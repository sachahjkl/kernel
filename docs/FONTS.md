# The text of the system: a vector font with subpixel bands

Status: built on 2026-11-11 on the branch `work/font`, at the decision of the owner of the same day (`HANDOFF.md`, item 33). The owner has not reviewed this design.

Words of the owner: "on peut garder spleen comme fallbach ou comme option dans un menu de paramétrage par exemple mais par défaut il faut une police vectorielle", and for the rendering: "Bandes sous-pixel". Earlier: "font rendering even maybe ? Software impl of slug + custom "subpixel" rendering ?" and "the idea with slug was just to try and "adapt"/backport things INTO our kernel design rules !".

The terms are in `GLOSSARY.md`, section "Text": font, glyph, outline, coverage, subpixel band, glyph cache, grid fit, setting, settings page.

## 1. What changed for a program

Nothing in its code. A program calls `graphics.text`, `graphics.character`, `graphics.unsigned` or the elements of `support/interface`, as before. `support/display` gives the setting of the person and the glyph cache to `support/graphics` when the program opens its window, and again at each change. Each window of the machine test draws with the vector font with no line of its own changed.

Five private copies of large text read the bitmap of Spleen directly, past the text interface: `large` in `scheduler` and `terminal`, `write_large` in `server` and the boot display, `text_draw` in `support/interface`. Each one now calls `graphics.text_scaled`, one line. They had to change because they did not use the interface of the text; a program that uses it does not change.

## 2. The grid

The system is laid out in cells of 8 x 16 pixels, and the design rules are a grid of 8 (`DESIGN.md`, sections 5 and 6). The vector font lives on it:

- **The default font is monospace.** Its advance maps to exactly 8 pixels at scale 1: the scale of the outline is 8 / advance, the same on both axes. A line is 16 pixels. Each existing layout holds; no window changes its size.
- **The scales 2 and 3 are real sizes**: 16 x 32 and 24 x 48 pixels, each drawn from the outline at that size, not enlarged pixels. The large numbers of `scheduler`, `remote`, `terminal`, `server` and the boot display gain the most.
- **A glyph is cut to its cell.** The ink and the color fringe of a glyph stay inside its cell of 8 x 16 (or 16 x 32, 24 x 48). A cell never draws into its neighbour: the terminal fills one cell and draws its character, and the damage by difference of `support/interface` takes the rectangle of a text record as all that it draws. A glyph that passes its advance (rare in a monospace font) loses that part.
- **The baseline** puts the middle of the ink of the characters 33 to 126 at the middle of the cell (`vector_font.glyph_style_of`). For JetBrains Mono at scale 1 it is row 12, the baseline of Spleen.

### Grid fit (the hinting of this system)

No TrueType bytecode interpreter: the subsets have no instructions. In place of it, a light grid fit of the vertical metrics, with the flag `FLAG_GRID_FIT` of the cache:

- the baseline is on a whole pixel (the origin of the cell);
- the x-height (the top of `x`) and the cap height (the top of `H`) go to the nearest whole pixel; the points between 0 and the x-height scale to it, the points between the x-height and the cap height scale between the two, the points above the cap height and below the baseline keep the plain scale (`vector_font.place_y`).

Why: at 13 to 14 pixels to the em, the tops of the lowercase letters and of the capitals fall between two rows without it, and a row of half coverage under each top makes the text soft. The fit moves the tops onto rows, so the horizontal stems of `n`, `e`, `t`, `E`, `H` are sharp. The vertical stems need no fit across: the subpixel bands place them in thirds of a pixel. Not done: a fit of each stem (it needs the stems of each glyph: an outline analysis or the instructions of the font).

The picture `build/fonts/candidates.png` (`kerneltool vector_fonts`) has the default font with and without the fit; the default is with it. It is a decision that the owner can reverse (section 11).

## 3. Subpixel bands

