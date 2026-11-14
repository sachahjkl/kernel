title: The scroll bar takes the pointer
date: 2026-11-14
release: 0.92.0
picture: docs/screenshots/scroll_bar.png
kind: Shown
guide: docs/DESIGN.md

A scroll bar of the system was a flat rectangle that showed a place. It is now a control. It has an arrow button at each end, a track, and a thumb with a border, a gradient across it and a grip of four lines. With the pointer over it, the bar takes blue tones. A press on an arrow button moves the view by one line, and again while the button is held. A press on the track moves the view by one page. The thumb follows the pointer while it is held. The window of a terminal and the window of the program `manual` have this scroll bar; the lists and the palette show it. Every scroll bar is one element of the interface package, 17 pixels thick. The scroll bars of the site are written from the same table of sizes and colors, in the dark and in the light form.
