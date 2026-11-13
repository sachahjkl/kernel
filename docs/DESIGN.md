# The design rules

These rules say how a program of this system looks. They are taken from the boot display (`support/bootscreen/`). The boot display is the model.

A new graphical program follows these rules. The programs of the desktop that came before do not follow all of them yet: see "State" at the end.

**Why rules.** One look across the system lets a reader trust what a screen says: a value always has the font of the cells and the color of its kind, a concept always has its color, and each number on a screen names the record that it comes from. The rules live as one table of constants (`support/graphics/rules.odin`), so a change of a color changes every program and the site at once.

**For whom.** A reader who writes a graphical program, and a reader who changes the desktop or the site.

**Read before.** Nothing. `INTERFACE.md` gives the package that draws the elements; `FONTS.md` the fonts.

**The map of this guide.** Sections 1 to 8: what is on the screen, forms, surfaces, color, text, the grid, cost, decoration. Section 9: the desktop. Section 10: the elements. Section 11: the mark. Section 12: the card of the boot image. "State": which programs follow the rules.

![The boot display, the model of the rules: the stages of the start on a line of time, the memory, the machine, the boot image, the programs](screenshots/boot.png)

The rules live as one table of constants in `support/graphics/rules.odin`: the grid, the surfaces, the colors of the concepts and the colors of the desktop, with `mix`, `shade`, `block` and `gradient`. The boot display, the compositor and the programs read this table. A program does not repeat a color of the rules as its own constant.

## 1. What is on the screen

- Each thing on the screen is a fact of a record. A display invents nothing.
- Each card has a caption that names its record, for example `Boot_Report.stages`. A reader can find the source of each number.
- A record that is all zero is valid. Its card says "not known yet", in the dim color. A card never shows a zero as if it was a measure.
- A size on the screen carries a fact when it can: the width of a stage is its duration, the width of a part of a size strip is the size of its file. A form has a least width, so that it stays visible.
- A name is whole or absent: a form that is too narrow for its name shows no name, and the name is said elsewhere when a reader needs it. A name is never cut.
- A step is an interface, not a printed line: a list of steps shows each step with its state ("done", "now", "failed").

## 2. Forms

- Rectangular forms are the preference of the design, not an absolute rule. A form is a rectangle unless another form says more. Any geometry can be drawn, sparingly; a round form can be right in some cases. The look to avoid: everything is a rounded blob.
- A point or a mark is a square.
- A line is a rectangle that is 1 or 2 pixels thick.
- Lines at an angle are allowed. The boot display keeps its own use of them: a part that has no measure on this scale (the firmware before the line of time).
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
| A module with no entry export | `0xC8C058` |
| A resource of the boot image | `0x9AA8C8` |
| Failed | `0xF06060` |
| Stop a program | `0xB82232`: a rich red, the color of the close button of a window |
| Not usable | `0x4A5563` |
| Text | `0xDCE4EC` |
| Dim text | `0x7C8A99` |

- The state of a thing has three colors: the color of the boot program while it starts, the color of a program when it runs, the color "failed" when it failed.
- Two neighbours of one concept take two shades of its color, so that their limit is visible.
- If a thing has an identity (a hash), its color can come from the hash. A thing that changes takes a new color.
- A color never stands alone for a fact: a text or a place says the same fact.

### The colors of code

Code has one set of colors wherever it is shown: on the site, and in the console of the system. The table is `support/graphics/code_colors.odin` (`Code_Class`, `code_class_colors`); the site (`tools/kerneltool/site_code.odin`) and the terminal (`support/terminal/code_runs.odin`) read it. Each class is an accent of the concepts, moved toward white on a dark surface and toward black on the light page of the site.

| Class | What | Accent | Dark: shade, color | Light: shade |
|---|---|---|---|---|
| Keyword | A word of the language | Kernel | 115 %, `0x64AAF2` | 55 % |
| Type | A type, or a name in the place of a type | Firmware | 115 %, `0x9E8FCB` | 60 % |
| Literal | A number, a text, a constant, a member | Memory | 100 %, `0x38C0B0` | 50 % |
| Name | The name of a function or of a declaration | Program | 100 %, `0x58D878` | 45 % |
| Directive | A directive or an attribute | Machine | 115 %, `0xD785BB` | 55 % |
| Comment | A comment, or words that are not code: quiet | Dim | 125 %, `0x9CA6B2` | 60 % |
| Punctuation | An operator or punctuation: quiet | Dim | 140 %, `0xB0B8C1` | 50 % |

