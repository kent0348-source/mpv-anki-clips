# Remote FFmpeg over SSH (Windows host)

This mod can offload video clip encoding to a stronger machine by running **FFmpeg on a remote host via SSH**, then copying the encoded clip back into your local output directory (typically the Anki media folder).

This is designed for the common setup:
- Laptop: plays video in mpv + runs MPV Anki Clips
- Desktop/host: stronger CPU/GPU + runs ffmpeg
- Media is on a LAN share

## How it works

1. MPV Anki Clips builds the ffmpeg argument list.
2. It remaps file paths (optional; see `remote_path_map`) so the remote host can open the same media.
3. It runs `ssh host powershell ...` to execute ffmpeg on the host (using PowerShell `-EncodedCommand` to avoid Windows quoting issues).
4. ffmpeg writes the encoded clip into a **shared staging folder**.
5. MPV Anki Clips copies the staged clip into your local output directory.

## Requirements

- OpenSSH client on the laptop (`ssh` in PATH)
- OpenSSH server on the host (Windows “OpenSSH Server” feature)
- Key-based authentication (so SSH can run non-interactively)
- `ffmpeg` on the host (in PATH), or set `remote_ffmpeg_exec`
- A shared staging folder that both machines can read/write (paths can differ between machines)

## Configuration keys

Add these to your `script-opts/mpv-anki-clips-core.conf`:

```ini
remote_ffmpeg_enabled=yes
remote_ssh_host=JOHN-PC
remote_ssh_user=your_user   # optional
remote_ssh_port=22
remote_ssh_identity_file=   # optional: path to your *private key* file (OpenSSH format)
remote_ssh_extra_args=
remote_ffmpeg_exec=ffmpeg

# Shared staging folder (can differ between laptop and host)
remote_encode_staging_dir_local=\\JOHN-PC\Storage\_mpv-anki-clips_staging
remote_encode_staging_dir_remote=D:\Storage\_mpv-anki-clips_staging

# Optional: remap *input* paths passed to ffmpeg (and passlogfile)
# Format: localPrefix=>remotePrefix;localPrefix2=>remotePrefix2
remote_path_map=\\JOHN-PC\Storage\=>D:\Storage\;F:\=>D:\Storage\

remote_encode_cleanup=yes
```

### About `remote_ssh_identity_file`

This setting should point to an **SSH private key file** that your laptop's `ssh` client can use for non-interactive login.

- **Expected file**: the *private* key (NOT the `.pub` public key).
   - Example: `C:\Users\you\.ssh\id_ed25519` (good)
   - Not this: `C:\Users\you\.ssh\id_ed25519.pub`
- **Expected format**: OpenSSH private key format (what `ssh-keygen` creates).
   - If you use PuTTY `.ppk` keys, convert them to OpenSSH or generate a new OpenSSH key with `ssh-keygen`.
- **Where it's usually located (Windows)**:
   - `C:\Users\<YourUser>\.ssh\` (the exact filename depends on how the key was created)
- **When to leave it empty**: if your key is already in the default location and your SSH agent / default key discovery works, leaving this blank is fine.

Tip: use an absolute path here; it avoids surprises with working directories.

### About staging dirs

- `remote_encode_staging_dir_remote` is the path ffmpeg will write to **on the host**.
- `remote_encode_staging_dir_local` is the path the laptop will read from when copying the finished clip back.

These can point to the same physical folder even if the paths are different (UNC vs drive letter, different drive letters, etc.).

### About `remote_path_map`

Use this if the laptop’s `mpv` reports media paths that don’t exist on the host.

Example:
- Laptop plays from: `\\JOHN-PC\Storage\John Data F\video_encode\file.mkv`
- Host sees same file at: `D:\Storage\John Data F\video_encode\file.mkv`

Then set:

```ini
remote_path_map=\\JOHN-PC\Storage\=>D:\Storage\
```

Rules are applied in order of longest prefix first.

## Windows SSH server setup (host)

High-level steps (PowerShell as Admin on the host):

1. Install OpenSSH Server:
   - Settings → Apps → Optional features → Add a feature → **OpenSSH Server**
2. Start and enable the service:
   - `Start-Service sshd`
   - `Set-Service -Name sshd -StartupType Automatic`
3. Allow through firewall (usually automatic; if not):
   - Ensure inbound rule for `sshd` exists.
4. Ensure you can SSH in from the laptop:
   - `ssh your_user@JOHN-PC`

### Key-based auth

From the laptop:

- Generate a key if you don’t have one:
  - `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`
- Copy the public key to the host user’s `authorized_keys`.

(Exact steps differ depending on how you manage Windows OpenSSH user keys; verify you can run a command without a password prompt.)

## Notes / limitations

- The remote runner currently targets a **Windows host** by executing a PowerShell command via SSH.
- Very long ffmpeg commands may hit remote command-length limits. If you use extremely long `video_custom_args`, consider simplifying them.
- Two-pass stats/log files are created on the host path. In remote mode, MPV Anki Clips skips local passlog scanning and does not reliably clean up host-side passlogs.

## Troubleshooting

- If encoding succeeds but copy-back fails: verify `remote_encode_staging_dir_local` is reachable from the laptop and you have write access.
- If ffmpeg fails to open input: add/adjust `remote_path_map` so the host can resolve `-i` paths.
- If SSH prompts for a password: fix key-based auth or set `remote_ssh_identity_file`.
- Check the OSD “last encode command” and the mpv console output for the exact ffmpeg command executed remotely.
