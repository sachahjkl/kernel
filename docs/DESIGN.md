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

- Rectangular forms are the preference of the design, not an absolute rule (owner, 2026-11-11: "c'est pas une interdiction absolue de tirer que des rectangles, c'est juste que c'est la préférence tendancielle que je veux. Je veux pas que tout soit un blob arrondi en fait."). A form is a rectangle unless another form says more. Any geometry can be drawn, sparingly; a round form can be right in some cases. The look to avoid: everything is a rounded blob. This replaces the rule of 2026-11-10 ("no round corner, no circle and no ellipse").
- A point or a mark is a square.
- A line is a rectangle that is 1 or 2 pixels thick.
- Lines at an angle are allowed (owner, 2026-11-11: "évidemment, les traits obliques c'est autorisé"). The boot display keeps its own use of them: a part that has no measure on this scale (the firmware before the line of time).
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
| Stop a program | `0xB82232` (owner, 2026-11-11: "et ce serait bien que les x de fermeture soit rouge, riche") |
| Not usable | `0x4A5563` |
| Text | `0xDCE4EC` |
| Dim text | `0x7C8A99` |

- The state of a thing has three colors: the color of the boot program while it starts, the color of a program when it runs, the color "failed" when it failed.
- Two neighbours of one concept take two shades of its color, so that their limit is visible.
- If a thing has an identity (a hash), its color can come from the hash. A thing that changes takes a new color.
- A color never stands alone for a fact: a text or a place says the same fact.

## 5. Text

- One font at a time, on the grid of cells of 8 x 16 pixels: the vector font by default, drawn with a coverage for each subpixel band (owner, 2026-11-11: "par défaut il faut une police vectorielle", "Bandes sous-pixel"); Spleen 8x16 as the fallback and as the other value of the setting `font` (`docs/FONTS.md`). Before 2026-11-11 the rule was "One font: Spleen 8x16".
- Three sizes: cells of 1, 2 and 3 times 8 x 16. The vector font draws each size from its outline; Spleen enlarges its pixels. No other size.
- The vector font is monospace: its advance is the width of a cell, so a layout in cells holds with either font. A glyph stays inside its cell.
- An enlarged picture of the screen shows colored edges on each letter: the subpixel bands, not a fault. The setting `subpixel_order` `none` gives gray edges.
- The title of a card is in capital letters, in the bold weight of the vector font, in the accent of the card, after a bar of 4 x 16 pixels in the same accent.
- A name is in the dim color. A value is in the text color. A measure of a concept is in the color of that concept.
- A card has at most one number in the large size: the number that the card is about.
- Numbers of one column are aligned on the right, each with its unit.
- A sentence follows the language rules of the project: short, exact, one term for one concept.

## 6. Grid

- The unit is 8 pixels. A position and a size are multiples of 8, or of 4 inside a form.
- A line of text is 16 pixels.
- The space between two cards is 8 pixels. The margin inside a card is 16 pixels. The title of a card takes 40 pixels.

## 7. Cost

- Drawing is `fill` of rectangles with integer arithmetic. No floating point and no image file. The one drawn data is the glyph cache of the vector font: the kernel tool makes it at build time from the outlines, in integers, and a text draw blends its words (`docs/FONTS.md`).
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
- The close button is a square of 24 x 24 pixels at the right end of the title bar, with the character `x` of the font in white. Its color is the concept "stop a program" (2026-11-11): a deep red `COLOR_STOP_PROGRAM` (`0xB82232`), not the coral of "failed", because to close a window is not a failure. It has the sign of depth of the rules: a block from 118 % of the red at the top to 82 % at the bottom, and a top line at 150 %. When the pointer is over it, the red is brighter (`0xE0343F`). On a window that is not in front, the red is quiet (`0x4E2229`) and the `x` is a dim pink (`0xC09098`). A cross of squares of 2 pixels was tried beside the character `x`: its two lines do not meet on one square at the centre, and it does not match the title; the character stays.
- The compositor places a new window at (60, 52), and each next one 36 pixels to the right and 30 pixels lower, for 8 windows. These numbers are not on the grid: the machine test presses places in windows at these numbers (see "State").
- Cost: the compositor computes the colors of one line of a title bar once, for the columns that the frame shows, then copies them to each line. Choice 265 of `docs/FIRST_MILESTONE.md` has the measures.

### Pointer

