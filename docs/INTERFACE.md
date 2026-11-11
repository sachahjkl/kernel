# The interface of the programs

Status: designed on 2026-11-11 by the desktop agent, at the request of the owner (`HANDOFF.md`, item 25). The owner has not reviewed it. The coordinator decided that the system has an interface module and that the design comes first.

Words of the owner: "pour ce qui est rendu graphique, même si on fait su software rendering, faudrait anticiper à faire les choses "bien" et avoir (un module ?) de la logique bien cadrée pour le Ui rendering, avec le "damage", le layouting, etc etc (font rendering even maybe ? [...]) [...] we need to lay good, robust, featurful foudations early rather than late", and "for slug/text/gui it's fine to LOOK AT gui_toolkit, not USE IT".

The terms of this document are in `GLOSSARY.md`, section "Desktop": interface package, draw record, draw table, element, element identity, damage by difference, interface state.

## 1. What the programs draw today

Counted on 2026-11-11 (`master` `cbe3c0e`) with `grep` over `programs/*/` and `support/`:

| Fact | Count |
|---|---|
| Programs that draw with `support/graphics` | 34, with 13 995 lines in all |
| Lines that call a drawing function (`fill`, `text`, `block`, `unsigned`, `character`, ...) | 591 |
| Programs that draw a card or a band of a card by hand | 21 |
| Private copies of the procedure `card` (frame, accent bar, title, caption) | 5: the boot display, the compositor, `remote`, `scheduler`, `server` |
| Private copies of large text (each pixel of the font as a square) | 5: `large` in `remote`, `scheduler`, `terminal`; `write_large` in the boot display and `server` |
| Programs that draw a bar on a track | 15 |
| Programs that draw a table (a header, columns, bands) | 8 |
| Lists with a choice | 3: the menus and the launcher of the compositor, `manual`, `errors` |
| Text inputs with a caret | 2: the launcher, `terminal` (`console` draws through the terminal) |
| Programs that react to the pointer | 7; to the keys: 9. Each one tests rectangles by hand |
| Programs that track damage | 1: the compositor. Each other program draws its whole surface for each change, and `Present` damages the whole surface |

After this count, the developer tool `inspect` came (step 50): a list with a filter and a choice, a band, tables and a hex view, all by hand. It is the next user in the order of the next steps.

Each card, bar, table and list is drawn again in each program, with its own numbers of pixels. A change of the rules (the close button of 2026-11-11, the colors of step 50) touches each program.

## 2. The model: an immediate pass over flat tables

**Choice: immediate mode.** Each frame, the program describes its whole window again, in code: `card`, `label_value_line`, `bar`, `button`. Each call appends fixed-size draw records to a draw table that the program owns, and gives back what the input did to that element ("pressed", "has the focus", "the text changed"). There is no tree of objects that lives between frames, no callback, no allocation.

Why, against a retained tree of widgets:

- The state of a window is the state of the program. A retained tree is a second copy of it that must be kept in step, which is the source of most interface faults. In immediate mode, a window cannot show a value that the program does not have.
- The output is data: a table of records of one size, in the memory of the caller (P14). A table can be compared, measured, sent to another rasterizer, or written to a file to test it.
- A retained tree gives damage for free: a node that changed knows its rectangle. Immediate mode loses that. Section 2.2 gives it back without a tree.

### 2.1 Draw record (format version 4)

A draw record is 40 bytes. The fields are little-endian, in this order:

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `kind` | u8 | `None` 0, `Rectangle` 1, `Vertical_Gradient` 2, `Horizontal_Gradient` 3, `Text` 4, `Clip` 5, `Point_Grid` 6, `Folded_Gap` 7 (version 2), `Picture` 8 (version 2), `Text_Grid` 9 (version 3), `Line` 10 (version 4) |
| 1 | `text_scale` | u8 | Text: 1, 2 or 3 (DESIGN.md, section 5) |
| 2 | `text_subpixel_x` | u8 | Text: the position after `x` in 1/64 of a pixel. 0 for Spleen 8x16, which places each glyph on a whole pixel |
| 3 | `line_thickness` | u8 | Line: the thickness in pixels, 1 to 32. 0 for the other kinds (version 4; it was `reserved`) |
| 4 | `x`, `y`, `width`, `height` | 4 x i32 | The rectangle of the record, in pixels of the surface. For text, the rectangle that the run covers. For a line, the first end, and the second end minus the first: `width` and `height` can be negative |
| 20 | `first_color` | u32 | `0x00RRGGBB`: the color of a rectangle or a text; the top or the left color of a gradient |
| 24 | `second_color` | u32 | The bottom or the right color of a gradient |
| 28 | `text_start`, `text_count` | 2 x u32 | Text: the bytes of the run in the text table of the draw table. Picture: the index of the picture in `Draw_Table.pictures` and its generation. Text grid: the index of the grid in `Draw_Table.grids` |
| 36 | `element` | u32 | The low 32 bits of the element identity that wrote the record, 0 for none: a tool can say which element changed |

