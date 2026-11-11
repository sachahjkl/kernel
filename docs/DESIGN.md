# The design rules

These rules say how a program of this system looks. The owner asked for them on 2026-11-10, after the new boot display: "peut-être extrait en des design rules". They are taken from the boot display (`support/bootscreen/`), which the owner approved. The boot display is the model.

A new graphical program follows these rules. The programs of the desktop that came before do not follow all of them yet: see "State" at the end.

The rules live as one table of constants in `support/graphics/rules.odin`: the grid, the surfaces, the colors of the concepts and the colors of the desktop, with `mix`, `shade`, `block` and `gradient`. The boot display, the compositor and the programs read this table. A program does not repeat a color of the rules as its own constant.

## 1. What is on the screen

- Each thing on the screen is a fact of a record. A display invents nothing.
- Each card has a caption that names its record, for example `Boot_Report.stages`. A person can find the source of each number.
- A record that is all zero is valid. Its card says "not known yet", in the dim color. A card never shows a zero as if it was a measure.
- A size on the screen carries a fact when it can: the width of a stage is its duration, the width of a tile is the size of its module. A form has a least width, so that its name stays readable.
- A step is an interface, not a printed line: a list of steps shows each step with its state ("done", "now", "failed").

## 2. Forms

- Each form is a rectangle. There is no round corner, no circle and no ellipse (owner, 2026-11-10).
- A point or a mark is a square.
- A line is a rectangle that is 1 or 2 pixels thick.
- Lines at an angle are used for one meaning only: a part that has no measure on this scale (the firmware before the line of time).
- There is no shadow and no transparency.

## 3. Surfaces

There are three levels. Each is a constant of the package.

| Level | Color | Use |
|---|---|---|
| Background | `0x0B1018` | Under all cards. A grid of points of 2 pixels, each 24 pixels, lies on it |
| Card | `0x17212E` at the top to `0x111822` at the bottom | The frame of one subject |
| Track | `0x1C2633` | The empty part of a bar, a band or a tube |

- A surface has a color that goes from lighter at the top to darker at the bottom. This is the one sign of depth.
- A card has a border of 1 pixel in its accent, at 28 % at the top and 14 % at the bottom.
- A full part of a bar goes from 120 to 130 % of its color at the top to 78 % at the bottom.

## 4. Color

One color is one concept, as one term is one concept.

| Concept | Color |
|---|---|
| Firmware | `0x8E7CC3` |
| Boot program | `0xE0A040` |
| Kernel | `0x4A9CF0` |
| Program | `0x58D878` |
| Memory | `0x38C0B0` |
| Machine | `0xD070B0` |
| Failed | `0xF06060` |
| Not usable | `0x4A5563` |
| Text | `0xDCE4EC` |
| Dim text | `0x7C8A99` |

- The state of a thing has three colors: the color of the boot program while it starts, the color of a program when it runs, the color "failed" when it failed.
- Two neighbours of one concept take two shades of its color, so that their limit is visible.
- If a thing has an identity (a hash), its color can come from the hash. A thing that changes takes a new color.
- A color never stands alone for a fact: a text or a place says the same fact.

## 5. Text

- One font: Spleen 8x16. Three sizes: 1, 2 and 3 times. No other size.
- The title of a card is in capital letters, in the accent of the card, after a bar of 4 x 16 pixels in the same accent.
- A name is in the dim color. A value is in the text color. A measure of a concept is in the color of that concept.
- A card has at most one number in the large size: the number that the card is about.
- Numbers of one column are aligned on the right, each with its unit.
- A sentence follows the language rules of the project: short, exact, one term for one concept.

## 6. Grid

- The unit is 8 pixels. A position and a size are multiples of 8, or of 4 inside a form.
- A line of text is 16 pixels.
- The space between two cards is 8 pixels. The margin inside a card is 16 pixels. The title of a card takes 40 pixels.

## 7. Cost

- Drawing is `fill` of rectangles with integer arithmetic. No floating point and no image file.
- A display does not wait so that a person can see it. A display that fails stays.
- Each display has a measured draw time in its choice in `docs/FIRST_MILESTONE.md`.

## 8. Decoration

Three things carry no fact: the grid of points on the background, the blue of the head of the boot display, which goes darker toward the right, and the same blue on the title bar of the window in front (section 9). A new decoration needs a decision of the owner.

## 9. The desktop

The desktop is the screen of the compositor: the background, the bar, the windows, the two menus of the bar and the launcher. It follows sections 1 to 8.

### Readings of the request of the owner (2026-11-11)

The owner asked for "a gradient from the current blue, as the start colour, to a darker blue toward the right", then a launcher as an experiment (`docs/HANDOFF.md`, 2026-11-10). Two points were not clear. The coordinator read them as follows on 2026-11-11. The owner can reverse each reading.

- **"The current blue"** is the blue of the title bar of a window, `0x3F7CC4`: the one saturated blue surface of the desktop before this step. The background of the desktop is not that blue: it is the background of the rules now.
- **The launcher** is not the menu of the programs. The menu is a list that the pointer opens from the bar. The launcher is a panel in the middle of the screen that a key opens: the person types a part of a name, and the list narrows at each key. It is the way of the keyboard to start a program. The desktop keeps the menu.

### Background and bar

- The background is `COLOR_BACKGROUND` with the grid of points of section 3. The compositor computes it once, at its start.
- The bar is 32 pixels high, at the top of the screen. It has the surface of a card (`COLOR_CARD_TOP` to `COLOR_CARD_BOTTOM`) and a line of 1 pixel in `COLOR_TRACK` at its bottom.
- The bar holds, from the left: the name of the system; the button `programs`; the button `windows`; at the right, the key of the launcher ("launcher: super") and the time since the start of the machine.
- A button is 24 pixels high, in `COLOR_TRACK`. The button of an open menu is in `COLOR_TITLE`, with its label in white.