- **Coverage at 3 samples for each pixel across**, one for each color stripe of the screen: the outline is drawn into an accumulation three times wider than the cell, with a margin of 6 thirds on each side.
- **The filter**: each third spreads over its neighbours with the weights 8, 77, 86, 77, 8 of 256 (the default filter of the usual LCD rendering), so that a side of a stem does not show one color alone. Measured on a stem of one pixel at its three places of a third (host test `filters_measured`): the five taps give a fringe of at most 162 of 255 and a peak of 239; three taps (85, 86, 85) give 170 and 255; no filter gives 255 and 255. The five taps are chosen: the least fringe for a loss of 16 levels at the peak.
- **The words of the cache**: for each pixel one word 0xGGRRGGBB: the coverage of the red, green and blue stripe after the filter, red at the left, and in the high byte the coverage of the whole pixel (the mean of its three thirds before the filter) for grayscale.
- **The order of the stripes** is a setting: `rgb` (the default), `bgr` (the same words with red and blue swapped at the blend: exact, the same thirds), `none` (grayscale, the high byte). Under QEMU the screen of the host decides: the pixels of the machine go to a window of the host, whose own panel has its own order; most panels are RGB.
- **Text over a gradient or a picture**: the blend reads the pixel under each covered pixel; nothing assumes a plain background.
- **Colored text**: the coverage of each channel times the color of the text, in linear light.

### The blend in linear light

`graphics.blend_coverage_row` (in `support/graphics/blend.odin`, beside `blend_premultiplied_alpha` of the pointer pictures: one family, one head comment): for each channel, with d the pixel under, c the color of the text and a the coverage of that channel,

    result = sqrt((d * d * (255 - a) + c * c * a) / 255)

A gamma of 2 in place of the curve of sRGB, in integers: the sum is under 2^24, shifted right by 12 bits it indexes a table of 4096 square roots that each program makes once (4 KiB). A channel with coverage 0 keeps the pixel, 255 gives the color.

The error against the exact curve of sRGB (host test `blend_error_against_srgb`, each coverage 0 to 255):

| Text over | Gamma of 2 | No gamma (a blend of the encoded values) |
|---|---|---|
| `COLOR_TEXT` over `COLOR_CARD_BOTTOM` | 8.5 levels at most | 51.0 levels |
| `COLOR_DIM` over `COLOR_BACKGROUND` | 4.2 | 27.2 |
| `COLOR_PROGRAM` over `COLOR_CARD_TOP` | 7.4 | 40.3 |
| `COLOR_BACKGROUND` over `COLOR_TEXT` | 8.9 | 54.9 |

Light text on a dark surface is the case of this system: a blend with no gamma makes each edge pixel up to 51 levels too dark, and the text looks thin.

### What a screenshot shows

A picture of the screen holds the colored edges of each glyph: enlarged, each letter has orange and blue sides. This is the subpixel band at work, not a fault: on an RGB panel at its native size the three stripes of a pixel make the edge. The pictures of `docs/screenshots` are taken with the order `rgb`. The setting `none` gives gray edges, for a picture to read enlarged or a screen with no stripes in rows (a turned screen, many OLED panels).

## 4. Fixed point

`support/vector_font/raster.odin` has no floating point, and neither has the text path of a display (`support/graphics`, `support/display`):