- The pointer is an arrow of squares of 2 pixels, 8 squares wide and 11 high: black at the edge, white inside. Its point is the top left square. This arrow is the shape `arrow` of the pointer theme of the system (`resources/pointers/system.manifest`). Each other pointer shape of that theme has the same style: squares of 2 pixels, black and white.
- **Not a rectangle (2026-11-11; since the rule on forms became a preference, this is no longer an exception).** The owner asked for the pointer theme that the owner uses on Linux, "Posy's Cursor" (`docs/POINTERS.md`). Its pointer pictures have smooth edges, curves and transparency: they are not rectangles. The request of the owner, in the words of the dictation: "si tu peux juste bah importer migrer ajuster les posies curseur c'est celui que j'utilise normalement sur Linux". The coordinator recorded this exception, as the nearest form that keeps the rule for the rest: the pointer picture is the one picture resource of the desktop that does not follow sections 2 and 7. It is drawn with a blend of premultiplied alpha. The windows, the bar, the menus, the launcher and each program keep "rectangles only, no round corners" and "no transparency". The owner can reverse this exception: then the theme of the system is the one theme. The same day the owner decided that the theme of the owner is a build input and the default pointer theme when the build has it (`HANDOFF.md` item 33): the exception follows from that decision.

### Launcher

- The key super (the left key with the logo, `display.KEY_SUPER`) opens and closes the launcher. No program uses this key: the compositor keeps it, and the program that has the focus never receives it.
- While the launcher is open, it takes each key: a character adds to the typed part, backspace removes the last one, up and down move the choice (from the last line to the first, and back), Enter starts the chosen program, Escape closes the launcher. A press of the pointer closes it. The program that has the focus receives no key and no pointer event while the launcher is open.
- The panel is a card of 384 pixels in the middle of the screen, on the grid. It has the title `LAUNCHER`, the caption `bar.names`, and the count of the names that match, "6 of 31".
- The input line is a field of 24 pixels in `COLOR_TRACK`, with a line of 2 pixels in `COLOR_TITLE` under it. It shows the typed part in white and a caret of 2 x 16 pixels in `COLOR_TITLE`. When it is empty, it says "type a part of a name" in the dim color.
- The list shows 10 lines. A name matches if it contains the typed part, without the case of the letters. The names that start with the typed part come first, then the others; each group is in the order of `bar.names`. A line of 2 pixels is under the typed part in each name. The chosen line is in `COLOR_TITLE`, with "enter: start" at its right. If more than 10 names match, a bar at the right says which part of the list the panel shows.
- With no match, the list says `no program has "xyz" in its name`, and Enter starts nothing.
- The launcher lists what the menu of the programs lists, from the same table, and starts a program as the menu does: the compositor sends `Start` with the name to the root service. It has no other power.


## 10. Elements

The interface package (`support/interface`, `docs/INTERFACE.md`) draws these elements. A program that uses them follows the rules of this file with no number of its own.

| Element | The rule |
|---|---|
| Background | `COLOR_BACKGROUND` and the grid of points of section 3, at 12 + 24 n of the surface |
| Card | A border of 1 pixel in its accent (28 % to 14 %), the surface of a card, a bar of 4 x 16 pixels and the title in the accent, the caption of its record in the dim color, a count at the right in the text color. Its content starts 40 pixels under its top and 16 pixels inside its sides |
| Line of a label and a value | The label in the dim color; the value in the text color (or in the color of its concept), at the right of its area for a number |
| Table | The titles of the columns in the dim color; lines of 24 pixels; every second line, from the first, on a band of `COLOR_CARD_TOP`; numbers at the right of their column |
| Bar | The track in `COLOR_TRACK`; the full part from 125 % of its color at the top to 78 % at the bottom; 2 pixels at least for a value above 0 |
| Button | A rectangle of the track with its label in the text color; blue (`COLOR_TITLE`) at 60 % when it has the focus or the pointer is over it, full blue with a white label when it is open or both |
| List with a choice | Lines of 24 pixels; the chosen line in `COLOR_TITLE` with its name in white; a line of 2 pixels under a searched part of each name; a bar of 2 pixels at the right when the lines do not fit |
| Text input | A field of the track with a line of 2 pixels at its bottom (`COLOR_TITLE` with the focus, `COLOR_NOT_USABLE` without); the text in white; a caret of 2 x 16 pixels in `COLOR_TITLE` with the focus; the placeholder in the dim color |
| Large number | The font at 3 times its size, drawn from its outline at 24 x 48: the one number of a card (section 5) |

- An element that takes input can take the focus, and the keyboard reaches it: Tab, Enter, Space, the arrows (`docs/INTERFACE.md`, section 4).

## 11. The mark

