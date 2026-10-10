# Open Anki's Add Cards window

This fork still supports a GUI-based add-note flow through AnkiConnect, but the binding is different from older docs.

## Current flow

1. Open a video in mpv.
2. Press <kbd>a</kbd> to open the advanced menu.
3. Optionally press <kbd>c</kbd> and refine the subtitle/timing selection first.
4. Press <kbd>Ctrl+G</kbd> in the advanced menu.

That triggers AnkiConnect's `guiAddCards` action and opens Anki's Add Cards window with the generated fields prefilled.
The note is not saved until you confirm it in that window. MPV Anki Clips reports the dialog handoff, not a completed note creation.

## Why use this instead of plain export?

Use the GUI add-card flow when you want to:

- inspect or edit the generated fields before confirming
- add extra information manually in Anki's Add Cards window
- keep a visible confirmation step instead of using the direct add-note path

If you do not need the Add Cards window, use <kbd>Ctrl+n</kbd> in the advanced menu for the direct export path instead.