- `Clip` sets the rectangle that the next records are cut to, until the next `Clip`; a `Clip` of width 0 ends the cut.
- **No stack of clips**: a `Clip` replaces the cut, and a `Clip` of width 0 removes each cut. An element that clips inside an area that is already clipped removes the outer clip. A caller that nests clips writes the intersection itself, and ends with the outer clip again.
- **Places and sizes**: each edge of a record is cut to 2^30 pixels from the corner of the surface (`COORDINATE_LIMIT`), then the size is the difference of the two edges. A rectangle that covers the surface with places past the `i32` still covers it.
- **`full` and `refused`**: `full` says that a record or a text did not fit in the table. The table is not the frame, so the next frame of that picture is drawn whole. `refused` says that a record could not be made: a picture or a grid that the table does not have, or a grid whose cells are fewer than its rows. That record is missing, and each other record is in the table, so the difference stays exact.
- **Grids with large numbers**: `grid_valid` divides in place of a product, so a count of rows or a stride near the largest `int` cannot wrap and pass the check.
- A version number (`DRAW_RECORD_VERSION`, 4) is beside the format, as for the contracts. A new kind is a new version.
- The text of a run is in the text table of the draw table, not in the record: a record stays 40 bytes, and two runs with the same bytes compare equal.
- A `Picture` record shows the pixels of a picture of the caller. The program raises its generation when its pixels change; with the same generation the record compares equal and damages nothing. `life`, `paint`, `plasma`, `temple` and the surfaces of the windows in the compositor are pictures.
- A `Text_Grid` record shows a grid of text cells of the caller (`Text_Grid_Cell`: a character, reverse, a color). Its 40 bytes do not change when its cells change: the difference compares the cells (section 2.4).

### 2.2 Damage by difference

The program keeps the draw table of the last frame that it drew (a second table, its own memory). After it builds the table of this frame, `damage_by_difference` compares the two tables, record by record, at the same index:

- Two records at one index are equal if their 40 bytes are equal and the bytes of their texts are equal. Nothing is damaged.
- If they differ, the rectangle of the old record and the rectangle of the new one are damaged: the old one must be painted over, the new one painted.
- The records after the end of the shorter table are damaged.
- The rectangles merge as in the compositor: rectangles that touch become one; with no room left (`DAMAGE_CAPACITY` 8), a new rectangle joins the first one.

Then `execute_in_rectangles` draws again, in each damage rectangle, each record of the new table that touches it, cut to the rectangle. The program never tracks damage by hand.

- **The limit of the index rule**: a record added in the middle of the table moves all the records after it, and they all compare as different: the damage is too large, never too small. It is right, and it costs only time. An element identity in each record (offset 36) allows a later rule that matches records by identity; it is not needed by the first users.
- **Two pictures**: a surface with two pictures needs the table that was drawn in the picture that the program draws now, which is the table of two frames before. The caller keeps one table for each picture. The program draws the difference with its own picture, but it presents also the difference with the picture that the screen shows (`damage_of_two_pictures`): a frame equal to its own picture can differ from the screen. Without that rule the terminal showed rows of two different frames (host test `two_pictures_screen_is_each_frame`).
- **The table of the shown picture is not known** (its copy failed, or it is full): the screen can show records of an older frame where the frame now draws nothing. The present is then the whole surface (host test `two_pictures_unknown_shown_table_presents_all`).
- **A new font**: on `Settings_Changed`, each record stays the same and each pixel of text changes. `window_events` calls `draw_whole_window_next`, which makes the next frame of each picture whole. The terminal and the manual read their events by themselves and call it.
- **A present that is lost**: `display.present_rectangle` gives false when the command ring is full. The picture then counts as not drawn, and its next frame is whole: with one picture, the next difference would see no change, and the screen would keep the old pixels.
- **Present with a rectangle**: `display.present_rectangle` gives the compositor the union of the damage: the compositor draws again only that part of the window (the protocol had a gap there: `Present` damaged the whole surface). A full rectangle stays the default of `display.present`.
- **The cost**, measured by the program `interface_elements` on its window of 68 records (choice 328 of `FIRST_MILESTONE.md`): nothing changed, 0 rectangles in 0.8 us; one number changed, 3 rectangles in 0.8 us; everything moved, 1 rectangle in 1.8 us: about 13 ns for each record. The whole frame is drawn in 366 to 411 us, a frame in its damage in 89 to 120 us. `clock` draws one picture in 11.6 us against 109.2 us by hand.

### 2.3 Memory of the caller, errors as values

- The caller gives the draw table (`records: []Draw_Record`, `text: []u8`) and the interface state. The package never allocates. Its core files make no kernel call; `window_drawing.odin` reads the events of a window and presents its surface.
- On the surface of a program, each damage rectangle is painted with the background before the records draw again (`draw_damage_on_surface`), and a whole frame starts from the background: a record that a frame no longer has leaves no pixel, with no rule for the caller. The compositor draws its panels over other windows, so it draws the records only.
- A table that is full stops taking records and keeps the flag `full`: the frame is drawn without the records that did not fit, the program can test the flag and write it on its log. No element fails in silence.
- An element gives its result as a value (`Element_Result`): pressed, has the focus, changed. Nothing is hidden in a context.