- A part with no class has the color of the text around it.
- Each class has at least 4.5 to 1 on each surface that shows code: the block of code of the site in both forms, and the background and the card in the terminal. Host tests compute each contrast.
- On a chosen row (`COLOR_CHOSEN`, section 10), no class keeps that contrast: the row is white.

### The colors of values

A technical value has one color wherever it is shown: on the site, and in the programs of the system that show values of mixed kinds, as the log does. The kinds are the value kinds (`GLOSSARY.md`, `contract/value_kinds`), one enumeration for the site and the system. The colors are one table, `support/graphics/value_colors.odin` (`value_kind_colors`); the site (`tools/kerneltool/site_values.odin`) and the program `log` read it. The site keeps only what is its own: the title, the meaning and the icon of each kind (`docs/SITE.md`, "The kinds of values"). No kind and no color is new: the log uses the kinds of the site, so no new decoration exists.

The kinds that the log writes, on a dark surface (contrast on the background `0x0B1018`, the top of a card `0x17212E`, the band of a row of the log `0x131B26`):

| Kind | Accent | Color | Contrast |
|---|---|---|---|
| Number | Memory | `0x38C0B0` | 8.47 / 7.22 / 7.70 |
| Size | Memory | `0x38C0B0` | 8.47 / 7.22 / 7.70 |
| Time | Boot program | `0xE0A040` | 8.42 / 7.17 / 7.65 |
| Module | Program | `0x58D878` | 10.45 / 8.90 / 9.49 |
| Version | Boot program | `0xE0A040` | 8.42 / 7.17 / 7.65 |
| Status | Failed | `0xF06060` | 5.94 / 5.06 / 5.40 |

- A part with no kind has the color of the text around it.
- Each kind has at least 4.5 to 1 on the background, on both colors of a card and on the band of a row of the log (`support/graphics/value_colors_test.odin`), and on both surfaces of a table of the site in both forms (`tools/kerneltool/site_values_test.odin`).
- A color is never the only sign: the text of the value and its unit say the same fact.

## 5. Text

- **Two fonts** (`docs/FONTS.md`, section 12.6):
  - **The interface font, B612** (proportional): each text that names or explains: the title and the caption of a card, a label, the name of a button, a line of a list or a menu, the title of a column, a sentence of help.
  - **The font of the cells, Paper Mono** (monospace): each value, and each text that a reader compares character by character or copies: a number in a column, a hash, an address, a text that is typed, code, the console, the terminal, a text grid.
  - Both draw in the line of 16 pixels of the grid, at the scales 1, 2 and 3. The places of the elements stay on the grid of 8; the letters of the interface font do not.
  - A text is measured in the font that draws it, and an element cuts a text to its box: no text passes its element in either font.
  - With no interface font (absent, refused, or the setting `font` is Spleen 8x16), each text is in the font of the cells, with the same layout rules.
  - The compositor follows the same rule: the buttons of the bar, the lines of its menus, the titles of the windows, the names and the hints of the launcher are in the interface font; the clock, the date, the text that is typed in the launcher and the counts of the menus are in the font of the cells. The mark and its name in square cells do not change. The places of the buttons and of the lines come from the widths of their texts in the font that draws them (the bar layout).
  - **The boot display, by design, in two steps**: the boot program holds no glyph cache, so the first screen of the machine is in Spleen 8x16, the one font of its binary, as a text grid is. The root service then draws the same display again with the caches of the boot image: the titles of its cards and the names of its facts in the interface font, its values in the font of the cells.
