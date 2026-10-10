# Flatpak notes

Flatpak sandbox permissions can affect whether mpv can load the add-on, access video files, invoke host tools, and communicate with AnkiConnect. The exact permissions and paths depend on the Flatpak builds and app IDs installed on your system.

For the Flathub mpv app with ID `io.mpv.Mpv`, the config root is typically:

```text
~/.var/app/io.mpv.Mpv/config/mpv
```

The add-on runtime belongs in its `scripts` subdirectory and the add-on settings in `script-opts`. If you use Flatseal or Flatpak overrides, grant only the file and host-tool access that your setup requires; avoid granting access to the entire host filesystem unless you have a specific reason.

AnkiConnect must be reachable from the mpv sandbox, and Anki must be able to read the media files that mpv writes. For the Flathub Anki app, its app-specific data is commonly under `~/.var/app/net.ankiweb.Anki`; confirm the installed app ID and actual media directory before adding filesystem permissions.

Clipboard helper executables such as `wl-copy` must be accessible from inside the sandbox. Their visibility depends on the Flatpak runtime and permissions, so verify from the sandbox rather than assuming that a host executable on `PATH` is available.