The mark is the picture that stands for the system (owner, 2026-11-12: "le heron A n°1 est le meilleur, nickel cest simple ! + le logo \"modus\" comme t'as fait super cool").

- The form: a heron on a grid of 24 by 24 square cells. It stands on one leg in water. Its parts: the crest and the tail (one part, in the color of the firmware), the head and the neck (the text color), the eye, the beak and the legs (two parts, in the color of the boot program), the body (the kernel), the wing (`0x2F6FC0`), the water (memory). No line goes around it.
- The data: `support/mark` holds the rows of the cells, the table of the parts with their colors and their boxes, and the letters of the name of the mark. Its procedures are pure: `mark_pixel(cell_size, x, y, on_light)` gives the color of one pixel of the heron, `name_pixel` one pixel of the name, `heron_size` and `name_size` their sizes.
- The gradient: each part is filled with one linear gradient, from the top left corner of the box of the part (the color moved 30 % toward white) to its bottom right corner (the color moved 30 % toward black). A pixel takes the gradient at its centre. The eye is one flat color. The arithmetic is in integers, rounded to the nearest value, so that every machine gives the same pixels.
- The two backgrounds: the background of the system `0x0B1018`, and the light background `0xF4F6F8` of a page of another program. On the light background the neck is darker (`0x9FB2C8`), and the name is in `0x0B1018` instead of the text color.
- The name of the mark: "modus" in letters of 5 by 7 cells, 2 empty columns between two letters, one flat color.
- The files: `kerneltool logo` writes them, and `kerneltool check` fails with "run kerneltool logo" when a file does not have the pixels of the data.

| File | Size | What it shows |
|---|---|---|
| `resources/logo/modus.png` | 1024 x 1024 | The heron (cells of 24) and the name under it (cells of 20), on the dark background |
| `resources/logo/modus_light.png` | 1024 x 1024 | The same on the light background |
| `resources/logo/heron_768.png` | 768 x 768 | The heron alone, cells of 32, on a transparent background |
| `resources/logo/heron_24.png`, `heron_48.png`, `heron_96.png`, `heron_192.png` | 24 to 192 | The heron alone with cells of 1, 2, 4 and 8 pixels, on a transparent background |
| `.project/image.png` | 512 x 512 | The heron alone, cells of 16, centred on the dark background |

- A transparent file keeps the colors of the dark background: its pale neck shows little on a white page. Use `modus_light.png` there.
- The PNG writer of these files is the one of the Odin standard library: it compresses, and it writes an alpha channel. The writer of the pictures of the screen has neither.
- A program of the system can draw the mark from the same data, at any whole cell size. No program does it yet: not the bar, not the boot display.

## State

- The boot display follows all rules.
- The desktop (the compositor: background, bar, menus, windows, pointer, launcher) follows all rules, with one exception: the places of new windows are not on the grid. The main scenario of the machine test presses fixed places in windows at these places; to move them to the grid is to measure each of these places again.
- `clock`, the window of `remote`, the launcher of the compositor, `interface_elements`, `vector_glyphs` and `settings` are built with the interface package (section 10). `errors`, `locks` and `net` take all their colors from `support/graphics`. `log` and `pages` take the background, the text and the dim color from it.
- Each other program takes from `support/graphics` the colors that have a role of the rules: the background, the card (a panel or a band), the text, the dim color, the track (the empty part of a bar), an expected answer (`COLOR_PROGRAM`) and a failure (`COLOR_FAILED`), where its own color had that role. The colors that mean something of one program stay in it: a refusal that the program expects, an answer that is not the expected one (`0xE0B040` in eight programs), the measures of `flow`, `crowd`, `disk` and `clock`, the bars of `budget` and `processors`, the states of `rings`, `threads` and `terminal`, the headings of `manual`, the count of `tally`, the marble of `temple`, the paper of `paint`, the levels of `log`, the kinds of pages of `pages`. Some of them have the value of a rule color with another meaning (`0xE0A040` for kernel entries): a color of the rules for them is a change of meaning, a later step.
- The windows below the level of the boot display, `remote` and `scheduler` (2026-11-11), from the farthest: `temple` (marble and ink, no rule color), `paint` (a light paper), `manual` (its own colors for headings, no cards), `monitor` (one list, no cards), the tables of `budget`, `rights`, `origin`, `limits`, `frames`, `imports`, `processors` (one size of text, bands but no cards and no captions), the measures of `clock`, `crowd`, `flow`, `disk`, then `rings`, `threads`, `workers`, `tally`, `notes`, `life`, and the text of `console` and `terminal`.