### Menus

- A menu of the bar is a card under its button: a border of 1 pixel in the color of the kernel, a title in capital letters, the caption of its source and the count of its lines.
- The menu of the programs has two columns of lines. Its caption is `bar.names`, the table of the names in `support/bar`.
- The menu of the windows has one line for each window, in the order of the client table. The window that has the focus has a square of 8 pixels before its title, and its title is white.
- A line is 24 pixels high. The line under the pointer is in `COLOR_TITLE`, with its text in white.

### Windows

- A window is a title bar of 24 pixels over the surface of its program, with a border of 2 pixels at the left, the right and the bottom. There is no shadow.
- The title bar of the window that has the focus goes from `COLOR_TITLE` (`0x3F7CC4`, the blue of the title bar before the rules) at its left column to `COLOR_TITLE_END` (`0x162C45`, the same blue at 36 %) at its right column. Its top line is 125 % of these colors: the sign of depth of section 3. The bottom border has the colors of the title bar; the left border is the start color, the right border the end color.
- The title bar of another window is quiet: it goes from `COLOR_TITLE_QUIET` (`0x2A3442`) to `COLOR_TITLE_QUIET_END` (`0x161D27`), and its title is in the dim color. So the gradient also says which window has the keyboard. Its title also says it: a title in white has the focus.
- The close button is a square of 24 x 24 pixels at the right end of the title bar, in the end color of the title bar at 70 %, with the character `x`. It is not red: red is the color "failed", and to close a window is not a failure.
- The compositor places a new window at (60, 52), and each next one 36 pixels to the right and 30 pixels lower, for 8 windows. These numbers are not on the grid: the machine test presses places in windows at these numbers (see "State").
- Cost: the compositor computes the colors of one line of a title bar once, for the columns that the frame shows, then copies them to each line. Choice 265 of `docs/FIRST_MILESTONE.md` has the measures.

### Pointer

- The pointer is an arrow of squares of 2 pixels, 8 squares wide and 11 high: black at the edge, white inside. Its point is the top left square.

### Launcher

- The key super (the left key with the logo, `display.KEY_SUPER`) opens and closes the launcher. No program uses this key: the compositor keeps it, and the program that has the focus never receives it.
- While the launcher is open, it takes each key: a character adds to the typed part, backspace removes the last one, up and down move the choice (from the last line to the first, and back), Enter starts the chosen program, Escape closes the launcher. A press of the pointer closes it. The program that has the focus receives no key and no pointer event while the launcher is open.
- The panel is a card of 384 pixels in the middle of the screen, on the grid. It has the title `LAUNCHER`, the caption `bar.names`, and the count of the names that match, "6 of 31".
- The input line is a field of 24 pixels in `COLOR_TRACK`, with a line of 2 pixels in `COLOR_TITLE` under it. It shows the typed part in white and a caret of 2 x 16 pixels in `COLOR_TITLE`. When it is empty, it says "type a part of a name" in the dim color.
- The list shows 10 lines. A name matches if it contains the typed part, without the case of the letters. The names that start with the typed part come first, then the others; each group is in the order of `bar.names`. A line of 2 pixels is under the typed part in each name. The chosen line is in `COLOR_TITLE`, with "enter: start" at its right. If more than 10 names match, a bar at the right says which part of the list the panel shows.
- With no match, the list says `no program has "xyz" in its name`, and Enter starts nothing.
- The launcher lists what the menu of the programs lists, from the same table, and starts a program as the menu does: the compositor sends `Start` with the name to the root service. It has no other power.

## State

- The boot display follows all rules.
- The desktop (the compositor: background, bar, menus, windows, pointer, launcher) follows all rules, with one exception: the places of new windows are not on the grid. The main scenario of the machine test presses fixed places in windows at these places; to move them to the grid is to measure each of these places again.
- `errors`, `locks`, `net` and `remote` take all their colors from `support/graphics`. `log` and `pages` take the background, the text and the dim color from it.
- Each other program takes from `support/graphics` the colors that have a role of the rules: the background, the card (a panel or a band), the text, the dim color, the track (the empty part of a bar), an expected answer (`COLOR_PROGRAM`) and a failure (`COLOR_FAILED`), where its own color had that role. The colors that mean something of one program stay in it: a refusal that the program expects, an answer that is not the expected one (`0xE0B040` in eight programs), the measures of `flow`, `crowd`, `disk` and `clock`, the bars of `budget` and `processors`, the states of `rings`, `threads` and `terminal`, the headings of `manual`, the count of `tally`, the marble of `temple`, the paper of `paint`, the levels of `log`, the kinds of pages of `pages`. Some of them have the value of a rule color with another meaning (`0xE0A040` for kernel entries): a color of the rules for them is a change of meaning, a later step.
- The windows below the level of the boot display, `remote` and `scheduler` (2026-11-11), from the farthest: `temple` (marble and ink, no rule color), `paint` (a light paper), `manual` (its own colors for headings, no cards), `monitor` (one list, no cards), the tables of `budget`, `rights`, `origin`, `limits`, `frames`, `imports`, `processors` (one size of text, bands but no cards and no captions), the measures of `clock`, `crowd`, `flow`, `disk`, then `rings`, `threads`, `workers`, `tally`, `notes`, `life`, and the text of `console` and `terminal`.
