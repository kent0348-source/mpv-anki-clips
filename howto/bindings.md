# Advanced-menu and global bindings

There are two binding contexts:

- **Advanced-menu bindings** work only while the MPV Anki Clips advanced menu is open.
- **Global bindings** stay active during playback, including while an add-on menu is open.

Each action has one configured key and one `binding_scope_<key-setting>` value: `advanced-menu` or `global`. The bundled scope defaults preserve the current behavior. Changing an action's scope moves its existing key; it does not create a second shortcut or allow the action in both contexts. Key settings retain their existing names: advanced actions use `menu_key_*`, global actions use `global_key_*`, and the menu opener remains `menu_key_open`.

The config GUI's **Key bindings** page keeps each action's shortcut and scope together on one row. Its **Active in** selector offers **Advanced menu only** and **Global (any time)**; rows are grouped by what the actions do, not by scope. The **Default** button restores both that action's shipped key and scope. Leave a key blank to disable the add-on's default shortcut.

Duplicate shortcuts are rejected when you save if they share a selected context; assigning the same key to actions in different contexts is allowed. If a scope change would create a duplicate in its destination context, resolve the duplicate before saving.

For example, this keeps the existing `e` key but makes subtitle seek-forward global:

```ini
menu_key_seek_next=e
binding_scope_menu_key_seek_next=global
```

Restart or reload mpv after changing scope settings; scope changes are read during add-on initialization.

## Binding any action in `input.conf`

Every action has a stable script-binding name and is available while the add-on is loaded, regardless of whether a menu is open. Prefix the action name with `mpv-anki-clips/` in mpv's `input.conf`:

```ini
F8 script-binding mpv-anki-clips/mpv-anki-clips-sub-seek-forward
```

This is a user-managed alternative to the add-on's default keys; MPV Anki Clips does not edit `input.conf`. It also lets you use an advanced-menu action globally without adding another context setting. A custom `input.conf` key does not change the action's ordinary menu shortcut.

Key capitalization is significant: `Ctrl+G` means Shift+Ctrl+g, while lowercase `Ctrl+g` opens the quick line-selection menu.

## Advanced-menu defaults

These actions default to the advanced-menu scope. A `binding_scope_menu_key_<action>` setting can move an action and its one key to the global scope. Their stable action names can also be bound in `input.conf` to make them available globally without changing their configured scope.

| Key | Action | Action name |
| --- | --- | --- |
| `c` | Capture current subtitle | `mpv-anki-clips-capture-current` |
| `q` | Seek to previous subtitle | `mpv-anki-clips-sub-seek-backward` |
| `e` | Seek to next subtitle | `mpv-anki-clips-sub-seek-forward` |
| `s` | Set start manually | `mpv-anki-clips-set-start` |
| `f` | Set end manually | `mpv-anki-clips-set-end` |
| `S` | Set start to current subtitle | `mpv-anki-clips-set-start-to-sub` |
| `F` | Set end to current subtitle | `mpv-anki-clips-set-end-to-sub` |
| `Alt+s` | Set start from clipboard-driven input | `mpv-anki-clips-set-start-from-clipboard` |
| `Alt+d` | Set end from clipboard-driven input | `mpv-anki-clips-set-end-from-clipboard` |
| `Alt+q` | Seek to previous subtitle and pause | `mpv-anki-clips-seek-previous-pause` |
| `Alt+e` | Seek to next subtitle and pause | `mpv-anki-clips-seek-next-pause` |
| `u` | Decrement card count | `mpv-anki-clips-decrement-cards` |
| `U` | Increment card count | `mpv-anki-clips-increment-cards` |
| `v` | Toggle subtitle capture | `mpv-anki-clips-toggle-capture` |
| `C` | Clear captured subtitles and resume | `mpv-anki-clips-clear-capture-resume` |
| `Ctrl+Alt+c` | Clear captured subtitles and stop | `mpv-anki-clips-clear-capture-stop` |
| `V` | Reset timings and dialogs | `mpv-anki-clips-reset-all` |
| `Ctrl+n` | Export a new note | `mpv-anki-clips-export-note` |
| `Ctrl+G` | Open Anki's Add Cards window | `mpv-anki-clips-gui-export` |
| `b` | Update selected note | `mpv-anki-clips-update-selected` |
| `B` | Update selected note in overwrite mode | `mpv-anki-clips-overwrite-selected` |
| `Ctrl+m` | Update last added note | `mpv-anki-clips-update-last` |
| `Ctrl+M` | Update last added note in overwrite mode | `mpv-anki-clips-overwrite-last` |
| `g` | Remove current subtitle from capture | `mpv-anki-clips-remove-current-subtitle` |
| `h` | Test encode | `mpv-anki-clips-test-encode` |
| `X` | Repeat last export in force-overwrite mode | `mpv-anki-clips-repeat-export-overwrite` |
| `Ctrl+X` | Repeat last export respecting original overwrite mode | `mpv-anki-clips-repeat-export-respect` |
| `r` | Refresh target-note preview and open it | `mpv-anki-clips-refresh-anki-preview` |
| `z` | Toggle autoclip | `mpv-anki-clips-toggle-autoclip` |
| `Z` | Cycle autoclip method | `mpv-anki-clips-cycle-autoclip-method` |
| `i` | Cycle menu hints | `mpv-anki-clips-cycle-hints` |
| `R` | Toggle target-note preview | `mpv-anki-clips-toggle-target-preview` |
| `t` | Toggle queue details | `mpv-anki-clips-toggle-queue-details` |
| `T` | Toggle last encode command | `mpv-anki-clips-toggle-encode-command` |
| `Ctrl+T` | Toggle last error tail | `mpv-anki-clips-toggle-error-tail` |
| `x` | Load last timings | `mpv-anki-clips-load-last-timings` |
| `y` | Toggle subtitle text export | `mpv-anki-clips-toggle-subtitle-export` |
| `Wheel up` | Next profile | `mpv-anki-clips-next-profile` |
| `Wheel down` | Previous profile | `mpv-anki-clips-previous-profile` |
| `Shift+Ctrl+Wheel up` | Increase menu font size | `mpv-anki-clips-increase-menu-font` |
| `Shift+Ctrl+Wheel down` | Decrease menu font size | `mpv-anki-clips-decrease-menu-font` |
| `Alt+f` | Cycle field set | `mpv-anki-clips-cycle-field-set` |
| `Esc` | Close menu | `mpv-anki-clips-close` |

