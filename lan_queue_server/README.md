# MPV Anki Clips LAN Queue Coordinator

This container coordinates MPV Anki Clips exports across machines. It never reads media and never runs ffmpeg. The MPV Anki Clips client holding the active lease runs the encode.

The API is intentionally unauthenticated. Every machine that can reach the published IP and port can submit, inspect, complete, or cancel jobs. Keep it on a trusted private LAN.

## Start

1. Copy `.env.example` and rename to `.env`.
2. In the .env file, set `QUEUE_PUBLISH_IP` to the Docker host's private IPv4 address, such as `192.168.1.10`. Do not use `0.0.0.0`, `::`, `127.0.0.1`, or a public/WAN address.
3. Set `QUEUE_HOST_PORT` if the default host port `18789` is already in use. The process inside the container still listens on `56789`; only the published host port changes. On Windows, also avoid Hyper-V excluded ranges (`netsh interface ipv4 show excludedportrange protocol=tcp`).
4. Start the service:

```sh
docker compose up --build -d
docker compose ps
```

Check it from another allowed LAN machine:

```sh
curl http://192.168.1.10:18789/health
curl http://192.168.1.10:18789/v1/status
```

After deploying the coordinator, configure MPV Anki Clips clients as described in the [LAN queue coordination guide](../howto/lan_queue_coordination.md).

## LAN boundary

Docker cannot tell whether traffic originally came from the internet. LAN-only operation requires all of the following:

- Publish the port only on the Docker host's private LAN IP. The Compose template binds `host_ip` to `QUEUE_PUBLISH_IP` so the service is not attached to `0.0.0.0` or a public interface.
- Do not set `QUEUE_PUBLISH_IP` to `0.0.0.0`, `::`, a loopback address, or any public/WAN address.
- Do not configure router port forwarding, UPnP, a public reverse proxy, or a tunnel for this port.
- Allow the published TCP port only from your private subnet in the host firewall, and remove any broader allow rule for the same port.
- Use a trusted LAN. Requests and queue metadata use unencrypted HTTP.

Windows PowerShell, run as Administrator, for a typical `192.168.1.0/24` LAN. Replace the local port if you changed `QUEUE_HOST_PORT`:

```powershell
Get-NetFirewallRule -DisplayName "MPV Anki Clips LAN queue" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "MPV Anki Clips LAN queue" -Direction Inbound -Action Allow -Protocol TCP -LocalAddress 192.168.1.10 -LocalPort 18789 -RemoteAddress 192.168.1.0/24
```

Ubuntu with UFW:

```sh
sudo ufw allow from 192.168.1.0/24 to 192.168.1.10 port 18789 proto tcp
```

Adjust the host IP, port, and subnet to match your network. The firewall destination should be the same private address as `QUEUE_PUBLISH_IP`.

## Operations

View logs and queue state:

```sh
docker compose logs -f queue
curl http://192.168.1.10:18789/v1/status
```

Upgrade or restart without discarding SQLite state:

```sh
docker compose up --build -d
docker compose restart queue
```

Back up the named volume while the service is stopped:

```sh
docker compose stop queue
docker run --rm -v lan_queue_server_queue-data:/data -v "$PWD:/backup" alpine \
  tar czf /backup/queue-data.tar.gz -C /data .
docker compose start queue
```

The exact volume prefix may differ. Check it with `docker volume ls`.

## Lease behavior

The active client renews a lease while ffmpeg runs. If heartbeats stop, the coordinator expires the lease, waits `QUEUE_REASSIGNMENT_GRACE_SECONDS`, then grants the next job. The grace gives the disconnected client time to abort local ffmpeg before another encode starts.

For local encoding this provides strong practical serialization. If MPV Anki Clips launches ffmpeg through SSH, aborting the local SSH process may not stop a remote ffmpeg process that has already detached.

## Two-machine check

1. Start a long export on machine A.
2. Submit an export from machine B and confirm it remains pending in `/v1/status`.
3. Let A finish and confirm B becomes granted.
4. Repeat, then terminate mpv on A. Confirm B starts only after the lease and reassignment grace expire.
5. Stop the coordinator and confirm neither client starts a new ffmpeg process while queueing is enabled.

## Tests

```sh
python -m unittest discover -s . -p "test_*.py" -v
```