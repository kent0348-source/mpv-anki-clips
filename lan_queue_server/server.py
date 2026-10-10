from __future__ import annotations

import ipaddress
import json
import logging
import os
import re
import signal
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


LOG = logging.getLogger("mpv_anki_clips.queue")
JOB_PATH = re.compile(r"^/v1/jobs/([^/]+)$")
ACTION_PATH = re.compile(r"^/v1/jobs/([^/]+)/(heartbeat|complete|cancel)$")


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Settings:
    host: str = "0.0.0.0"
    port: int = 56789
    publish_ip: str | None = None
    database_path: str = "/data/queue.db"
    lease_seconds: float = 30.0
    reassignment_grace_seconds: float = 10.0
    sweep_seconds: float = 1.0
    max_jobs: int = 1000
    max_body_bytes: int = 65536

    @classmethod
    def from_environment(cls) -> "Settings":
        settings = cls(
            host=os.getenv("QUEUE_HOST", cls.host),
            port=_env_int("QUEUE_PORT", cls.port),
            publish_ip=os.getenv("QUEUE_PUBLISH_IP") or None,
            database_path=os.getenv("QUEUE_DATABASE", cls.database_path),
            lease_seconds=_env_float("QUEUE_LEASE_SECONDS", cls.lease_seconds),
            reassignment_grace_seconds=_env_float(
                "QUEUE_REASSIGNMENT_GRACE_SECONDS", cls.reassignment_grace_seconds
            ),
            sweep_seconds=_env_float("QUEUE_SWEEP_SECONDS", cls.sweep_seconds),
            max_jobs=_env_int("QUEUE_MAX_JOBS", cls.max_jobs),
            max_body_bytes=_env_int("QUEUE_MAX_BODY_BYTES", cls.max_body_bytes),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if not self.host:
            raise ValueError("QUEUE_HOST must not be empty")
        if not 1 <= self.port <= 65535:
            raise ValueError("QUEUE_PORT must be between 1 and 65535")
        if self.publish_ip is not None:
            require_private_lan_ip(self.publish_ip)
        if not self.database_path:
            raise ValueError("QUEUE_DATABASE must not be empty")
        if self.lease_seconds <= 0:
            raise ValueError("QUEUE_LEASE_SECONDS must be positive")
        if self.reassignment_grace_seconds < 0:
            raise ValueError("QUEUE_REASSIGNMENT_GRACE_SECONDS must not be negative")
        if self.sweep_seconds <= 0:
            raise ValueError("QUEUE_SWEEP_SECONDS must be positive")
        if self.max_jobs < 1:
            raise ValueError("QUEUE_MAX_JOBS must be positive")
        if not 1024 <= self.max_body_bytes <= 10 * 1024 * 1024:
            raise ValueError("QUEUE_MAX_BODY_BYTES must be between 1024 and 10485760")


_RFC1918_NETWORKS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


def require_private_lan_ip(value: str) -> None:
    try:
        address = ipaddress.ip_address(value.strip())
    except ValueError as error:
        raise ValueError("QUEUE_PUBLISH_IP must be an IP address") from error
    if address.version != 4:
        raise ValueError("QUEUE_PUBLISH_IP must be a private IPv4 address")
    if address.is_unspecified:
        raise ValueError("QUEUE_PUBLISH_IP must not be 0.0.0.0")
    if not any(address in network for network in _RFC1918_NETWORKS):
        raise ValueError("QUEUE_PUBLISH_IP must be a private RFC1918 LAN address")


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError as error:
        raise ValueError(f"{name} must be an integer") from error


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError as error:
        raise ValueError(f"{name} must be a number") from error


class QueueStore:
    def __init__(
        self,
        database_path: str,
        lease_seconds: float,
        reassignment_grace_seconds: float,
        max_jobs: int,
        clock: Any = time.time,
    ) -> None:
        self.database_path = database_path
        self.lease_seconds = lease_seconds
        self.reassignment_grace_seconds = reassignment_grace_seconds
        self.max_jobs = max_jobs
        self.clock = clock
        self._lock = threading.RLock()
        if database_path != ":memory:":
            Path(database_path).parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(database_path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA synchronous=NORMAL")
        self._create_schema()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def _create_schema(self) -> None:
        with self._connection:
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL UNIQUE,
                    state TEXT NOT NULL,
                    submitted_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    metadata_json TEXT NOT NULL,
                    lease_id TEXT,
                    lease_deadline REAL,
                    promote_after REAL
                )
                """
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS jobs_state_sequence ON jobs(state, sequence)"
            )

    def submit(self, payload: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        job_id = payload.get("job_id")
        if not isinstance(job_id, str) or not job_id or len(job_id) > 200:
            raise ApiError(400, "invalid_job_id", "job_id must be a non-empty string of at most 200 characters")
        encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        now = self.clock()
        with self._transaction():
            self._refresh_locked(now)
            existing = self._get_row_locked(job_id)
            if existing is not None:
                return self._view_locked(existing, now), False
            retained = self._connection.execute(
                "SELECT COUNT(*) FROM jobs WHERE state IN ('pending', 'granted')"
            ).fetchone()[0]
            if retained >= self.max_jobs:
                raise ApiError(503, "queue_full", "queue capacity has been reached")
            state = "granted" if self._can_grant_locked(now) else "pending"
            lease_id = uuid.uuid4().hex if state == "granted" else None
            lease_deadline = now + self.lease_seconds if state == "granted" else None
            self._connection.execute(
                """
                INSERT INTO jobs(
                    job_id, state, submitted_at, updated_at, metadata_json,
                    lease_id, lease_deadline, promote_after
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                (job_id, state, now, now, encoded, lease_id, lease_deadline),
            )
            return self._view_locked(self._get_row_locked(job_id), now), True

    def get(self, job_id: str) -> dict[str, Any]:
        now = self.clock()
        with self._transaction():
            self._refresh_locked(now)
            row = self._get_row_locked(job_id)
            if row is None:
                raise ApiError(404, "job_not_found", "job was not found")
            return self._view_locked(row, now)

    def heartbeat(self, job_id: str, lease_id: Any) -> dict[str, Any]:
        now = self.clock()
        with self._transaction():
            self._refresh_locked(now)
            row = self._require_active_lease_locked(job_id, lease_id)
            deadline = now + self.lease_seconds
            self._connection.execute(
                "UPDATE jobs SET lease_deadline = ?, updated_at = ? WHERE job_id = ?",
                (deadline, now, job_id),
            )
            return self._view_locked(self._get_row_locked(job_id), now)

    def complete(self, job_id: str, lease_id: Any) -> dict[str, Any]:
        now = self.clock()
        with self._transaction():
            self._refresh_locked(now)
            self._require_active_lease_locked(job_id, lease_id)
            self._connection.execute(
                """
                UPDATE jobs
                SET state = 'completed', updated_at = ?, lease_id = NULL,
                    lease_deadline = NULL, promote_after = NULL
                WHERE job_id = ?
                """,
                (now, job_id),
            )
            self._promote_locked(now)
            return self._view_locked(self._get_row_locked(job_id), now)

    def cancel(self, job_id: str, lease_id: Any = None) -> dict[str, Any]:
        now = self.clock()
        with self._transaction():
            self._refresh_locked(now)
            row = self._get_row_locked(job_id)
            if row is None:
                raise ApiError(404, "job_not_found", "job was not found")
            if row["state"] == "granted":
                self._require_active_lease_locked(job_id, lease_id)
            elif row["state"] not in ("pending", "expired"):
                return self._view_locked(row, now)
            self._connection.execute(
                """
                UPDATE jobs
                SET state = 'cancelled', updated_at = ?, lease_id = NULL,
                    lease_deadline = NULL, promote_after = NULL
                WHERE job_id = ?
                """,
                (now, job_id),
            )
            self._promote_locked(now)
            return self._view_locked(self._get_row_locked(job_id), now)

    def status(self) -> dict[str, Any]:
        now = self.clock()
        with self._transaction():
            self._refresh_locked(now)
            running = self._connection.execute(
                "SELECT * FROM jobs WHERE state = 'granted' ORDER BY sequence LIMIT 1"
            ).fetchone()
            pending = self._connection.execute(
                "SELECT * FROM jobs WHERE state = 'pending' ORDER BY sequence"
            ).fetchall()
            expired = self._connection.execute(
                "SELECT * FROM jobs WHERE state = 'expired' ORDER BY sequence"
            ).fetchall()
            return {
                "running": self._view_locked(running, now) if running else None,
                "pending": [self._view_locked(row, now) for row in pending],
                "expired": [self._view_locked(row, now) for row in expired],
                "pending_count": len(pending),
            }

    def sweep(self) -> None:
        with self._transaction():
            self._refresh_locked(self.clock())

    def _transaction(self) -> Any:
        store = self

        class Transaction:
            def __enter__(self) -> None:
                store._lock.acquire()
                store._connection.execute("BEGIN IMMEDIATE")

            def __exit__(self, error_type: Any, error: Any, traceback: Any) -> None:
                try:
                    if error_type is None:
                        store._connection.commit()
                    else:
                        store._connection.rollback()
                finally:
                    store._lock.release()

        return Transaction()

    def _refresh_locked(self, now: float) -> None:
        self._connection.execute(
            """
            UPDATE jobs
            SET state = 'expired', updated_at = ?, promote_after = ?,
                lease_deadline = NULL
            WHERE state = 'granted' AND lease_deadline <= ?
            """,
            (now, now + self.reassignment_grace_seconds, now),
        )
        self._promote_locked(now)

    def _can_grant_locked(self, now: float) -> bool:
        active = self._connection.execute(
            "SELECT 1 FROM jobs WHERE state = 'granted' LIMIT 1"
        ).fetchone()
        grace = self._connection.execute(
            "SELECT 1 FROM jobs WHERE state = 'expired' AND promote_after > ? LIMIT 1",
            (now,),
        ).fetchone()
        return active is None and grace is None

    def _promote_locked(self, now: float) -> None:
        if not self._can_grant_locked(now):
            return
        row = self._connection.execute(
            "SELECT job_id FROM jobs WHERE state = 'pending' ORDER BY sequence LIMIT 1"
        ).fetchone()
        if row is None:
            return
        self._connection.execute(
            """
            UPDATE jobs
            SET state = 'granted', updated_at = ?, lease_id = ?,
                lease_deadline = ?, promote_after = NULL
            WHERE job_id = ?
            """,
            (now, uuid.uuid4().hex, now + self.lease_seconds, row["job_id"]),
        )

    def _require_active_lease_locked(self, job_id: str, lease_id: Any) -> sqlite3.Row:
        row = self._get_row_locked(job_id)
        if row is None:
            raise ApiError(404, "job_not_found", "job was not found")
        if row["state"] != "granted":
            raise ApiError(409, "lease_inactive", "job does not have an active lease")
        if not isinstance(lease_id, str) or lease_id != row["lease_id"]:
            raise ApiError(409, "lease_mismatch", "lease_id does not match the active grant")
        return row

    def _get_row_locked(self, job_id: str) -> sqlite3.Row | None:
        return self._connection.execute(
            "SELECT * FROM jobs WHERE job_id = ?", (job_id,)
        ).fetchone()

    def _view_locked(self, row: sqlite3.Row, now: float) -> dict[str, Any]:
        position = None
        if row["state"] == "pending":
            position = self._connection.execute(
                "SELECT COUNT(*) FROM jobs WHERE state = 'pending' AND sequence <= ?",
                (row["sequence"],),
            ).fetchone()[0]
        metadata = json.loads(row["metadata_json"])
        return {
            "job_id": row["job_id"],
            "state": row["state"],
            "position": position,
            "submitted_at": row["submitted_at"],
            "updated_at": row["updated_at"],
            "lease_id": row["lease_id"] if row["state"] == "granted" else None,
            "lease_deadline": row["lease_deadline"],
            "lease_seconds_remaining": max(0.0, row["lease_deadline"] - now)
            if row["lease_deadline"] is not None
            else None,
            "promote_after": row["promote_after"],
            "details": metadata,
        }


class QueueHttpServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], store: QueueStore, max_body_bytes: int) -> None:
        self.store = store
        self.max_body_bytes = max_body_bytes
        super().__init__(address, QueueRequestHandler)