- The font of the cells: the vector font by default, drawn with a coverage for each subpixel band; Spleen 8x16 as the fallback and as the other value of the setting `font` (`docs/FONTS.md`).
- Three sizes: lines of 1, 2 and 3 times 16 pixels; cells of 1, 2 and 3 times 8 x 16 for the font of the cells. No other size.
- The font of the cells is monospace: its advance is the width of a cell, so a layout in cells holds with the vector font and with Spleen. A glyph of the font of the cells stays inside its cell.
- An enlarged picture of the screen shows colored edges on each letter: the subpixel bands, not a fault. The setting `subpixel_order` `none` gives gray edges.
- The title of a card is in capital letters, in the bold weight of the interface font, in the accent of the card, after a bar of 4 x 16 pixels in the same accent.
- A name is in the dim color. A value is in the text color. A measure of a concept is in the color of that concept. Where values of mixed kinds follow one another, as in a line of the log or a table of the site, each value is in the color of its value kind (section 4, "The colors of values").
- A card has at most one number in the large size: the number that the card is about.
- Numbers of one column are aligned on the right, each with its unit.
- A sentence follows the language rules of the project: short, exact, one term for one concept.

## 6. Grid

- The unit is 8 pixels. A position and a size are multiples of 8, or of 4 inside a form.
- A line of text is 16 pixels.
- The space between two cards is 8 pixels. The margin inside a card is 16 pixels. The title of a card takes 40 pixels.

## 7. Cost

- Drawing is `fill` of rectangles with integer arithmetic. No floating point and no image file. The one drawn data is the glyph cache of the vector font: the kernel tool makes it at build time from the outlines, in integers, and a text draw blends its words (`docs/FONTS.md`).
- A display does not wait so that a reader can see it. A display that fails stays.
- Each display has a measured draw time.

## 8. Decoration

Three things carry no fact: the grid of points on the background, the blue of the head of the boot display, which goes darker toward the right, and the same blue on the title bar of the window in front (section 9). No other decoration exists.

## 9. The desktop

The desktop is the screen of the compositor: the background, the bar, the windows, the two menus of the bar and the launcher. It follows sections 1 to 8.

### The gradient and the launcher

- **The gradient** of a title bar goes from the blue of the title bar, `0x3F7CC4`, at its left to a darker blue at its right. The background of the desktop is not that blue: it is the background of the rules.
- **The launcher** is not the menu of the programs. The menu is a list that the pointer opens from the bar. The launcher is a panel in the middle of the screen that a key opens: the input types a part of a name, and the list narrows at each key. It is the way of the keyboard to start a program. The desktop keeps the menu.

### Background and bar

- The background is `COLOR_BACKGROUND` with the grid of points of section 3. The compositor computes it once, at its start.
- The bar is 32 pixels high, at the top of the screen. It has the surface of a card (`COLOR_CARD_TOP` to `COLOR_CARD_BOTTOM`) and a line of 1 pixel in `COLOR_TRACK` at its bottom.
- The bar holds, from the left: the mark of the system (the heron with cells of 1 pixel, 24 by 24, at (16, 4): section 11); the button `programs`; the button `windows`; at the right, the key of the launcher ("launcher: super") and the time since the start of the machine.
- A button is 24 pixels high, in `COLOR_TRACK`. The button of an open menu is in `COLOR_TITLE`, with its label in white.

### Menus

- A menu of the bar is a card under its button: a border of 1 pixel in the color of the kernel, a title in capital letters, the caption of its source and the count of its lines.
- The menu of the programs has two columns of lines. Its caption is `bar.names`, the table of the names in `support/bar`.
- The menu of the windows has one line for each window, in the order of the client table. The window that has the focus has a square of 8 pixels before its title, and its title is white.
- A line is 24 pixels high. The line under the pointer is a chosen row: `COLOR_CHOSEN`, with its text in white (section 10).

### Windows

