# Modifying cards added with GoldenDict

You can add a card first using GoldenDict,
and then append an audio clip and a picture to it.

This guide describes the Anki workflow in
[GoldenDict NG](https://github.com/xiaoyifang/goldendict-ng); other GoldenDict builds may provide different Anki integrations.
Read [Setting up GoldenDict](https://tatsumoto-ren.github.io/blog/setting-up-goldendict.html) and
[How to connect with Anki](https://github.com/xiaoyifang/goldendict-ng/blob/staged/website/docs/topic_anki.md)
if you are new to GoldenDict.

To send subtitles from `mpv` directly to GoldenDict,
append the following line to `mpv-anki-clips-core.conf`:

```
autoclip_method=goldendict
```

**Note:** If `goldendict` is not in the PATH,
you have to [add it to the PATH](https://wiki.archlinux.org/title/Environment_variables#Per_user).

To enable the GoldenDict autoclip path while mpv is running:

1. Press <kbd>a</kbd> to open the advanced menu.
2. Press <kbd>z</kbd> to toggle autoclip on if it is off.
3. Press <kbd>Z</kbd> until the autoclip method is `goldendict`.

Now as subtitles appear on the screen,
they will be immediately sent to GoldenDict instead of the system clipboard.

1. Open GoldenDict.
2. Play a video in `mpv`.
3. When you find an unknown word,
   select the definition text,
   right-click and select "send word to anki" to make a card,
   or press <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>N</kbd>.
4. Go back to mpv and update the most recently added note with media and subtitle text.

For that last step, return to mpv and use one of these current flows:

- Open the advanced menu with <kbd>a</kbd>, then press <kbd>Ctrl+m</kbd> to update the most recently added note or <kbd>Ctrl+M</kbd> for overwrite mode.
- Use global <kbd>Ctrl+g</kbd> for the quick-card line-selection menu if you want to update the last added note from a chosen number of subtitle lines.

https://github.com/Ajatt-Tools/mpvacious/assets/69171671/0fc02d24-d320-4d2c-b7a9-cb478e9f0067

Don't forget to set the right timings and join lines together
if the sentence is split between multiple subs.
To do it, enter interactive selection with <kbd>a</kbd> then <kbd>c</kbd>,
and move through nearby subtitles with <kbd>alt+q</kbd> and <kbd>alt+e</kbd> inside the menu.

To pair Mecab and GoldenDict, install [gd-tools](https://github.com/Ajatt-Tools/gd-tools).