### 2.4 Text grid

A text grid is the element of the terminal: up to 104 x 32 cells, which a program changes many times in one second.

- The table of the frame now names the cells of the caller; each table before keeps its own copy of the cells that its picture shows (`draw_table_copy` copies them, about 26 KiB for each table of the terminal).
- The difference damages, in each row, the span from the first changed cell to the last one; the rectangles merge as in section 2.2. A grid that changes its size is damaged whole.
- The execution draws the cells of one color that follow each other as one text, so the text goes through `graphics.text_scaled` (and the glyph cache of the vector font) once for each run.
- The console draws no pixels: it writes records into its terminal, so the text grid of the terminal is the drawing of the console too.

### 2.5 Line

A `Line` record draws a straight line between two points, with a thickness, in one color: `draw_line(table, from_x, from_y, to_x, to_y, thickness, color)`.

- **The pixels**: the path of `graphics.line` (the line of Bresenham, integers only), with a square of the thickness at each point of the path. An even thickness starts one pixel before the point. The pixels are the same at each build and on each part of the surface: the execution in a damage rectangle walks the same path and cuts the squares.
- **One order**: `draw_line` writes the left end first, or the top end when the two ends have one x. A line and its reverse are one record, so they draw the same pixels and compare equal.
- **The damage**: the rectangle that holds each square of the path (`line_rectangle`). Pieces of the path would be tighter on a diagonal, but the damage list joins rectangles that touch (section 2.2), and the pieces of one line touch: the list would make them one rectangle again. A diagonal across a window damages its whole bounding rectangle.
- **Hostile values**:
  - A thickness of 0 or less gives no record. A thickness past 32 (`LINE_THICKNESS_LIMIT`) is cut to 32.
  - An end past 32 768 pixels from the corner (`LINE_COORDINATE_LIMIT`) gives no record. A cut end would change the slope, so the record would be another line. The bound exists because the execution walks each point of the path.
  - A record written by hand with a thickness of 0, a thickness past 32, or an end past the bound covers nothing: no pixel, no damage.
  - A line of length 0 is one square of its thickness. A line fully outside the area is cut away like each record.
- **The cost bound**: one execution walks at most 65 537 points and fills at most 32 x 32 pixels for each point inside the area.
- **Limits**: no rounded ends, no antialiasing, no dashes. Lines at an angle are allowed, sparingly (DESIGN.md, section 2).
- `draw_outline` appends the border of a rectangle as four rectangles, the same pixels as `graphics.outline`.

### 2.6 Window places

The compositor puts each window on the grid of 8 pixels (`support/bar/window_place.odin`, procedures with no state and their host test).

- A window that a person drags goes to the nearest point of the grid, then stays where 8 pixels of its title are on the screen, under the bar. At the left, the end of the title is at 8 or more, so the close button is on the screen too. Without that bound, a window dragged past an edge could not come back: the menu of the windows only brings a window to the front.
- A new window that fits stays at the place that the compositor chose, moved up and left until it fits. A window wider than the screen puts its close button at the right of the screen; a drag shows its left part. A window higher than the screen starts under the bar.

## 3. Layout

- The unit is the grid of 8 pixels (DESIGN.md, section 6). An `Area` is a rectangle of the surface.
- **A column** gives areas from the top of its area to the bottom: `column_take(&column, height)`. The height of a line of text is 16, a line of a table 24.
- **A row** splits an area into columns in one pass: the caller gives the sizes of all the columns before it draws in them, so the row knows each width at once. A size is `Pixels` (a fixed width), `Characters` (a count of characters of the font: the width that the text measure gives) or `Share` (a part of what the fixed sizes leave, in proportion to its value). A gap is between two columns.
- **Alignment**: text is at the left, or at the right of its area (numbers, DESIGN.md section 5), and in the middle of the height of a line.
- **One pass.** There is no tree and no constraint solver: what is not known before the row (the width of a text that the program has not made yet) is measured by the caller with `text_width` first. `gui_toolkit` solves sizes in five passes over a tree of boxes (standalone, upward, downward, violations, positions): the windows of this system have fixed sizes, and one pass with sizes declared before content covers each window of section 1.

## 4. Input and focus