- **Coordinates** in subunits: 256 to a pixel on each axis (24.8). The points of an outline are integers in units of the font; the placement maps them with rational numbers rounded to the nearest subunit (`divide_rounded`).
- **Accumulation** in `i32`: a piece of a segment of height h with ends at ra and rb subunits from the left of its column adds h (512 - ra - rb) to its cell and h (ra + rb) to the next; a full pixel is 256 x 512 = 131 072. **The overflow argument**: a segment adds at most one full pixel to a cell of a row, and a glyph has at most 8192 segments (a segment past that is dropped), so a cell and a prefix sum stay under 2^30.
- **Cuts**: a segment is cut at each row and each column; the place of a cut is a function of the segment and of the line of the cut only, so two pieces that meet share their point. The sum of the coverage of a closed outline is exactly the area of the polygon of its cut points.
- **Exactness** (host test `coverage_is_the_area`): a rectangle at positions that are not on a pixel, triangles at 45 degrees and the whole accumulation give a sum of coverage equal to their area, to the unit. Twelve convex polygons with edges at other angles: at most 0.000029 of their area apart (the rounding of the cut points).
- **The edges of the accumulation**: what is left of it lies on its left side, what is right of it on its right side, so the coverage inside stays exact; a row has one cell more for a piece on the right side of the last column. Host test `the_last_column`: a vertical edge exactly on the right side of the last column with widths 1, 2 and 3, and an outline that passes all four sides. (The rasterizer in floating point of step 51 wrote outside its row in that case; the desktop agent corrects that file on `work/desktop`; this step replaces the file.)
- **Quadratic curves** are cut into 1 to 16 segments, so that each is at most 1/8 of a pixel from the curve; each point is computed from the ends and the control point, rounded: no error adds up along a curve.
- **The result does not depend on the build**: integers only; the host test `golden_glyph_cache` builds the cache of JetBrains Mono two times, compares the bytes, and compares the hash of the words of each scale with a constant. A change of the renderer changes these hashes: it needs a new `RENDERER_VERSION` and new constants.

## 5. The glyph cache

A table of drawn glyphs: for each scale (1, 2, 3) and each character 32 to 126 (the subpixel position bucket is always 0 for text on the grid of 8; the fractional position stays in the draw record of `support/interface` for a later proportional font). Format: `contract/glyph_cache` (a header of 128 bytes, a size entry of 16 bytes for each scale, a glyph entry of 8 bytes for each character and scale, then the words; a glyph keeps only its rows with ink). Fixed capacity: 3 sizes, 95 characters; no replacement rule is needed, because the table holds every glyph that the grid can draw. All zero is valid: a program with no cache draws Spleen.

### Where it lives: three places weighed

| | In each program, at run time | Shared, filled at run time by a font service | Built by the kernel tool, a resource of the boot image |
|---|---|---|---|
| The time to fill ASCII 32 to 126 at 3 scales | 3.7 to 4.0 ms for each program (measured by `vector_glyphs` for each candidate) | The same, once | 0 at run time; the same work once in the build |
| Memory | 390 624 bytes in each program (JetBrains Mono) | One copy, shared read-only | One copy: the pages of the boot image, mapped read-only |
| The font file at run time | In each program (14 to 21 KB) | In the service | None: the system draws from the cache only |
| Property 11 | The cache is not a fact of the system description | The same | The cache is a function of the font file (its BLAKE3 in the header) and of the renderer version; the boot image names it by its hash |
| Hostile input | Each program reads the font file | One service reads it | The kernel tool reads it at build time; each program validates the cache once (one pass over its tables, 7 us in root) |

**Chosen: built at build time, a resource of the boot image.** The root service checks its hash once at start (796 to 966 us for 390 624 bytes) and maps it read-only into each program with a surface, each terminal and the compositor (property 6: shared memory; property 20: a read-only grant that the root service gives). The tool makes it at each build from the subset in `resources/fonts`; the same font and the same renderer give the same bytes (the host test compares two builds). The resource mechanism is the one of the pointer pictures (step 55, `docs/ARCHITECTURE.md`, U2b): the glyph cache is a second resource of the same table, given through the same `resource_mapping` of the root service.

The other two forms stay possible: `vector_glyphs` builds the cache of each candidate in its own memory with the same function (`vector_font.glyph_cache_build`), which is the form of a program that draws another font.

### The cost of a text draw

| Measure (machine test, the least of 50 batches) | Branch | `master` |
|---|---|---|
| One glyph of Spleen 8x16 | 35 ns | 30 ns |
| One glyph from the glyph cache, scale 1 | 309 ns | |
| One glyph from its outline, in fixed point, with the stripes: scale 1 / 2 / 3 | 3 874 / 10 607 / 20 613 ns | 5 373 ns at 13 px (floating point, step 51) |