class QueueRequestHandler(BaseHTTPRequestHandler):
    server: QueueHttpServer
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        try:
            if self.path == "/health":
                self._send(200, {"status": "ok"})
                return
            if self.path == "/v1/status":
                self._send(200, self.server.store.status())
                return
            match = JOB_PATH.fullmatch(self.path)
            if match:
                self._send(200, self.server.store.get(match.group(1)))
                return
            raise ApiError(404, "not_found", "endpoint was not found")
        except ApiError as error:
            self._send_error(error)
        except Exception:
            LOG.exception("unhandled GET error")
            self._send(500, {"error": {"code": "internal_error", "message": "internal server error"}})

    def do_POST(self) -> None:
        try:
            payload = self._read_json()
            if self.path == "/v1/jobs":
                result, created = self.server.store.submit(payload)
                self._send(201 if created else 200, result)
                return
            match = ACTION_PATH.fullmatch(self.path)
            if not match:
                raise ApiError(404, "not_found", "endpoint was not found")
            job_id, action = match.groups()
            if action == "heartbeat":
                result = self.server.store.heartbeat(job_id, payload.get("lease_id"))
            elif action == "complete":
                result = self.server.store.complete(job_id, payload.get("lease_id"))
            else:
                result = self.server.store.cancel(job_id, payload.get("lease_id"))
            self._send(200, result)
        except ApiError as error:
            self._send_error(error)
        except Exception:
            LOG.exception("unhandled POST error")
            self._send(500, {"error": {"code": "internal_error", "message": "internal server error"}})

    def _read_json(self) -> dict[str, Any]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ApiError(411, "length_required", "Content-Length is required")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise ApiError(400, "invalid_length", "Content-Length is invalid") from error
        if length < 0 or length > self.server.max_body_bytes:
            raise ApiError(413, "body_too_large", "request body exceeds configured limit")
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ApiError(400, "invalid_json", "request body must be valid UTF-8 JSON") from error
        if not isinstance(payload, dict):
            raise ApiError(400, "invalid_json_type", "request body must be a JSON object")
        return payload

    def _send_error(self, error: ApiError) -> None:
        self._send(error.status, {"error": {"code": error.code, "message": error.message}})

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format_string: str, *args: Any) -> None:
        LOG.info("http client=%s message=%s", self.client_address[0], format_string % args)