- The program gives each frame an `Input` record, filled from the `display.Event` records of the frame: the place of the pointer, a press and a release of the left button, and the keys pressed in this frame (at most 16).
- **Element identity**: an element that takes input has an identity, a u64 that the caller makes from a text with `identity("launcher list")` (the 64-bit FNV-1a hash of the text). The identity must stay the same from one frame to the next for one element. Two elements with one text have one identity: `identity_with(base, row)` and `identity_in(parent, name)` make them two, and `Frame.identity_collisions` counts the elements of a frame that repeat an identity (a host test).
- The order of Tab holds 64 elements (`FOCUS_ORDER_CAPACITY`); an element after them takes a press but not Tab, and `Frame.focus_overflow` counts them.
- **The interface state** (memory of the caller, 2 KiB) keeps between frames: the element that has the focus, the element under the pointer, the element pressed and not yet released, and the order of the elements that can take the focus in the last frame.
- **The keyboard is a first path**: Tab and Shift+Tab move the focus in the order of the elements of the last frame; Enter and Space press the button that has the focus; up and down move the choice of a list that has the focus; a text input that has the focus takes the characters and Backspace. The launcher of the compositor is the model: each thing that the pointer does, a key does.
- **The pointer**: an element under the pointer is "under the pointer" (the close button of a window is brighter); a press and a release on one element press it. A press on an element gives it the focus.

## 5. Text

- **The interface of the text** is two functions and one record: `Font` (`kind`, `scale`), `text_width(font, text) -> pixels` and the record `Text` of section 2.1 with `text_scale` and `text_subpixel_x`, with the scales 1, 2 and 3.
- **The font of the system** (2026-11-11, `docs/FONTS.md`): the vector font by default, from the glyph cache that the root service maps, with a coverage for each subpixel band; Spleen 8x16 as the fallback and as the other value of the setting `font`. Both are monospace on cells of 8 x 16, so `text_width` and the layout do not change with the setting, and `text_subpixel_x` stays 0 on the grid. `execute` draws a text record with `graphics.text_scaled`: the package does not know which font draws.
- **A change of the setting** comes as the display event `Settings_Changed`: `window_events` marks the window as not drawn, and the next frame draws it whole (each draw record is the same, each pixel of text is not).
- A proportional font later is a second `kind`: it fills `text_subpixel_x`, and its glyph cache has subpixel positions. The callers do not change.

## 6. The output and its execution

- `execute(table, canvas)` draws each record into a canvas of the program (its surface), in order: `Rectangle` is a `fill`, `Vertical_Gradient` is the `block` of the rules, `Horizontal_Gradient` is the `gradient` row of the title bar, `Text` is the font of the system.
- `execute_in_rectangles(table, canvas, rectangles)` draws, for each rectangle, the records that touch it, cut to it.
- **A later back end** (property 18, WebGPU): the same table is the input of a GPU pass: one instance for each record, the gradients in the vertex colors, the text from an atlas or from outlines (section 9). The format has no pointer and no field that only the processor can read.

## 7. Where it lives: a `support` package now, a module when the contract can describe its calls

Two forms were weighed:

| | A module with exports (P10) | A package of `support` |
|---|---|---|
| Code pages | One copy, shared by hash by each program that imports it (P11) | One copy in each program; the hash of each program changes with the package |
| The cost of a call | 3.9 ns through an import slot (measured by `imports`, step 35); about 200 element calls for one frame: under 1 us | 0: a direct call, often inlined |
| What the call passes | Must be described by the module contract (section 5 of `MODULE_CONTRACT.md`) | Any Odin type |
| A replacement of the module | Each program takes a new version with no new build (Replacement of an import) | Each program is built again |

The module is the right form: the interface is shared code, as P10 and P11 say. It is not possible today: the calls of the interface pass tables of the caller (the draw table, the rows of a list, the columns of a row), and the description of an export cannot describe a table as a parameter (`FIRST_MILESTONE.md`, the gaps of property 19). Passing an address as an Integer would work in a direct call and mean nothing in an isolated call: it breaks the contract.

**The choice**: `support/interface`, a package that a program compiles in, written as a module would be: each function takes the tables of the caller and fixed-size records, no global state, no callback. When the description gains "a table as a parameter", the package becomes a module with the same functions as exports, and the programs import it. This is a decision for the owner (section 10).

**The test of the claim** (2026-11-11, after tables as parameters, `MODULE_CONTRACT.md`): the module `interface_module` has eight exports that call the functions of the package with no change to the package: the draw table is a `Table(Draw_Record, Append)`, the text table `Bytes(Append)`, an area a Record, the area of the content of a card a `Table(Area, Change)` of one row, the pixels of the canvas `Bytes(Change)`, the damage a Table result. The program `interface_through_module` imports it, builds one frame through it and the same frame with the package compiled in: the two draw tables are equal, record for record. What the claim missed: (1) the calls are not the same calls: a function of the package takes a `^Frame` (three addresses: the table, the state, the input), which a description cannot carry; an export takes the two tables and the records of its element, and makes a frame over them for one call. (2) The record `Draw_Record` has fields of 1 and 4 bytes, which the description could not describe before this step (Integer fields of 1, 2 and 4 bytes are added). (3) The elements that take input (a button, a list, a text input) keep the interface state of the program between frames: as exports they need the state as a `Table(Interface_State, Change)` of one row; not done in this step. Measured: about 10 ns more for each element call than the package compiled in (25 calls, 523 ns against 283 ns for one frame); the module has 14 980 bytes of code, against 8 865 bytes of functions of the package in `clock` and 24 948 bytes in `interface_elements` (the functions that the compiler did not inline).