On the host (`glyph_draw_cost`): 333 to 362 ns from the cache against 33 to 44 ns for Spleen. The target was "the same order as Spleen": a glyph from the cache costs 9 times a glyph of Spleen. The steps that brought it from 921 ns: a loop for each order of the stripes (a constant), no bounds check after the one validation of the cache, the squares of the pixel under kept from one pixel to the next, a shift in place of a division. What stays: about 40 pixels of a glyph have a partial coverage, and each needs three blends in linear light. Section 9 has the effect on whole frames, which is small.

The blend of a glyph now has an SSE2 form beside this scalar form, with the same bytes: `docs/SIMD.md`, sections 3 and 6, says what it computes in vectors and how to measure it against the numbers above.

## 6. The font file

The owner did not choose one. Six candidates, each read from the build input of `flake.nix` (the packages of nixpkgs, pinned by `flake.lock`). Their license texts were read at the source on 2026-11-11.

| Candidate | License, as read | Outlines | Source | ASCII subset | Glyphs made of glyphs |
|---|---|---|---|---|---|
| JetBrains Mono 2.304 | SIL OFL 1.1, no Reserved Font Name: "Copyright 2020 The JetBrains Mono Project Authors [...] This Font Software is licensed under the SIL Open Font License, Version 1.1." (`github.com/JetBrains/JetBrainsMono/OFL.txt`) | `glyf` | 268 544 bytes | 14 164 bytes | 4 |
| DejaVu Sans Mono 2.37 | Bitstream Vera license, DejaVu changes in the public domain: "The Font Software may be modified [...] only if the fonts are renamed to names not containing either the words "Bitstream" or the word "Vera"." (`github.com/dejavu-fonts/dejavu-fonts/LICENSE`) | `glyf` | 343 096 | 17 688 | 0 |
| IBM Plex Mono 1.1.0 | SIL OFL 1.1 "with Reserved Font Name "Plex"" (`github.com/IBM/plex/LICENSE.txt`): the subset is named "IBM Mono ASCII" | `glyf` | 155 940 | 15 224 | 3 |
| Fira Mono 3.2 | SIL OFL 1.1: "Digitized data copyright (c) 2012-2015, The Mozilla Foundation and Telefonica S.A." (`github.com/mozilla/Fira/LICENSE`); the name table of the file: "Licensed under the Open Font License, version 1.1 or later" | `glyf` | 174 632 | 13 424 | 0 |
| Commit Mono 1.143 | The name table of the font file: "This Font Software is licensed under the SIL Open Font License, Version 1.1"; the repository (`github.com/eigilnikolajsen/commit-mono/LICENSE`): MIT. The two differ; the subset keeps the text of the file | `glyf` | 377 980 | 13 024 | 0 |
| Iosevka 34.3.0 | SIL OFL 1.1, no Reserved Font Name: "Copyright (c) 2015-2026, Renzhi Li" (`github.com/be5invis/Iosevka/LICENSE.md`) | `glyf`, a collection of 18 faces (the first is read) | 50 041 356 | 20 944 | 5 |
| Source Code Pro 2.042 | SIL OFL 1.1 "with Reserved Font Name 'Source'" (`github.com/adobe-fonts/source-code-pro/LICENSE.md`) | CFF only in nixpkgs | | not made | |

- **CFF** (Source Code Pro): its outlines are Type 2 charstrings, a small stack machine with cubic curves. The reader would need that interpreter (about 40 operators, subroutines, hints to skip) and the cut of cubic curves. Not built: five candidates have `glyf`.
- **A subset is a Modified Version** of the font under the OFL (OFL FAQ 2.6: "Removing any parts of the font [...] is considered modification. This is permitted by the OFL but would not normally allow the use of RFNs."). So a font with a Reserved Font Name is renamed in its subset ("IBM Mono ASCII"). Each subset keeps the copyright and the license text of its source in its name table and in a `.license` file beside it; `resources/fonts/OFL.txt` and `BITSTREAM_VERA_LICENSE.txt` have the full texts.
- **The subset command**: `kerneltool vector_fonts` reads `VECTOR_FONT_SOURCES` (the development shell sets it), writes for each candidate the characters 32 to 126 and `.notdef` as simple glyphs with no instructions (a glyph made of glyphs is made simple with its offsets and its scale in integers), the tables `OS/2` (of the source), `cmap` (one segment), `glyf`, `head`, `hhea`, `hmtx`, `loca`, `maxp`, `name`, `post`, with their checksums. It uses no time and no random value: the same input gives the same bytes. The subsets are in the repository, as the output of `kerneltool font` is: a build needs no build input.
- **A wider range** costs at most 4 bytes for each pixel of a cell, at three scales: 4 x (8 x 16 + 16 x 32 + 24 x 48) = 7 168 bytes for each character with ink in each row; about 4 100 bytes for each character on the mean with only the rows with ink. The 96 characters of Latin-1 would add about 390 KB; the subset grows by about 150 bytes for each character.

