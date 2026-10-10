# Core workflows

This guide collects the everyday note, subtitle, and profile workflows. Default keys below can be changed where noted; see [advanced and global bindings](./bindings.md) for the full default binding reference.

## Create or update notes

- Open the advanced menu with `a` to create a note (`Ctrl+n`), update selected notes (`b` / `B`), or update the most recently added note (`Ctrl+m` / `Ctrl+M`).
- The quick-card flow uses global bindings with existing recent notes and well-timed subtitles.
- The quick-card flow uses existing recent notes and well-timed subtitles.

For step-by-step flows, see [create a note](./create_card.md), [update selected notes](./update_selected_card.md), [the Add Cards window](./add_dialog.md), and [quick cards](./create_quick_card.md).

## Subtitle capture and timing

Open the advanced menu with `a`. Press `c` to capture the current subtitle and begin selecting lines. Move to nearby subtitles with `Alt+q` and `Alt+e`; use `q` and `e` to seek without pausing. Set the clip start or end manually with `s` and `f`, or align them to the current subtitle with `S` and `F`. `Alt+s` and `Alt+d` set the start and end using the clipboard-driven timing input.

While the menu is open:

- `v` toggles subtitle capture without clearing captured text or timings.
- `g` removes the current subtitle from the captured list.
- `C` clears captured subtitles and resumes playback.
- `Ctrl+Alt+c` clears captured subtitles and stops.
- `V` resets timings and captured dialogs.
- `x` restores the last saved timings.

The OSD previews captured primary and secondary subtitle text. Use `Ctrl+g` globally for the quick line-selection flow when subtitles are well-timed and no manual selection is needed.

## Clipboard and other text sources

`Ctrl+c` copies the current primary subtitle; `Ctrl+C` copies the current secondary subtitle. The advanced menu's `z` toggles autoclip and `Z` cycles its target: `clipboard`, `goldendict`, or `custom_command`.

`copy_text_mode` controls text sent through these copy/autoclip targets:

- `single_line` collapses text to one line.
- `subtitle_content` preserves subtitle layout.
- `custom_pattern` applies a Lua pattern replacement, with configurable scope and output formatting.

The custom filter is controlled by `copy_text_custom_pattern`, `copy_text_custom_replacement`, `copy_text_custom_scope`, and `copy_text_custom_base_mode`. `use_clipboard_when_empty=yes` allows non-empty clipboard text to supply export text when subtitle text is unavailable. These filters do not change the subtitle preview.

See the [GoldenDict workflow](./goldendict.md) and [Rikaitan workflow](./yomichan.md) for external note-creation workflows.

## Secondary subtitles

Global bindings toggle secondary subtitle visibility (`Ctrl+v`) and move to the previous/next secondary track (`Ctrl+k` / `Ctrl+j`). Core settings control automatic loading, preferred languages, visibility policy, and the hover-sensitive area used by automatic visibility. See the comments in the shipped [core settings example](../src/mpv-anki-clips/exampleconfig/mpv-anki-clips-core.conf).

## Field sets

The core settings support up to three field sets. Each maps the sentence, secondary subtitle, video, and miscellaneous-information fields. Cycle the active set with `Alt+f` in the advanced menu; it changes the mappings used for subsequent exports without restarting mpv.

## Profiles

`mpv-anki-clips-base.conf` supplies profile defaults, an optional profile file overrides those profile-specific values, and `mpv-anki-clips-core.conf` is applied independently for shared settings. The active profile is selected in `mpv-anki-clips-profiles.conf` and loaded at startup or add-on reload; selecting a profile for editing in the GUI does not activate it in a running mpv session.

Inside the advanced menu, use the mouse wheel to cycle profiles. The active profile is shown in the menu header. The shipped [profiles example](../src/mpv-anki-clips/exampleconfig/mpv-anki-clips-profiles.conf) enables the base profile by default.
