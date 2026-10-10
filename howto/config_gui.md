# Portable configuration GUI

The optional standalone GUI edits the same mpv `script-opts` config files as the add-on. It runs separately from mpv, does not require the Lua add-on to be installed, and can be removed without removing the add-on or its settings.

## Install and launch

Download the portable GUI package for your operating system and extract its complete `mpv-anki-clips-config` folder to a writable location. Launch the executable inside that folder. On Windows, it runs as a windowed app without an accompanying console window and includes an application icon. It does not need a conventional installer, administrator privileges, or an installed Rust toolchain. Install the add-on runtime separately in mpv's `scripts` directory.

On Linux, use the GUI's **Create shortcut…** action to add an application-menu entry. It installs the app icon in your user icon theme and references it from the shortcut; you can also choose to create a Desktop shortcut.

Use **Browse** if the config folder is not at its standard location. The GUI shows the `script-opts` path it will edit. Select the correct mpv config root before saving, particularly if mpv uses a portable config or custom `--config-dir`.

Use **Open current .conf** to launch the file for the active settings tab with the operating system's default application. Core settings and key bindings open the shared core config; the Profiles tab opens the selected profile's file. Use **Open script-opts folder** to open the target directory in the system file manager.

## Editing settings and profiles

The GUI edits core settings, profile files, profile lists, and key bindings. The **Key bindings** tab groups actions by task and shows each shortcut beside its **Active in** selector: **Advanced menu only** or **Global (any time)**. Each action has one key and one exclusive scope; changing scope moves that key to the selected context rather than adding a second binding. Advanced-menu keys work only while that menu is open; global keys stay active during playback. Leave the key blank to disable the add-on's default shortcut. **Default** restores both the action's shipped key and scope. The Profiles tab lets you select a profile to edit; **Save profile** writes its settings. The base profile holds defaults, while custom profiles save overrides. The profile selected for editing is distinct from the profile mpv loads at startup or add-on reload.

When a config folder is loaded, the GUI migrates supported settings that moved between core and profile files and removes obsolete or unknown options. Review and preserve important settings before saving: each changed existing file is backed up with a `.bak` suffix in the GUI's `config-backups` folder, outside mpv's config directory. Restart mpv after saving for changes to take effect.

Hover over a setting to see its description from the bundled example config. On the Key bindings tab, duplicate shortcuts in the selected scopes are rejected when saving; resolve any collision introduced by a scope change before saving. The runtime also warns about duplicates and disables the later shortcut. Scope changes are read during add-on initialization, so restart or reload mpv after saving. The GUI does not edit `input.conf`; its stable action names remain available there regardless of the selected scope.

## Read-only detection

**Scan OS config** is manually triggered. It checks tools resolved through `PATH`, common application locations, and likely mpv config roots; it does not scan an arbitrary user-selected directory or the entire disk. Results distinguish the executable resolved by a terminal command from other detected installs and identify likely config roots and whether the add-on is present. If multiple candidates are found, or mpv uses a custom `--config-dir`, verify the path against the running setup.

**Check media defaults** separately queries the operating system's current default handlers for common video and audio formats. It is read-only: it does not change file associations or launch the handlers. Results depend on the platform's association-query facilities and may show missing tools or unresolved executable paths.

## Building the portable package

The GUI is built in Rust with Slint's software renderer. To build a package from the repository root, install Rust 1.92 or newer and run:

```powershell
python build\package_config_gui.py --version v1.2.3
```

Build separately on Windows, Linux, and macOS for a package targeting each operating system.
