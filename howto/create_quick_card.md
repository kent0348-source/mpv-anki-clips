# Quick card workflow

The quick-card flow in this fork is designed for media with well-timed subtitles and an existing note-creation workflow outside mpv.

Typical use case:

1. Create a note first with Rikaitan, GoldenDict, or another AnkiConnect-based tool.
2. Return to mpv and use the quick-card flow to update the last added note with media and subtitle text.

## Current bindings

- <kbd>Ctrl+g</kbd> opens the quick line-selection menu
- <kbd>Alt+g</kbd> opens the quick card-count menu

## Quick line-selection menu

After pressing <kbd>Ctrl+g</kbd>:

1. Press a number from <kbd>1</kbd> to <kbd>9</kbd> to choose how many subtitle lines to use.
2. The script then updates the most recently added note using that number of lines.

Inside this menu, <kbd>g</kbd> is a shorthand for choosing one line.

Examples:

- <kbd>Ctrl+g</kbd>, then <kbd>1</kbd>: update the last added note from one subtitle line
- <kbd>Ctrl+g</kbd>, then <kbd>2</kbd>: update the last added note from two subtitle lines
- <kbd>Ctrl+g</kbd>, then <kbd>g</kbd>: same as choosing one line

## Updating more than one recent note

After pressing <kbd>Alt+g</kbd>:

1. Press a number from <kbd>1</kbd> to <kbd>9</kbd> to choose how many recently added notes should be updated.
2. Then press a number from <kbd>1</kbd> to <kbd>9</kbd> again to choose how many subtitle lines should be used.

Example:

- <kbd>Alt+g</kbd>, then <kbd>2</kbd>, then <kbd>2</kbd>: update the last two added notes using two subtitle lines

After the quick-card update completes, the selected card count resets back to the default of one.

## Important differences from older docs

- There is no `gg` binding in this fork.
- The quick-card flow is opened with <kbd>Ctrl+g</kbd>, not plain <kbd>g</kbd>.
- Inside the quick line-selection menu, plain <kbd>g</kbd> is a shorthand for choosing one line.
- Test encodes use <kbd>h</kbd> inside the advanced menu; there is no global test-encode binding.