- A window is a title bar of 24 pixels over the surface of its program, with a border of 2 pixels at the left, the right and the bottom. There is no shadow.
- The title bar of the window that has the focus goes from `COLOR_TITLE` (`0x3F7CC4`) at its left column to `COLOR_TITLE_END` (`0x162C45`, the same blue at 36 %) at its right column. Its top line is 125 % of these colors: the sign of depth of section 3. The bottom border has the colors of the title bar; the left border is the start color, the right border the end color.
- The title bar of another window is quiet: it goes from `COLOR_TITLE_QUIET` (`0x2A3442`) to `COLOR_TITLE_QUIET_END` (`0x161D27`), and its title is in the dim color. So the gradient also says which window has the keyboard. Its title also says it: a title in white has the focus.
- The close button is a square of 24 x 24 pixels at the right end of the title bar, with the character `x` of the font in white. Its color is the concept "stop a program": a deep red `COLOR_STOP_PROGRAM` (`0xB82232`), not the coral of "failed", because to close a window is not a failure. It has the sign of depth of the rules: a block from 118 % of the red at the top to 82 % at the bottom, and a top line at 150 %. When the pointer is over it, the red is brighter (`0xE0343F`). On a window that is not in front, the red is quiet (`0x4E2229`) and the `x` is a dim pink (`0xC09098`). The button shows the character `x`, not a cross of squares of 2 pixels: the two lines of such a cross do not meet on one square at the centre, and the cross does not match the title.
- The compositor places a new window at (60, 52), and each next one 36 pixels to the right and 30 pixels lower, for 8 windows. These numbers are not on the grid: the machine test presses places in windows at these numbers (see "State").
- Cost: the compositor computes the colors of one line of a title bar once, for the columns that the frame shows, with a fixed-point step for each channel (no division for each pixel), then copies them to the 24 lines. At its start it measures three forms of a title bar of 1024 pixels, 64 times each, and writes them on the log. On 10 machines of one check: one color takes 1.6 to 2.7 us, a mix for each pixel 65 to 87 us, one row of colors then copies 5.7 to 6.8 us. The gradient costs about 4 us for each window that a frame draws.
- At 8 bits for each channel, the gradient has 41 levels of red, 80 of green and 126 of blue over the width of a window. The picture shows no band, so there is no dithering.

### Pointer

- The pointer is an arrow of squares of 2 pixels, 8 squares wide and 11 high: black at the edge, white inside. Its point is the top left square. This arrow is the shape `arrow` of the pointer theme of the system (`resources/pointers/system.manifest`). Each other pointer shape of that theme has the same style: squares of 2 pixels, black and white.
- **Not a rectangle.** The theme "Posy's Cursor" (`docs/POINTERS.md`) is a build input. When the build has it, it is the default pointer theme. Its pointer pictures have smooth edges, curves and transparency: they are not rectangles. The pointer picture is the one picture resource of the desktop that does not follow sections 2 and 7. It is drawn with a blend of premultiplied alpha. The windows, the bar, the menus, the launcher and each program keep rectangular forms and no transparency.

### Launcher

- The key super (the left key with the logo, `display.KEY_SUPER`) opens and closes the launcher. No program uses this key: the compositor keeps it, and the program that has the focus never receives it.
- While the launcher is open, it takes each key: a character adds to the typed part, backspace removes the last one, up and down move the choice (from the last line to the first, and back), Enter starts the chosen program, Escape closes the launcher. A press of the pointer closes it. The program that has the focus receives no key and no pointer event while the launcher is open.
- The panel is a card of 384 pixels in the middle of the screen, on the grid. It has the title `LAUNCHER`, the caption `bar.names`, and the count of the names that match, "6 of 31".
- The input line is a field of 24 pixels in `COLOR_TRACK`, with a line of 2 pixels in `COLOR_TITLE` under it. It shows the typed part in white and a caret of 2 x 16 pixels in `COLOR_TITLE`. When it is empty, it says "type a part of a name" in the dim color.
- The list shows 10 lines. A name matches if it contains the typed part, without the case of the letters. The names that start with the typed part come first, then the others; each group is in the order of `bar.names`. A line of 2 pixels is under the typed part in each name. The chosen line is a chosen row: `COLOR_CHOSEN`, with its name and "enter: start" at its right in white (section 10). If more than 10 names match, a bar at the right says which part of the list the panel shows.
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
| List with a choice | Lines of 24 pixels; the chosen line in `COLOR_CHOSEN` with its name and its hint in white; a line of 2 pixels under a searched part of each name; a bar of 2 pixels at the right when the lines do not fit |
| Text input | A field of the track with a line of 2 pixels at its bottom (`COLOR_TITLE` with the focus, `COLOR_NOT_USABLE` without); the text in white; a caret of 2 x 16 pixels in `COLOR_TITLE` with the focus; the placeholder in the dim color |
| Large number | The font at 3 times its size, drawn from its outline at 24 x 48: the one number of a card (section 5) |

### The chosen row

A chosen row is the chosen line of a list, of a menu of the bar, of the launcher, and of the completion list of the terminal.

