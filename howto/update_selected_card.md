# Update a selected note

Use this flow when you already have one or more notes selected in the Anki Browser and want mpv to append or replace media/text on those selected notes.

## Update from the current subtitle

1. Select the target note in the Anki Browser.
2. In mpv, pause on the subtitle you want.
3. Press <kbd>a</kbd> to open the advanced menu.
4. Press <kbd>b</kbd> to update the selected note.
5. Press <kbd>B</kbd> instead if you want overwrite mode.

## Update from multiple subtitle lines

1. Select the target note in the Anki Browser.
2. Press <kbd>a</kbd> to open the advanced menu.
3. Press <kbd>c</kbd> to capture from the current subtitle.
4. Move through nearby subtitles with <kbd>alt+q</kbd> and <kbd>alt+e</kbd> while refining the selection.
5. Adjust timings if needed with <kbd>s</kbd>, <kbd>f</kbd>, <kbd>S</kbd>, and <kbd>F</kbd>.
6. Press <kbd>b</kbd> to update the selected note, or <kbd>B</kbd> for overwrite mode.

## About overwrite mode

- append mode keeps the update non-destructive where possible
- overwrite mode is for replacing the target fields more aggressively

## Safety limit

The maximum number of selected notes that can be updated is limited by `card_overwrite_safeguard`.

That safeguard exists so that a mistaken Browser selection does not silently rewrite a large number of cards.

## Browser and Editor interaction

Having a note merely visible or selected in the Browser does not normally prevent MPV Anki Clips from updating it. However, if that note is open in an editor with unsaved or stale contents, saving the editor after the API update can overwrite the newer fields. Close the editor without saving, or reload the note before saving any pending edits.

After an update, MPV Anki Clips reads the requested fields back from Anki and reports a mismatch or an unverifiable result. This confirms the state at that moment; it cannot prevent a later save from a stale editor. Updates are not automatically retried, to avoid overwriting concurrent edits.