**The default: JetBrains Mono** (`DEFAULT_VECTOR_FONT` in `tools/kerneltool/vector_fonts.odin`: one line). Why: at 8 x 16 its zero has a dot and its `O` does not, `1`, `l` and `I` differ, its x-height (550 of 1000) gives 7 rows like Spleen, its stems are even at the three scales, and the OFL with no Reserved Font Name lets the subset keep its name. DejaVu Sans Mono is close; Iosevka has the largest letters (its advance is half its em, so its em is 16 pixels) and the most condensed forms; Fira Mono is the heaviest; IBM Plex Mono needs a new name.

The picture of the choice: `font_candidates` (the program `vector_glyphs`: the same line in Spleen and in the six fonts, the large number at scale 2, a word enlarged 4 times; each candidate from a cache that the program builds), and `build/fonts/candidates.png` (`kerneltool vector_fonts`: the same lines at scales 1, 2 and 3 in each candidate and in Spleen, the default with and without the grid fit, a word of each enlarged 5 times; drawn on the host by the same `support/graphics`).

## 7. The setting

The system had no settings menu. The smallest form that keeps the properties:

- **Where it lives**: one page, the settings page (`contract/settings`). The root service creates it at start and writes the place, the size and the hash of the glyph cache in it. The program `settings` receives it with Write (the role `Settings` of the root service: the one writer). Each program with a surface, each terminal and the compositor receive it read-only at a fixed address, with its address in the value 13 of their context (P20: a grant of the root service, read-only; P9: no shared file). All zero is valid: the vector font, `rgb`.
- **A change while programs run**: `settings` writes the page (the change count is odd during the write) and wakes the threads that wait on the change count. The compositor waits on it: it gives the new choice to its own text, draws its whole screen again, and sends the display event `Settings_Changed` to each window. `support/display` gives the new font to `support/graphics` when the program reads the event, between two frames; `support/interface` draws the whole window at the next frame (each draw record is the same, each pixel of text is not). A program draws again as it does for any event.
- **The first settings**: `font` (`vector`, `spleen`) and `subpixel_order` (`rgb`, `bgr`, `none`). Later: the pointer theme (`docs/POINTERS.md`: the order of `pointer_theme_choice`), the strategy of the scheduler.
- **The program `settings`**: a window of the interface package: the two settings as buttons (the pointer and the keyboard: Tab, then Enter), the text of the system at its three sizes, the facts of the glyph cache (size, hash, valid or not used). Exports with descriptions (P19): `settings.set(name, value)` (1, or an error record: `No_Grant` -1 for a caller that does not act for the person, `Absent` -2 for a name, `Bad_Value` -3 for a value) and `settings.get(name)` (a text). The console calls them after `connect("settings")`; `kerneltool call` calls them through `remote`.
- **Not built: the setting is not kept** when the machine stops. The right form: `settings` keeps the record in its private store (P9) and the root service starts it at boot as a service with no window, which writes the page before the first program. Until then a stored setting has no place to come from: the default holds at each boot.

## 8. Fallback