- Its color is `COLOR_CHOSEN`, `0x3C76BB`: the blue of the title bar at 96 % (`shade(COLOR_TITLE, 96)`). It is not the title blue itself: white has 4.29 to 1 on `0x3F7CC4`, under the 4.5 that a text needs.
- Its text is white: 4.67 to 1. No other color of the rules keeps 4.5 on it: the text color has 3.63, the accent of a match under 3.3.
- A matched character of a chosen row in a grid of cells is the reverse: the chosen blue on a white cell, 4.67 to 1. In a list of the interface font, the line of 2 pixels under the searched part is white.
- A title bar is not a chosen row: it keeps its gradient from `COLOR_TITLE`. An open button draws its white label on `COLOR_CHOSEN` too (4.67).
- A host test computes the contrast of the text and of a matched character on the chosen row (`support/terminal/code_runs_test.odin`).

- An element that takes input can take the focus, and the keyboard reaches it: Tab, Enter, Space, the arrows (`docs/INTERFACE.md`, section 4).

## 11. The mark

The mark is the picture that stands for the system: a heron in pixel cells, and the name "modus".

- The form: a heron on a grid of 24 by 24 square cells. It stands on one leg in water. Its parts: the crest and the tail (one part, in the color of the firmware), the head and the neck (the text color), the eye, the beak and the legs (two parts, in the color of the boot program), the body (the kernel), the wing (`0x2F6FC0`), the water (memory). No line goes around it.
- The data: `support/mark` holds the rows of the cells, the table of the parts with their colors and their boxes, and the letters of the name of the mark. Its procedures are pure: `mark_pixel(cell_size, x, y, on_light)` gives the color of one pixel of the heron, `name_pixel` one pixel of the name, `heron_size` and `name_size` their sizes. `mark_draw(canvas, x, y, cell_size, on_light)` and `name_draw` draw into a canvas of `support/graphics`: the covered pixels only, cut to the canvas.
- The cell size: 1 to `CELL_SIZE_LIMIT` (65 536). Another cell size draws nothing and has a size of 0. A pixel outside the heron or the name is not covered.
- The gradient: each part is filled with one linear gradient, from the top left corner of the box of the part (the color moved 30 % toward white) to its bottom right corner (the color moved 30 % toward black). A pixel takes the gradient at its centre. The eye is one flat color. The arithmetic is in integers, rounded to the nearest value, so that every machine gives the same pixels.
- The two backgrounds: the background of the system `0x0B1018`, and the light background `0xF4F6F8` of a page of another program. On the light background the neck is darker (`0x9FB2C8`), and the name is in `0x0B1018` instead of the text color.
- The name of the mark: "modus" in letters of 5 by 7 cells, 2 empty columns between two letters, one flat color.
- The files: `kerneltool logo` writes them, and `kerneltool check` fails with "run kerneltool logo" when a file does not have the pixels of the data.

| File | Size | What it shows |
|---|---|---|
| `resources/logo/modus.png` | 1024 x 1024 | The heron (cells of 24) and the name under it (cells of 20), on the dark background |
| `resources/logo/modus_light.png` | 1024 x 1024 | The same on the light background |
| `resources/logo/modus_transparent.png` | 1024 x 1024 | The heron and the name in the colors of the dark background, on a transparent background |
| `resources/logo/modus_light_transparent.png` | 1024 x 1024 | The heron and the name in the colors of the light background (the darker neck, the dark name), on a transparent background |
| `resources/logo/heron_768.png` | 768 x 768 | The heron alone, cells of 32, on a transparent background |
| `resources/logo/heron_24.png`, `heron_48.png`, `heron_96.png`, `heron_192.png` | 24 to 192 | The heron alone with cells of 1, 2, 4 and 8 pixels, on a transparent background |
| `.project/image.png` | 512 x 512 | The heron alone, cells of 16, centred on the dark background |

- A transparent file keeps the colors of the dark background: its pale neck shows little on a white page. Use `modus_light.png` there.
- The PNG writer of these files is the one of the Odin standard library: it compresses, and it writes an alpha channel. The writer of the pictures of the screen has neither.
- Where the system draws the mark, always with the colors of the dark background:

| Where | Who draws | What | When the gradients are computed |
|---|---|---|---|
| The bar of the desktop | the compositor | the heron, cells of 1 pixel, at (16, 4) | once, at the start, into a picture of 24 x 24 pixels over the pixels of the bar; each frame copies that picture (a Picture record that never changes) |
| The head of the boot display | `support/bootscreen`: the boot program, the root service, the program `boot` | the heron, cells of 2 pixels (48 x 48) at (20, 12), and the name of the mark, cells of 3 pixels, at its right | at each draw of the display: one call for each of the 2 304 pixels of the box of the heron and the 2 079 pixels of the box of the name, a few integer divisions each |

- No file of the mark is in the boot image: each place draws from the data.

### The animations

The mark has idle animations. Several animations play in turn. They play only on the large mark of the home of the site and on the icon of its tab, and they respect the choice of the visitor about motion.

- An animation of the mark moves a few cells of the still heron. It does not draw the bird again. The data is in `support/mark/animation.odin`, beside the table of the still heron, in the same cells and letters. A cell that moves takes the gradient of its part over the box of that part in the still heron.

| Animation | Frames (duration, cells changed from the still heron) | Time | Weight |
|---|---|---|---|
| blink | the eye closes (150 ms, 1) | 150 ms | 6 |
| look | the head and the beak one cell forward (800 ms, 11); still (250 ms, 0); one cell back (800 ms, 12) | 1850 ms | 3 |
| leg | the knee of the raised leg half in (200 ms, 2); in (500 ms, 6); half in (200 ms, 2) | 900 ms | 2 |
| ripple | one cell of water above the line at each side of the legs, two columns farther at each frame (4 frames of 180 ms, 2 each) | 720 ms | 3 |
| dip | the head one row lower (300 ms, 23); the eye closed (250 ms, 22); open (350 ms, 23); a swallow down the front of the neck (3 frames of 220 ms, 1 each) | 1560 ms | 1 |
| preen | the head three rows lower, the neck curved (250 ms, 43); the head turned back, the beak above the body (250 ms, 43); the head folded on the back, the tip of the beak on the body (300 ms, 47); two strokes: the tip leaves the body and a feather lifts (180 ms, 47), back in the feathers (180 ms, 47); then the same poses up (250 ms each) | 2090 ms | 1 |
| scratch | the knee in, the pose of the leg animation (200 ms, 6); three strokes on the ground: the foot forward on the row of the ground (220 or 200 ms, 8), pulled back one column with one cell of water lifted behind it (220 ms, 9); the knee in again (200 ms, 6) | 1680 ms | 1 |

- The order of play, which repeats (about 80 seconds: 64.1 s still and 15.7 s of animations): 3 s blink, 4.8 s ripple, 2.2 s blink, 4 s look, 5.2 s blink, 3.4 s preen, 2.6 s ripple, 4.4 s blink, 5.5 s dip, 3 s look, 3.7 s blink, 5 s scratch, 2.4 s leg, 4.2 s blink, 3.3 s ripple, 2.8 s leg, 4.6 s look. The owner found the first still times a little too long (2026-11-12: "un peu trop large"); they were 3 to 8 s. Each time is the still time before the animation. No animation follows itself. No random number is used.
- The preen and the scratch: in the preen the bird bends and scratches its body; in the scratch it scrapes the ground with its front foot. In the scratch the body does not dip: the body, the wing and the tail one row lower change 46 cells (counted on the table), five times the cells of a stroke of the leg, and the leg reads alone.
- The bounds, which the host tests hold: each animation has its limit of changed cells in the data (`animation_change_limits`): a frame differs from the still heron and from the frame before it by at most 24 cells, or 48 for the preen, which moves the whole head onto the back; a frame lasts 150 to 1000 ms, so the picture changes at most about 6 times each second; an animation lasts at most 3 s; a still time is 2 to 6 s.
- The sprite sheets of the site hold 22 sprites: the still heron and 21 distinct frames. A sheet of the home is 4356 x 250 pixels (198 for each sprite), in one row: under the 8192 pixels that a browser decodes. The sheet of the icon is 704 x 32.
- Where it plays: the large heron of the head of the home of the site, and the icon of the tab of the home. Not the small mark of the bar of the site, and not the desktop of the system yet.
- Reduced motion: when the browser says that the visitor asks for reduced motion, nothing moves, and the still picture stays. A change of that choice while the page is open stops or starts the play.
- A hidden tab: the play stops, no timer runs, and the icon is the still icon again.
- `kerneltool logo` writes `build/mark_animations.png`: each animation as a row of its frames at cells of 8 pixels, with the durations and the order of play, for a reader to look at.
- The desktop of the system does not play the animations. The data is ready for it: `animation_frame_cells` gives the cells of a frame, and `cells_draw` draws them. To play them, the compositor needs one picture of 24 x 24 pixels for each distinct frame, drawn at the start as the still heron is. It also needs one timer that changes the generation of the Picture record of the bar at the times of the order of play.