## 8. Property 20 and the compositor

- The package draws only into the canvas that the caller gives: a program draws only into its own surface. The package has no handle and makes no kernel call (P20: no ambient access).
- The compositor is a user of the same package: its launcher is built as a draw table, executed into its frame, and damaged by difference as each program's window is.

## 9. Text: a vector font, research note and prototype

This section is the research of step 51. The owner decided on 2026-11-11: a vector font by default, with subpixel bands, Spleen 8x16 as the fallback. The design that was built is `docs/FONTS.md`: a rasterizer in fixed point, a glyph cache made at build time, JetBrains Mono by default. The prototype below (floating point, no cache) is replaced.

### What Slug does

Slug (Eric Lengyel, JCGT 6(2), 2017, <https://jcgt.org/published/0006/02/02/>) draws a glyph from its quadratic Bézier curves in the pixel shader, with no bitmap. For each pixel, it casts a horizontal and a vertical ray, finds where each ray crosses each curve of the glyph (the roots of a quadratic, with a robust classification of the end points so that no pixel drops or sparkles), and takes the coverage of the pixel from the signed distances of the crossings: an antialiased edge that is exact at any scale and under any transform. To keep the work small, the glyph is cut into horizontal and vertical bands, and each band lists only the curves that touch it, sorted so that the shader stops early. Since 2019, "dynamic dilation" grows the box of each glyph by half a pixel on the screen in the vertex shader.

### Its state today (verified on 2026-11-11)

- **Patent**: US 10,373,352 (granted 2019, to 2038). On 2026-03-17 its author filed USPTO form SB/43 and paid the fee to disclaim the rest of its term, "permanently and irrevocably dedicating the Slug patent to the public domain" (<https://terathon.com/blog/decade-slug.html>, "Patent Announcement"; also <https://blog.adafruit.com/2026/03/22/slugs-out-the-algorithm-that-made-text-look-perfect-is-now-free-or-how-to-give-away-a-patent/>). Google Patents still shows the patent as "Active": that site does not show the disclaimer of 2026; this is the state of an aggregator, not a contrary fact. I could not read the USPTO record itself.
- **Reference code**: <https://github.com/EricLengyel/Slug>, shaders "freely used by anyone for any purpose"; a distributed program must give credit. One reader names the license MIT or Apache-2.0 (<https://luv.swa.sh/slug-bezier.html>); GitHub shows "Other". The system copies no code: the ideas are free to use.
- `gui_toolkit` has a Slug path on the GPU (`docs/text.md`, "Slug"), with stem darkening, hinting for small sizes and coverage per color stripe; its note `slug-small-text.md` says that Slug text at 11 to 16 pixels looks softer than hinted bitmaps, and that closer to the reference is not the same as sharper.

### What it means for this system

- This system draws with the processor (property 18, step 1). Slug is a GPU method: the bands and the root solvers save work for thousands of pixels in parallel. On the processor, the same exact coverage comes cheaper from a scanline rasterizer: each line segment of the outline adds its signed area to an accumulation row, and one prefix sum gives the coverage of each pixel (the method of font-rs and of stb_truetype 2). The quadratic curves are cut into line segments within a tolerance.
- **The prototype** (`support/vector_font`, the program `vector_glyphs`): a parser of a subset of TrueType (`head`, `hhea`, `maxp`, `cmap` format 4, `hmtx`, `loca`, `glyf` with simple glyphs) that checks each offset and each count against the length of the file (a font is hostile input); a rasterizer with exact area coverage, a horizontal position in 1/64 of a pixel, and an option of coverage per color stripe (three samples per pixel, then the 5-tap filter 8, 77, 86, 77, 8 / 256 against color fringes).
- **The measures** (choice 333 of `FIRST_MILESTONE.md`): one glyph of Spleen 8x16, 32 ns; one glyph of 13 pixels from its outline, 2939 ns in grayscale, 2396 ns on a whole pixel, 5502 ns with color stripes: about 90 times more, with no cache of the coverage of a glyph. The picture `vector_glyphs` shows the same text in the two fonts, and one glyph enlarged 8 times in grayscale and with color stripes.
- **What the picture shows** (2026-11-11): at 13 pixels the outline font has the shapes of its design and even spaces (an advance of 7.8 pixels), and its stems are softer than the stems of Spleen, which sit on whole pixels; the color stripes give sharper sides with faint colors at the edges. Spleen is sharper at its one size.
- **The font**: a font needs a license that allows embedding in a program of the system. Candidates: DejaVu Sans Mono (Bitstream Vera license, DejaVu changes in the public domain; TrueType outlines), Noto Sans and Noto Sans Mono, Inter, IBM Plex, JetBrains Mono, Source Code Pro (SIL Open Font License 1.1: embedding allowed, no sale of the font alone). The prototype uses DejaVu Sans Mono, a monospace font like Spleen, with its license beside it.
- **The rules**: a vector font keeps the grid: one size for the text of the interface (a cap height that is a whole number of pixels, as the reference of Slug advises), a large size for the one number of a card; the line height stays 16 or 24.

## 10. Decisions for the owner

1. The model: immediate mode over draw tables, damage by difference (sections 2 and 2.2).
2. The form: a `support` package now, a module when the contract describes a table as a parameter (section 7). The other way: extend the contract first.
3. The font: decided on 2026-11-11 (a vector font by default, subpixel bands, Spleen as the fallback). The decisions that remain (the font file, the grid fit) are in `docs/FONTS.md`, section 11.
4. The order of the next conversions (`FIRST_MILESTONE.md`, "Next steps", item 13).

## 11. What was taken from `gui_toolkit`, and what was not

`~/Projects/gui_toolkit` (MIT license, 2026, the owner) was read for ideas. No code was copied.

Taken as ideas:

- **Immediate mode with a state kept by identity** (its `Box` with a `Key`, from the RAD Debugger): elements are described again at each frame, and only the focus, the element under the pointer and the pressed element live between frames, by identity.
- **Signals as a value** (its `Signal`: pressed, clicked, focused, ...): here `Element_Result`.
- **Damage is never negotiable for correctness** (its `damage.odin`: "a partial frame must be byte-for-byte identical to the full frame", with a verify mode that draws both): here the host tests compare a frame drawn in its damage rectangles with the same frame drawn whole.
- **A bounded list of damage rectangles that merge** (its `MAX_DAMAGE_RECTS` 16): here 8, as the compositor.
- **The keyboard is a first path** (Enter and Space press, as its `clicked`).
- **Text measured by the font, drawn from runs** (its `draw.glyph_run`): here the text record with a subpixel position, ready for a vector font.

Refused:

- **The damage given by the application** (its `damage_add` that the program calls): here the package computes it by difference, so a program cannot forget a rectangle.
- **The layout solver of five passes over a tree** (sizes by text, percent, sum of children, violations): one pass with sizes declared before content (section 3).
- **Floating point, transforms, round corners, shadows, themes** (its `draw` layer): the rules of this system are integer rectangles on a grid.
- **Allocation by the toolkit** (its frame allocator and maps): the caller gives each table.
- **A font stack of a host system** (DirectWrite, Fontations, HarfRust): the system has its own font.

## 12. State of the conversions (2026-11-11)

This section is the report of steps 52 to 54 (the conversions), written after the merge.

### The findings of the independent read (`/tmp/review_interface.md`)

| Finding | What was done | What holds it |
|---|---|---|
| F1: `line_add` of the vector font wrote one cell past its row (a vertical segment on the last column; a coverage of width 1) | Corrected. `support/vector_font/raster.odin:34`: `if start_y == end_y \|\| target.width < 2 { return }`; line 60: `if left_index < 0 \|\| left_index + 1 >= target.width \|\| right_index >= target.width` before the clamp | Host test `segments_at_the_edges_stay_in_their_rows`: it failed before (an index out of its row), it passes after |
| W1: a `Present` for the whole surface with a place of its own damaged up to one surface past the window | Corrected. `programs/compositor/main.odin:317-318`: `changed_width, changed_height := client.surface.width - left, client.surface.height - top` | The compositor does not run on the host: no host test. The rectangle stays inside the surface in each case by its two lines; the machine test draws each window |
| W2: Enter was taken before the characters of the same frame | Corrected: a text input takes Enter in the order of its keys and stops there; `element_interact` takes no Enter for a text input | Host test `text_input_keys_in_their_order` (keys `l s Enter x` give "ls", activated, `x` not taken): failed before, passes |
| W3: key 17 and later of one frame were dropped | Corrected: `window_events` stops when the input has 16 keys, the other events wait in the ring | Host test `a_full_input_says_so` (the reading itself needs a ring: no host test of it) |
| W4: the partial-frame test missed cases | Added: a clip that changes, horizontal gradients, text at the scales 1 to 3, records outside the surface, records of one line, more than 8 rectangles (the merge), a full table, pictures | Host tests `damage_is_never_too_small_for_each_kind`, `picture_and_folded_gap` |
| N1: more than 20 digits indexed `digits[-1]` | Corrected: `min(minimum_digits, 20)` | Host test `number_with_many_digits`: failed before |
| N2: a negative height of a column made `used` smaller | Corrected: `top + max(height, 0)` | Host test `column_negative_height`: failed before |
| N3: `row_split` did not check its sizes | Corrected: negative sizes are 0, fixed sizes are cut, each column stays in the row, no overflow | Host test `row_split_checks_its_sizes`: failed before |
| N4: a press under the last line or on the bar of a list chose a line; a cut choice was not reported | Corrected | Host test `list_press_and_cut_choice`: failed before |
| N5: Tab in the launcher moved the focus to the list for one build | Corrected: the launcher ignores Tab | The compositor does not run on the host; the launcher steps of the machine test |
| N6: two elements with one identity; elements past 64 not reachable by Tab | `identity_in` and `identity_with`; `Frame.identity_collisions` and `Frame.focus_overflow` count them; section 4 says the limit | Host test `identity_collision` (did not compile before: the count did not exist) |
| N7: `draw_text_right` lost the element; `int` cut to `i32` with no check | Corrected: the element passes; each place and size is clamped to `i32` | Host test `coordinates_are_cut_to_i32` |
| N8: "makes no kernel call" was false for `window_drawing.odin` | The claim is kept to the core files (`draw_table.odin`, section 2.3) | Read |
| N9: a table that does not cover its surface kept stale pixels | Corrected with no rule for the caller: each damage rectangle of a surface is painted with the background first (`draw_damage_on_surface`), a whole frame starts from the background | Host test `a_gone_record_leaves_no_pixel` |
| Names | `raster.odin`: `start_x`, `signed_height`, `width_inverse`, `first_x`, ...; `parse.odin`: `start_read`, `end_read`, `glyph_bytes`; `vector_glyphs`: `pixel_x`, `pixel_y`; `bar`: `full_width`; the launcher: `name_index`, `line_number`. The TrueType tags stay | Read |

The package has 24 host tests (`support/interface/interface_test.odin`), the font prototype 4.

### The converted windows

"Calls" are the direct drawing calls of `support/graphics` (`fill`, `text`, `block`, `unsigned`, `character`, `clear`, `line`, `outline`) in the program before the conversion (`859f078`) and after. "Module" is the size of the module file, in bytes, on `master` `c909390` and on the branch of the conversions: the package is compiled in each program.

| Program | Calls before | Calls after | Module before | Module after |
|---|---|---|---|---|
| inspect | 58 | 0 | 81 920 | 90 112 |
| scheduler | 50 | 0 | 61 440 | 73 728 |
| monitor | 29 | 0 | 49 152 | 61 440 |
| locks | 20 | 0 | 86 016 | 98 304 |
| disk | 19 | 0 | 35 284 | 45 124 |
| limits | 17 | 0 | 28 129 | 42 225 |
| crowd | 15 | 0 | 28 672 | 45 056 |
| tally | 15 | 0 | 36 864 | 49 152 |
| flow | 13 | 0 | 28 672 | 40 960 |
| budget | 12 | 0 | 28 672 | 40 960 |
| notes | 12 | 0 | 53 248 | 65 536 |
| errors | 11 | 0 | 134 113 | 144 609 |
| rights | 11 | 0 | 24 576 | 40 960 |
| frames | 11 | 0 | 73 728 | 90 112 |
| imports | 11 | 0 | 81 920 | 94 208 |
| net | 10 | 0 | 50 179 | 64 515 |
| origin | 10 | 0 | 24 576 | 40 960 |
| manual | 10 | 0 | 114 688 | 126 976 |
| life | 2 | 2 (its own board picture, by design: the Picture record) | 32 768 | 51 148 |
| clock, remote, the launcher (step 51) | 32, 31, 48 lines | 0 | | |
| Sum of the 19 programs above | 346 | 2 | | |

- Each converted module grows by 8 to 16 KiB (2 to 4 pages): the package is in each one. `processors`, which is not converted, grows by 4 KiB from the measure of pictures of `display`. This is the measured argument for the package as one shared module (section 7): about 230 KiB in all for these programs, today paid once for each.
- The boot image: 3 284 753 bytes on `master` `c909390`, 3 566 097 bytes with the conversions (+281 344).
- Lines: in the 19 programs, 865 lines added and 494 removed (+371), against 1 242 lines of the package (and 537 of its host tests). A conversion replaces each drawing call by one record and adds the tables of the program and the frame: it does not make the programs shorter. It removes the five private copies of `card` and of large text in the converted programs, it gives each window the damage by difference and the keyboard, and one change of the rules now changes every converted window.
- The times of the pictures are not published: the host had a load of 17 to 62 during each run of this step, and a measure above a load of 8 is not valid. `kerneltool measure windows` (in the form of `kerneltool measure scheduler N`) starts each converted window alone in a measure build and prints one table of the time of the first picture and of the mean of 3 and of 10, with the load of the host. The coordinator runs it on a quiet host; to measure "before", the same command on the commit "display measures the time of a picture" (the programs before the conversion with the marks of the measure).

### What the pictures of the last run show (devlog `2026-11-11_121254_branch_desktop`)

- `inspect`: the caption "Program_Report" of the narrow SLOTS card touched its right border; the columns "weight" and "req us" of the threads read as one. Corrected: a card cuts its caption to the room between its title and its count (host test `card_caption_stays_inside`), and the columns of the threads have room. Both faults were there before the conversion.
- `scheduler`, `locks`, `manual`, `life`: no fault seen.
- `limits`, `crowd`, `origin`, `rights`, `disk`, `notes`: no clipped text and no column out of place. `crowd`: its header "kernel entries, one million records" ends 8 pixels from the right edge of the window. `notes`: an empty band between its status line and its keys.

### The layers after the merge (step 59)

Each layer is a commit that passed the main scenario; the last one passed the full check (789 checks).

| Layer | Direct drawing calls before / after | Module before / after (bytes) | What holds it |
|---|---|---|---|
| The compositor: its windows (frame records and the surface as a Picture record), its bar and its two menus (cards) in one draw table for each frame | 42 / 7 (the pointer of `work/cursor`, the points of the background, the copy to the screen) | 125 723 / 121 979 | The main scenario (menus, moves, close buttons); one measure run: the frame of a window of 800 x 600 by hand 8.5 us, as 9 records 8.9 us (load 39 to 63: an indication only) |
| The boot display: its five cards are the card of the package | the card by hand / `interface.card` | `boot` 69 632 / 77 824, `root` 172 032 / 180 224 | The pictures `boot`, `boot_fails`; the UEFI loader builds with the package (no kernel call in the core files) |
| `paint`, `plasma`, `temple`: Picture records (`interface.show_picture` for one picture) | paint 13 / 5, plasma 0 / 0, temple 18 / 18: the remaining calls draw into the picture of the program, by design | paint 45 056 / 61 440, plasma 24 576 / 45 056, temple 212 992 / 229 376 | The pictures `desktop_moved`, `temple` |
| The text grid (section 2.4) and `terminal` | terminal 29 / 0 | 49 152 / 65 536 | Host tests `text_grid_damage_for_each_cell`, `text_grid_draws_its_cells`, `two_pictures_present_what_the_screen_shows`, `two_pictures_screen_is_each_frame`; the pictures `terminal`, `terminal_held`, `terminal_keys`, `terminal_stopped` |
| Window places on the grid of 8 | | | The compositor places each new window and each moved window with its corner on the grid; the scenarios move windows with steps `Move`; the tool reads places from `compositor.windows()` once it has the grant person; the full check |

- Sizes are on `master` `b97fb08` against the branch; the boot image is 5 338 592 bytes against 5 531 104 (+192 512).
- In this step the package grew by 401 lines (with 3 host tests and 1 simulation); the 16 changed files gained 844 lines and lost 273.
- `flood`, lines in one second, as the terminal logs them: 3 492 315 before the text grid (load about 50), 4 651 133, 3 567 351 and 2 429 679 after (loads 15 to 23). Each is above a load of 8, so none is a valid measure; the text grid did not make the console slower in these runs. A frame of the terminal now draws only the rows that changed.
- A fault found and corrected in the package: with two pictures, a frame presented only its difference with its own picture. The screen shows the other picture, so rows of two frames were mixed on the screen (seen in `terminal.png`, a row half of one line and half of another). The rule and a simulation of the screen are in section 2.2.
- The pictures of this step (devlog `2026-11-11_150943_branch_desktop`): `desktop_moved` (plasma, paint, life, monitor on the grid), `temple`, `boot`, `rings`, `terminal`, `terminal_held`, `terminal_stopped`, `menu`, `windows`. Faults seen and corrected: the processor name of the boot display was cut in the middle of a word (a fact is now cut after its last whole word); the keys hint of the terminal ran over "older than the lines kept" (the hint is left out when the text at its left takes its room). No other clipped text, no misaligned column.

### Lines and shared pictures (step 62)

- `rings` draws its rings with `Line` records and its nodes with `draw_outline`: 0 direct drawing calls (19 before).
- `threads`, `workers` and `processors` keep the pixels that their threads compute in a picture of the program, in the memory that the threads share. The window shows it with a `Picture` record. For `threads`, the generation of a square is the frame count of its thread. For `workers` and `processors`, the generation is the number of the picture times 1024, plus its complete tiles or rows. Direct drawing calls after the change:
  - `threads`: 1 (9 before), the clear of each square picture to the background at the start.
  - `workers`: 1 (21 before), the clear of its picture at the start.
  - `processors`: 2 (22 before), the clear of its picture at the start and at each new picture.
  - Each of these calls draws into a picture of the program, not into the surface. The threads write the pixels of the picture directly: that is the subject of these programs.
- A frame of these windows copies the picture only when its generation changed. A picture can be copied while a thread writes it, as before when the threads wrote into the surface. The next generation copies it again.
- `crowd`: the window ends 12 pixels after its widest header, the same margin as at the left (it ended 16 pixels after it, and the header passed its column).
- `notes`: the line of the keys follows the status line, with no empty band. When the grant of the store ended, the line that says so takes the place of the keys. The window is 30 pixels shorter (208).

### Not converted, and why

- `server`, `fetch`: another agent rewrites `server`.
- `console`: it draws no pixels; its terminal draws it (section 2.4).
- `log`, `pages`: colors of their own meaning and a layout of their own. `twin` and `fault` have no window.
- The pointer of the compositor: the branch `work/cursor` owns it.
