title: Windows name things in B612 and show values in Paper Mono
date: 2026-11-12
release: 0.82.0
picture: docs/screenshots/interface_elements.png
kind: Shown
guide: docs/DESIGN.md

The elements of the interface now draw in two fonts. A text that names or explains is in B612: a card title, a label, a button, a line of a list. A value is in Paper Mono: a number, a typed text, a cell of a table. Each window that uses the interface library takes the rule with no change of its code. Measured in the machine, one whole frame of the window of the elements: 264 us in one font, 328 us in two, at a host load above 10. The bar, the menus and the title bars stay in Paper Mono for now.
