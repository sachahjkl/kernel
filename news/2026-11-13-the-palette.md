title: The palette: one panel for the programs and the windows
date: 2026-11-13
release: next
picture: docs/screenshots/palette.png
kind: Shown
guide: docs/DESIGN.md

The key super now opens the palette, which replaces the launcher. It is one panel with one list: the programs that the system can start, the windows that are open, and the commands of the console. With no letter typed, it shows the windows first, then the programs. Each typed letter narrows the list. The match is the fuzzy match of the console: the letters appear in a name in their order, not always side by side, and a line marks each matched letter. Each row says what it is in words. Enter starts the chosen program or brings the chosen window to the front. A command with no argument runs from the panel, which shows a short result; a table opens in the console. A command with arguments opens in the edit line of the console. The close of a window and a command such as shutdown ask for a second Enter, on a red row that says what stops. The typed text is at twice the size of the font, in a band that touches the top, the left and the right edge of the panel, with no frame around it. The panel has no right of its own: a command runs in the console, with the grants of the console.
