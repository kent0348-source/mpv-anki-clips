# LAN queue coordination

The optional LAN coordinator serializes exports from multiple MPV Anki Clips clients. It manages job order and renewable leases; it does not read media or run FFmpeg. The client holding a lease owns the export and invokes its configured local or remote FFmpeg process.

## Set up clients

First deploy the Docker coordinator by following the [LAN queue server guide](../lan_queue_server/README.md). On every participating MPV Anki Clips installation, enable queueing and set the coordinator's private LAN address and published port in `mpv-anki-clips-core.conf`:

```ini
queue_server_enabled=yes
queue_server_host=192.168.1.10
queue_server_port=18789
queue_server_connect_timeout=2
queue_server_request_timeout=5
queue_server_heartbeat_interval=10
```

Use only a host name or address in `queue_server_host`—do not include `http://` or a path. Set the same endpoint on every client. The OSD can show the configured endpoint, queue details, and a pending job's global position.

When enabled, queue submission/polling does not silently fall back to an uncoordinated local encode if the server is unavailable. A client renews its lease while an export runs; if the lease is lost, it aborts its local FFmpeg command. The server waits its reassignment grace before granting the next job.

## Network and security boundary

The API has no authentication and uses plain HTTP. Any machine that can reach the published address and port can submit and manage jobs. Use only a trusted private LAN, bind the service to a private host interface, restrict the port in the host firewall to the intended subnet, and do not expose it through router port forwarding, UPnP, a public proxy, or a tunnel. Full deployment and firewall instructions are in the [server guide](../lan_queue_server/README.md).

Remote FFmpeg is also gated by the lease, but aborting the local SSH process cannot guarantee termination of a remote FFmpeg process that has already detached. The strongest practical serialization guarantee is for local encodes on a healthy LAN.
