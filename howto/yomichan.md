# Modifying cards added with Rikaitan

You can add a card first using
[Rikaitan](https://tatsumoto.neocities.org/blog/setting-up-yomichan.html),
and then append an audio clip and a picture to it.

To enable clipboard autoclip while mpv is running:

1. Press <kbd>a</kbd> to open the advanced menu.
2. Press <kbd>z</kbd> to toggle autoclip on if it is off.
3. Press <kbd>Z</kbd> until the autoclip method is `clipboard`.

Now as subtitles appear on the screen, they will be immediately copied to the clipboard.
You can use it in combination with clipboard monitor.

1. Open [Rikaitan Search](https://tatsumoto.neocities.org/blog/what-is-yomichan-search)
   by pressing <kbd>Alt+Insert</kbd> in your web browser.
2. Play a video in `mpv`.
3. When you find an unknown word, click the <kbd>+</kbd> button to make a card for it.
4. Go back to mpv and update the most recently added note.

To update the last added note, return to mpv and use one of these flows:

- Open the advanced menu with <kbd>a</kbd>, then press <kbd>Ctrl+m</kbd> to update the last added note or <kbd>Ctrl+M</kbd> for overwrite mode.
- Use global <kbd>Ctrl+g</kbd> for the quick-card line-selection flow.

Don't forget to set the right timings and join lines together
if the sentence is split between multiple subs.
To do it, enter interactive selection with <kbd>a</kbd> then <kbd>c</kbd>,
and move through nearby subtitles with <kbd>alt+q</kbd> and <kbd>alt+e</kbd> inside the menu.
