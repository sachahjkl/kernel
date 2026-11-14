# The program heron: the animations of the mark in a window

The program `heron` plays the animations of the mark in a window of the system. It is a demonstration of the graphics of the system: a large form that moves each frame, a small damage, and a picture that is shown whole. What it shows and its keys are in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The animations". This file records why it has its form.

## The purpose

- A reader sees the heron move in the system, not only on the site.
- A reader sees how an animation is made: a few cells change, and a move is another drawing in the same cells.
- The program is a load for the window layer that no other program gives: a form of up to 32 by 26 cells changes its place 60 times a second.

The animations play in a program that a reader starts. They never play on a mark beside a text or a control: a picture that moves takes the eye from the text (`docs/DECISIONS.md`, D-180).

## The constraints

- One source of each rule. The site and the program must not hold two copies of a rule that can drift.
- A cell of the heron is a square of one size at a place of the grid, also while the heron moves (`docs/DECISIONS.md`, D-240).
- A test of the program checks a condition, never a time. The play must give the same lines on a slow host.
- The log of the system is shared and bounded. A program that runs for hours must not fill it.

## The chosen form

**The rules are in `src/library/support/mark`.** The cells and the frames, the order of play and the still times (`play.odin`), the forms and the keys of the moves (`motion.odin`) are data and pure procedures there. The kernel tool runs the same procedures to check the script of the site. The program holds no rule: it asks for the next animation, the frame at a time, the form and the place at a time, and draws.

- The rule of the order takes a number of chance as a parameter. A test gives the numbers of a generator with a seed; the program gives numbers of its random generator. The rule itself has no source of chance, so the tool and the program can share it.

**A move on the grid is the rule; the free way is the comparison.** On the grid the program draws the drawn form of `src/library/support/mark` for the frame, at a place in whole cells. The free way reads the same keys, stretches the frame as it is to the box of the form, and moves the box pixel by pixel.

- The free way stretches the frame, not the form. A stretched form would look almost right, and the comparison would show only the travel between two cells. A stretched frame shows what a form is for: the eye is no longer one cell, the beak and the legs change their thickness.
- The grid way is not a filter over the free way. It never draws a scaled picture and never rounds a smooth place: the form and the place are cells from the data.
- The free way lives in one file of the program. It is not a rule of the system, so it is not in `src/library/support/mark`.

**The play goes forward by at most 40 ms for a picture.** A picture that comes late slows the animation. The shortest frame is 70 ms, so each frame is in one picture at least, and the dash always has a picture with the heron outside the window. The lines of the log are then the same on each host: "17 frames", "left the window".

**The stage is a picture of the program, cut in tiles.** Each tile is a Picture record with a generation. A picture of the heron clears and draws two rectangles of the stage and raises the generation of the tiles under them. The window layer then finds a damage of a few tiles by its usual difference: the program tracks no damage rectangle for the window.

**The window is shown whole or not at all.** The surface of the window has two pictures. The program draws one while the compositor reads the other. `Present` names the picture that is complete. The program draws only when the compositor took the picture before.

- This is the one contract of the system for a whole frame. A surface with one picture is memory that the compositor reads while the program writes it.
- The fault that made this rule: the window had one picture. The window layer paints a damage rectangle with the background, then draws its records. The compositor read the rectangle between the two, and one picture of the screen showed the head of the heron with no body. A window that changes a number shows such a mix as nothing. A window that moves a large form shows it as a flicker.
- The cost: each picture of the surface is drawn from its own older frame, two steps of the heron. The damage is about two times the damage of one step. It is still a few tiles.

**Each key writes one line, after the picture.** A line says a state that the screen has: the program writes it after it presented that state. A scenario of a test or of a film waits for the line, then takes its picture.

- An animation of the own order writes a line too, but only the first 32: the heron plays as long as its window is open.
- The line of an animation of the own order does not start as the line of an asked animation. A wait for the dash that a key asked for must not take a dash that chance played.

## The refused forms

- **A copy of the order rule or of the moves in the program.** It was the first form of the moves, for the time when `src/library/support/mark` did not hold them. Two tables drift.
- **A sampling of the cell grid for a squashed heron** (each cell of the wider heron shows the nearest cell of the frame). It keeps square cells, but it leaves out the row under the eye and makes a leg two cells wide. A form is drawn by hand: lines chosen on the heron, then corrections.
- **One Picture record for the whole stage.** It does not make a frame whole: the copy of that picture into a surface with one picture is torn in the same way. And each frame damages the whole stage.
- **A second buffer in the program, copied at the end of a frame.** The stage is that buffer already. The compositor never reads it. The tear is in the surface.
- **Rectangle records for the cells, with no picture.** A cell has a gradient over the box of its part, at an angle. A record has a flat color, or a gradient along one axis.
- **A count of the pictures in a test** ("the dash drew 100 pictures"). It is a speed. The test waits for a line that says what the heron did.
- **A line of the log for each animation, for ever.** It fills the log of the system in an hour.

## The subtle points

- A surface with two pictures needs the table of each picture. Without the memory of the second table, the window layer draws each frame whole, and the damage is the whole window.
- A tile that changed in one step must be drawn in both pictures. The generations do this with no code: the table of a picture holds the generations of its own last frame, so a tile that changed since then differs.
- The program takes its keys also while it waits for the compositor. Only the picture waits.
- The line of what the window shows is written after `Present`, not after the compositor drew. The tool takes a picture when the compositor says that it drew each `Present`.
- The first line of the program says that its window has two pictures, and the main test waits for it. It proves that the program uses the contract. It does not prove that the compositor keeps it.
- The band is in the font of the cells: 8 pixels for a character in both settings of the font. Each text has a box for its longest value, and a box that is too small stops the build.

## The state

Built: the play, the two ways, the tiles, the surface with two pictures, the lines of the log, the exports `play`, `animations` and `grid`, the scenario of the main test and the film.

Left:

- No host test of the free way: a program has no host tests.
- No check that reads the screen for a part of a heron. An exact check needs the compositor to say which picture of a surface it read for a frame, and the program to say which picture it drew: the compositor has no such line.
- The windows with one picture that move a large part each frame (`plasma`, `temple`, `life`) can show a mix of two frames. They copy one whole picture, so the mix is two halves of two frames, not a missing part.
