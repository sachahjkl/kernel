title: The drawing of a window is one module that 23 programs import
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/INTERFACE.md

Each program with a window held its own copy of the code that draws a frame: the damage, the fills, the text and the blends, about 20 KiB in each file. That code is now the module `drawing`. 23 programs import it, and the system holds one copy.

A window calls the module two times for a frame. The first call gives the rectangles that changed since the frame before. The second call draws the records of the frame in these rectangles. Each call passes the tables of the program and the pixels of its surface by address: nothing is copied.

The parts that a program calls many times for a frame stay in the program: the buttons, the lists, the layout, the input. One such call through a module cost about 100 ns more in a measure of one run; a frame has 30 to 200 of them.

The manual and the module graph now show an edge from each of these programs to `drawing`. The programs that show a picture or a grid of text cells, and the compositor, still hold the drawing code: their turn needs a way to name a picture in the description of an export.

A test draws the same frames with the old code path and through the module, in each font, and compares the bytes of the two canvases.