class Coordinator:
    def __init__(self, settings: Settings) -> None:
        settings.validate()
        self.settings = settings
        self.store = QueueStore(
            settings.database_path,
            settings.lease_seconds,
            settings.reassignment_grace_seconds,
            settings.max_jobs,
        )
        self.server = QueueHttpServer(
            (settings.host, settings.port), self.store, settings.max_body_bytes
        )
        self._stop = threading.Event()
        self._sweeper = threading.Thread(target=self._sweep, name="lease-sweeper", daemon=True)

    def serve(self) -> None:
        self._sweeper.start()
        LOG.info("queue coordinator listening host=%s port=%s", *self.server.server_address)
        try:
            self.server.serve_forever(poll_interval=0.25)
        finally:
            self.close()

    def shutdown(self) -> None:
        self._stop.set()
        self.server.shutdown()

    def close(self) -> None:
        self._stop.set()
        self.server.server_close()
        if self._sweeper.is_alive() and threading.current_thread() is not self._sweeper:
            self._sweeper.join(timeout=self.settings.sweep_seconds * 2)
        self.store.close()

    def _sweep(self) -> None:
        while not self._stop.wait(self.settings.sweep_seconds):
            try:
                self.store.sweep()
            except Exception:
                LOG.exception("lease sweep failed")


def main() -> None:
    logging.basicConfig(
        level=os.getenv("QUEUE_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = Settings.from_environment()
    coordinator = Coordinator(settings)

    def stop(_signal_number: int, _frame: Any) -> None:
        threading.Thread(target=coordinator.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    coordinator.serve()


if __name__ == "__main__":
    main()