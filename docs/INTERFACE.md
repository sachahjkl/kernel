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

### 2.1 Draw record (format version 1)

A draw record is 40 bytes. The fields are little-endian, in this order:

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `kind` | u8 | `None` 0, `Rectangle` 1, `Vertical_Gradient` 2, `Horizontal_Gradient` 3, `Text` 4, `Clip` 5 |
| 1 | `text_scale` | u8 | Text: 1, 2 or 3 (DESIGN.md, section 5) |
| 2 | `text_subpixel_x` | u8 | Text: the position after `x` in 1/64 of a pixel. 0 for Spleen 8x16, which places each glyph on a whole pixel |
| 3 | `reserved` | u8 | 0 |
| 4 | `x`, `y`, `width`, `height` | 4 x i32 | The rectangle of the record, in pixels of the surface. For text, the rectangle that the run covers |
| 20 | `first_color` | u32 | `0x00RRGGBB`: the color of a rectangle or a text; the top or the left color of a gradient |
| 24 | `second_color` | u32 | The bottom or the right color of a gradient |
| 28 | `text_start`, `text_count` | 2 x u32 | Text: the bytes of the run in the text table of the draw table |
| 36 | `element` | u32 | The low 32 bits of the element identity that wrote the record, 0 for none: a tool can say which element changed |

- `Clip` sets the rectangle that the next records are cut to, until the next `Clip`; a `Clip` of width 0 ends the cut.
- A version number (`DRAW_RECORD_VERSION`, 1) is beside the format, as for the contracts. A new kind is a new version.
- The text of a run is in the text table of the draw table, not in the record: a record stays 40 bytes, and two runs with the same bytes compare equal.
- Pictures (the surface of `plasma`, the cells of `life`) are not in version 1: those programs draw pixels, not an interface.

### 2.2 Damage by difference

The program keeps the draw table of the last frame that it drew (a second table, its own memory). After it builds the table of this frame, `damage_by_difference` compares the two tables, record by record, at the same index:

- Two records at one index are equal if their 40 bytes are equal and the bytes of their texts are equal. Nothing is damaged.
- If they differ, the rectangle of the old record and the rectangle of the new one are damaged: the old one must be painted over, the new one painted.
- The records after the end of the shorter table are damaged.
- The rectangles merge as in the compositor: rectangles that touch become one; with no room left (`DAMAGE_CAPACITY` 8), a new rectangle joins the first one.

Then `execute_in_rectangles` draws again, in each damage rectangle, each record of the new table that touches it, cut to the rectangle. The program never tracks damage by hand.

- **The limit of the index rule**: a record added in the middle of the table moves all the records after it, and they all compare as different: the damage is too large, never too small. It is right, and it costs only time. An element identity in each record (offset 36) allows a later rule that matches records by identity; it is not needed by the first users.
- **Two pictures**: a surface with two pictures needs the table that was drawn in the picture that the program draws now, which is the table of two frames before. The caller keeps one table for each picture.
- **Present with a rectangle**: `display.present_rectangle` gives the compositor the union of the damage: the compositor draws again only that part of the window (the protocol had a gap there: `Present` damaged the whole surface). A full rectangle stays the default of `display.present`.
- **The cost**, measured by the program `interface_elements` on its window of 68 records (choice 328 of `FIRST_MILESTONE.md`): nothing changed, 0 rectangles in 0.8 us; one number changed, 3 rectangles in 0.8 us; everything moved, 1 rectangle in 1.8 us: about 13 ns for each record. The whole frame is drawn in 366 to 411 us, a frame in its damage in 89 to 120 us. `clock` draws one picture in 11.6 us against 109.2 us by hand.

### 2.3 Memory of the caller, errors as values

- The caller gives the draw table (`records: []Draw_Record`, `text: []u8`) and the interface state. The package never allocates.
- A table that is full stops taking records and keeps the flag `full`: the frame is drawn without the records that did not fit, the program can test the flag and write it on its log. No element fails in silence.
- An element gives its result as a value (`Element_Result`): pressed, has the focus, changed. Nothing is hidden in a context.

## 3. Layout

- The unit is the grid of 8 pixels (DESIGN.md, section 6). An `Area` is a rectangle of the surface.
- **A column** gives areas from the top of its area to the bottom: `column_take(&column, height)`. The height of a line of text is 16, a line of a table 24.
- **A row** splits an area into columns in one pass: the caller gives the sizes of all the columns before it draws in them, so the row knows each width at once. A size is `Pixels` (a fixed width), `Characters` (a count of characters of the font: the width that the text measure gives) or `Share` (a part of what the fixed sizes leave, in proportion to its value). A gap is between two columns.
- **Alignment**: text is at the left, or at the right of its area (numbers, DESIGN.md section 5), and in the middle of the height of a line.
- **One pass.** There is no tree and no constraint solver: what is not known before the row (the width of a text that the program has not made yet) is measured by the caller with `text_width` first. `gui_toolkit` solves sizes in five passes over a tree of boxes (standalone, upward, downward, violations, positions): the windows of this system have fixed sizes, and one pass with sizes declared before content covers each window of section 1.

## 4. Input and focus

- The program gives each frame an `Input` record, filled from the `display.Event` records of the frame: the place of the pointer, a press and a release of the left button, and the keys pressed in this frame (at most 16).
- **Element identity**: an element that takes input has an identity, a u64 that the caller makes from a text with `identity("launcher list")` (the 64-bit FNV-1a hash of the text). The identity must stay the same from one frame to the next for one element.
- **The interface state** (memory of the caller, 2 KiB) keeps between frames: the element that has the focus, the element under the pointer, the element pressed and not yet released, and the order of the elements that can take the focus in the last frame.
- **The keyboard is a first path**: Tab and Shift+Tab move the focus in the order of the elements of the last frame; Enter and Space press the button that has the focus; up and down move the choice of a list that has the focus; a text input that has the focus takes the characters and Backspace. The launcher of the compositor is the model: each thing that the pointer does, a key does.
- **The pointer**: an element under the pointer is "under the pointer" (the close button of a window is brighter); a press and a release on one element press it. A press on an element gives it the focus.

## 5. Text

- **The interface of the text** is two functions and one record: `Font` (`kind`, `scale`), `text_width(font, text) -> pixels` and the record `Text` of section 2.1 with `text_scale` and `text_subpixel_x`. Today `kind` has one value, `Spleen_8x16` (owner, 2026-11-10: the bitmap font at its native size), with the scales 1, 2 and 3.
- A vector font later is a second `kind`: it fills `text_subpixel_x`, and its rasterizer reads it. The callers do not change: they measure with `text_width` and append text records.
- The research on a vector font, with a prototype, is in section 9.

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

## 8. Property 20 and the compositor

- The package draws only into the canvas that the caller gives: a program draws only into its own surface. The package has no handle and makes no kernel call (P20: no ambient access).
- The compositor is a user of the same package: its launcher is built as a draw table, executed into its frame, and damaged by difference as each program's window is.

## 9. Text: a vector font, research note and prototype

Spleen 8x16 stays the font of the system in this step (decision of 2026-11-10). This section prepares the decision of the owner.

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
3. The font: Spleen 8x16 stays, or a vector font (which one, which sizes, and grayscale or coverage per color stripe), after the picture of `vector_glyphs`.
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