## 12. The card of the boot image

The card "BOOT IMAGE" of the boot display says which files the boot image holds, by kind, and what the check of their hashes found. It has 536 x 130 pixels of content, whatever the count of files. Package `support/bootscreen/image_card` computes its places; the boot program, the root service and the program `boot` draw them. It uses integers only and allocates nothing.

- **The kinds**: "programs" are the modules with an entry export; "no entry" are the modules with no entry export, which other modules import; "resources" are the files of the resource table. The kernel is not in the boot image: the card of the machine gives its size, and the line of the check counts it.
- **The size strip**, 12 pixels high, at the top: one size strip for all the files, by kind, then from the largest file to the smallest. A part is at least 2 pixels wide, 4 for the failed file. The parts fill the width exactly. If the files need more than the width at their least, the smallest files have no part; the failed file always has one. Two parts that touch take two shades of the color of their kind. The strip has no names.
- **The rows of names**, 4 rows of 18 pixels under the strip. Each kind has one row at least: the color of the kind, its name, its count and its bytes. Then the tiles: the names of its largest files, from the largest. A tile is as wide as its whole name. The first name that does not fit ends the kind, so a smaller file never takes the place of a larger one. The count of the files with no tile ("+55") follows the last tile, in the dim color. The rows that are left go, one at a time, to the kind with the most files with no tile.
- **The line of the check**: the count of the files that have the hash of the system description, the kernel included ("85 verified, the kernel included"); or, after a failure, "failed: " and the whole name of the file, in the color of a failure; or "no file verified" when the check failed before the files (a wrong signature). The part and the tile of the failed file are in the color of a failure.
- **The line of the trust** is the last line (`docs/TRUSTED_BOOT.md`, section 4).

With the boot image of the last build (77 modules and 9 resources), the card names 12 files: 7 programs in two rows (`console`, `root`, `temple`, `remote`, `vector_glyphs`, `errors`, `address_space`), 3 modules with no entry and 2 resources. A host test holds this count.

## State

- The boot display follows all rules.
- The desktop (the compositor: background, bar, menus, windows, pointer, launcher) follows all rules, with one exception: the places of new windows are not on the grid. The main scenario of the machine test presses fixed places in windows at these places; to move them to the grid is to measure each of these places again.
- `clock`, the window of `remote`, the launcher of the compositor, `interface_elements`, `vector_glyphs` and `settings` are built with the interface package (section 10). `errors`, `locks` and `net` take all their colors from `support/graphics`. `log` and `pages` take the background, the text and the dim color from it.
- Each other program takes from `support/graphics` the colors that have a role of the rules: the background, the card (a panel or a band), the text, the dim color, the track (the empty part of a bar), an expected answer (`COLOR_PROGRAM`) and a failure (`COLOR_FAILED`), where its own color had that role. The colors that mean something of one program stay in it: a refusal that the program expects, an answer that is not the expected one (`0xE0B040` in eight programs), the measures of `flow`, `crowd`, `disk` and `clock`, the bars of `budget` and `processors`, the states of `rings`, `threads` and `terminal`, the headings of `manual`, the count of `tally`, the marble of `temple`, the paper of `paint`, the levels of `log`, the kinds of pages of `pages`. Some of them have the value of a rule color with another meaning (`0xE0A040` for kernel entries): a color of the rules for them is a change of meaning, which is not done.
- The windows below the level of the boot display, `remote` and `scheduler`, from the farthest: `temple` (marble and ink, no rule color), `paint` (a light paper), `manual` (its own colors for headings, no cards), `monitor` (one list, no cards), the tables of `budget`, `rights`, `origin`, `limits`, `frames`, `imports`, `processors` (one size of text, bands but no cards and no captions), the measures of `clock`, `crowd`, `flow`, `disk`, then `rings`, `threads`, `workers`, `tally`, `notes`, `life`, and the text of `console` and `terminal`.