The quick menus also provide named actions: `mpv-anki-clips-quick-line-select-1` through `mpv-anki-clips-quick-line-select-9`, `mpv-anki-clips-quick-line-select-one`, and `mpv-anki-clips-quick-card-select-1` through `mpv-anki-clips-quick-card-select-9`. Their close actions are `mpv-anki-clips-quick-line-menu-close-escape`, `mpv-anki-clips-quick-line-menu-close-q`, `mpv-anki-clips-quick-card-menu-close-escape`, and `mpv-anki-clips-quick-card-menu-close-q`.

## Global defaults

These actions default to the global scope. Their one key can be moved to the advanced-menu scope using the corresponding `binding_scope_<key-setting>`. Each action remains available by its stable name if its configured key is blank.

| Key | Action | Action name |
| --- | --- | --- |
| `a` | Open advanced menu (`menu_key_open`) | `mpv-anki-clips-menu-open` |
| `Ctrl+g` | Open quick line-selection menu | `mpv-anki-clips-quick-card-menu-open` |
| `Alt+g` | Open quick card-count menu | `mpv-anki-clips-quick-card-sel-menu-open` |
| `Ctrl+c` | Copy primary subtitle | `mpv-anki-clips-copy-sub-to-clipboard` |
| `Ctrl+C` | Copy secondary subtitle | `mpv-anki-clips-copy-secondary-sub-to-clipboard` |
| `Ctrl+v` | Toggle secondary subtitle visibility | `mpv-anki-clips-secondary-sid-toggle` |
| `Ctrl+j` | Select next secondary subtitle track | `mpv-anki-clips-secondary-sid-next` |
| `Ctrl+k` | Select previous secondary subtitle track | `mpv-anki-clips-secondary-sid-prev` |
| `Ctrl+h` | Rewind to current subtitle start | `mpv-anki-clips-sub-rewind` |
| `Ctrl+H` | Replay current subtitle | `mpv-anki-clips-sub-replay` |
| `Ctrl+L` | Play to next subtitle end | `mpv-anki-clips-sub-play-up-to-next` |
| `Ctrl+Y` | Restart mpv with current file (debug) | `mpv-anki-clips-restart-mpv-current-file` |

On Windows, `Ctrl+Y` opens a new PowerShell console. On Linux, it opens a terminal using the first supported installed emulator (`x-terminal-emulator`, GNOME Terminal, Konsole, XFCE Terminal, or `xterm`); if none is available, it reports an error and leaves the current mpv session running.

Some keys intentionally differ by context: `g` removes the current captured subtitle in the advanced menu but selects one line in the quick line-selection menu. `Ctrl+g` globally opens the quick line-selection menu; `Ctrl+G` inside the advanced menu opens Anki's Add Cards window.