- **No cache, or a cache that its validation refuses**: the program draws Spleen 8x16, and its log has one line ("display: no glyph cache" or "display: the glyph cache is refused: <sentence>, value, limit"). The validation (`glyph_cache.validate`) checks the magic, the version, the size of the file, the counts, each cell size and baseline, the place of the words and the rows and words of each glyph (host test `damaged_glyph_cache`: ten fields damaged one at a time, each refused with its kind; the file cut at each 977 bytes, each refused, no fault).
- **A cache whose hash is wrong**: the root service does not map it (one line on the log), and no program has it.
- **A damaged font file** at build time: the tool stops the build with the problem (`vector_font.Font_Problem`). The reader checks each read (host test `hostile_files`: the file cut at each 211 bytes, 48 files with 64 changed bytes, each glyph drawn at the three scales: no fault).
- **The boot display can use the vector font**: the glyph cache is in the boot image, and the root service checks its hash and validates it before its first boot display (the picture `boot_fails` is drawn by the root service, in the vector font). A screen with red in the low byte swaps the stripes of the text (`bootscreen.stripes_of_screen`).
- **A character that the font lacks**: the system draws ASCII 32 to 126 only, and each candidate has all of them (the subset command refuses a font without one). A byte outside draws nothing, as with Spleen.

## 9. Measures

Each pair was measured in the same hour with the same tool, `master` at `c909390` and the branch rebased on `cacaf48` (the frame caches are between: they do not draw). The load of the host was 15 to 37 during each run (`uptime` in the log of the agent): above 8, so by the rule of the project these numbers are not valid measures of speed. They show the order; a run on a quiet host is needed.

| Measure | `master` | Branch |
|---|---|---|
| `flood`: lines in one second (the terminal draws a full window at each picture) | 3 925 316 | 4 302 808 (other runs: 1 594 054 and 2 629 205 at load 30 to 45) |
| The terminal: pictures in one second | 62 | 62 |
| A full frame of the desktop, 1024 x 768 with 16 windows | 1 683 to 3 424 us | 1 523 to 2 653 us |
| `interface_elements`: the whole frame / the next frame in its damage | 402 / 119 us | 637 / 158 us (875 / 209 us at load 45) |
| `clock`: one picture, the mean of 10 | 19.9 us | 31.5 to 46.3 us (211.7 us in one run) |
| The boot image | 3 566 097 bytes (`cacaf48`) | 3 778 016 bytes: +390 624 the glyph cache, +64 193 `settings`, -231 953 `vector_glyphs` (the 343 KB file of DejaVu left, six subsets came) |
| The glyph cache | | 390 624 bytes; its hash checked by the root service in 796 to 966 us |

The console stays fast: the producer writes into the terminal ring, and the terminal draws at most 62 pictures in one second whatever the font; a picture of the window of `flood` (about 2 500 characters that are not spaces) costs about 0.7 ms more with the vector font (2 500 times 274 ns), under 5 % of a processor at 62 pictures in one second. The full frame of the compositor copies surfaces: the font does not enter it.

## 10. Gaps

- The cache draw is 9 times Spleen for one glyph (section 5). A table of the blends for each pair of pixel and color (three times 256 bytes) would make a partial pixel three loads; it pays only where the pixel under does not change from one row to the next, which is not the case over the gradient of a card.
- No grid fit of each stem; no stem darkening (`gui_toolkit` thickens the stripes by 0.2 pixel; not tried here).
- The setting is not kept across a stop of the machine (section 7).
- A proportional font, kerning and the characters outside ASCII are not built: the cache has no glyph outside 32 to 126 and no subpixel position.
- The order of the stripes of the screen is not detected: under QEMU it is the panel of the host, which the system cannot read.
- The measures of section 9 were taken on a host with a load above 8.

## 11. Decisions that the owner must make

1. **The font file**: JetBrains Mono (the default), or another candidate of section 6: one line, `DEFAULT_VECTOR_FONT`.
2. **The grid fit**: on (the default; the tops of the letters on whole pixels, the shapes moved by up to half a pixel) or off (the shapes of the design; softer tops at 8 x 16): one line, `GLYPH_CACHE_GRID_FIT`. Both are defensible; the picture `build/fonts/candidates.png` shows both.
3. **The order of the stripes by default**: `rgb` (now), or `none` until the system can know the panel.
4. **A boot service for the settings** (section 7), so that a setting stays after a stop.
