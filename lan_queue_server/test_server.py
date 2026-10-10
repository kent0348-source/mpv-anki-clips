from __future__ import annotations

import http.client
import json
import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from server import ApiError, QueueHttpServer, QueueStore, Settings, require_private_lan_ip


class FakeClock:
    def __init__(self, value: float = 1000.0) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds


class QueueStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()
        self.store = QueueStore(":memory:", 10.0, 5.0, 10, self.clock)

    def tearDown(self) -> None:
        self.store.close()

    def test_fifo_completion_promotes_next_job(self) -> None:
        first, _ = self.store.submit({"job_id": "first"})
        second, _ = self.store.submit({"job_id": "second"})
        third, _ = self.store.submit({"job_id": "third"})

        self.assertEqual("granted", first["state"])
        self.assertEqual(1, second["position"])
        self.assertEqual(2, third["position"])

        self.store.complete("first", first["lease_id"])
        self.assertEqual("granted", self.store.get("second")["state"])
        self.assertEqual(1, self.store.get("third")["position"])

    def test_duplicate_submission_is_idempotent(self) -> None:
        first, created = self.store.submit({"job_id": "same", "value": 1})
        duplicate, duplicate_created = self.store.submit({"job_id": "same", "value": 2})

        self.assertTrue(created)
        self.assertFalse(duplicate_created)
        self.assertEqual(first["lease_id"], duplicate["lease_id"])
        self.assertEqual(1, duplicate["details"]["value"])

    def test_concurrent_submissions_create_one_grant(self) -> None:
        barrier = threading.Barrier(8)

        def submit(index: int) -> dict[str, object]:
            barrier.wait()
            return self.store.submit({"job_id": f"job-{index}"})[0]

        with ThreadPoolExecutor(max_workers=8) as executor:
            jobs = list(executor.map(submit, range(8)))

        self.assertEqual(1, sum(job["state"] == "granted" for job in jobs))
        self.assertEqual(7, sum(job["state"] == "pending" for job in jobs))

    def test_expiry_waits_for_reassignment_grace(self) -> None:
        first, _ = self.store.submit({"job_id": "first"})
        self.store.submit({"job_id": "second"})

        self.clock.advance(10.0)
        self.store.sweep()
        self.assertEqual("expired", self.store.get("first")["state"])
        self.assertEqual("pending", self.store.get("second")["state"])

        self.clock.advance(4.9)
        self.store.sweep()
        self.assertEqual("pending", self.store.get("second")["state"])

        self.clock.advance(0.1)
        self.store.sweep()
        second = self.store.get("second")
        self.assertEqual("granted", second["state"])
        self.assertNotEqual(first["lease_id"], second["lease_id"])

    def test_heartbeat_renews_and_stale_lease_is_rejected(self) -> None:
        job, _ = self.store.submit({"job_id": "job"})
        original_deadline = job["lease_deadline"]
        self.clock.advance(3.0)
        renewed = self.store.heartbeat("job", job["lease_id"])
        self.assertGreater(renewed["lease_deadline"], original_deadline)

        with self.assertRaises(ApiError) as context:
            self.store.complete("job", "wrong-lease")
        self.assertEqual("lease_mismatch", context.exception.code)

    def test_pending_cancel_does_not_need_lease(self) -> None:
        active, _ = self.store.submit({"job_id": "active"})
        self.store.submit({"job_id": "pending"})
        cancelled = self.store.cancel("pending")
        self.assertEqual("cancelled", cancelled["state"])
        self.assertEqual("granted", self.store.get("active")["state"])
        self.store.complete("active", active["lease_id"])

    def test_capacity_counts_only_live_jobs(self) -> None:
        store = QueueStore(":memory:", 10.0, 5.0, 2, self.clock)
        self.addCleanup(store.close)
        first, _ = store.submit({"job_id": "one"})
        store.submit({"job_id": "two"})
        with self.assertRaises(ApiError) as context:
            store.submit({"job_id": "three"})
        self.assertEqual("queue_full", context.exception.code)
        store.complete("one", first["lease_id"])
        second = store.get("two")
        store.complete("two", second["lease_id"])
        created, _ = store.submit({"job_id": "three"})
        self.assertEqual("granted", created["state"])

    def test_active_lease_survives_database_reopen(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database = str(Path(directory) / "queue.db")
            first_store = QueueStore(database, 10.0, 5.0, 10, self.clock)
            job, _ = first_store.submit({"job_id": "persistent"})
            first_store.close()

            reopened = QueueStore(database, 10.0, 5.0, 10, self.clock)
            try:
                restored = reopened.get("persistent")
                self.assertEqual("granted", restored["state"])
                self.assertEqual(job["lease_id"], restored["lease_id"])
            finally:
                reopened.close()


class HttpApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()
        self.store = QueueStore(":memory:", 10.0, 5.0, 10, self.clock)
        self.server = QueueHttpServer(("127.0.0.1", 0), self.store, 1024)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.store.close()

    def request(
        self, method: str, path: str, payload: object | None = None
    ) -> tuple[int, dict[str, object]]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"} if body is not None else {}
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            decoded = json.loads(response.read().decode("utf-8"))
            return response.status, decoded
        finally:
            connection.close()

    def test_health_and_status_need_no_credentials(self) -> None:
        health_status, health = self.request("GET", "/health")
        queue_status, queue = self.request("GET", "/v1/status")
        self.assertEqual(200, health_status)
        self.assertEqual("ok", health["status"])
        self.assertEqual(200, queue_status)
        self.assertEqual(0, queue["pending_count"])

    def test_job_lifecycle_needs_no_credentials(self) -> None:
        create_status, job = self.request("POST", "/v1/jobs", {"job_id": "http-job"})
        self.assertEqual(201, create_status)
        self.assertEqual("granted", job["state"])

        heartbeat_status, heartbeat = self.request(
            "POST",
            "/v1/jobs/http-job/heartbeat",
            {"lease_id": job["lease_id"]},
        )
        self.assertEqual(200, heartbeat_status)
        self.assertEqual("granted", heartbeat["state"])

        complete_status, completed = self.request(
            "POST",
            "/v1/jobs/http-job/complete",
            {"lease_id": job["lease_id"]},
        )
        self.assertEqual(200, complete_status)
        self.assertEqual("completed", completed["state"])

    def test_invalid_json_and_stale_lease_have_stable_errors(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.request("POST", "/v1/jobs", body=b"{", headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        error = json.loads(response.read().decode("utf-8"))
        connection.close()
        self.assertEqual(400, response.status)
        self.assertEqual("invalid_json", error["error"]["code"])

        _, job = self.request("POST", "/v1/jobs", {"job_id": "leased"})
        status, mismatch = self.request(
            "POST", "/v1/jobs/leased/complete", {"lease_id": "stale"}
        )
        self.assertEqual(409, status)
        self.assertEqual("lease_mismatch", mismatch["error"]["code"])

    def test_oversized_body_is_rejected(self) -> None:
        status, error = self.request(
            "POST", "/v1/jobs", {"job_id": "large", "padding": "x" * 2000}
        )
        self.assertEqual(413, status)
        self.assertEqual("body_too_large", error["error"]["code"])


class PublishIpGuardTests(unittest.TestCase):
    def test_rfc1918_addresses_are_accepted(self) -> None:
        for value in ("10.0.0.5", "172.16.4.1", "192.168.1.50"):
            require_private_lan_ip(value)

    def test_public_unspecified_and_loopback_are_rejected(self) -> None:
        for value in ("0.0.0.0", "127.0.0.1", "8.8.8.8", "::", "::1", "not-an-ip"):
            with self.assertRaises(ValueError):
                require_private_lan_ip(value)

    def test_settings_reject_public_publish_ip(self) -> None:
        env = {
            "QUEUE_HOST": "0.0.0.0",
            "QUEUE_PORT": "56789",
            "QUEUE_PUBLISH_IP": "0.0.0.0",
            "QUEUE_DATABASE": ":memory:",
        }
        with patch.dict(os.environ, env, clear=False):
            with self.assertRaises(ValueError):
                Settings.from_environment()

    def test_settings_accept_private_publish_ip(self) -> None:
        env = {
            "QUEUE_HOST": "0.0.0.0",
            "QUEUE_PORT": "56789",
            "QUEUE_PUBLISH_IP": "192.168.1.10",
            "QUEUE_DATABASE": ":memory:",
        }
        with patch.dict(os.environ, env, clear=False):
            settings = Settings.from_environment()
        self.assertEqual("192.168.1.10", settings.publish_ip)


if __name__ == "__main__":
    unittest.main()