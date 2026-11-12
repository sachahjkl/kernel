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
- **Spleen as the fallback is enlarged** (owner, 2026-11-12: "yeah that's fine"): the rule "no enlarged low-resolution font" holds for the default font. When a program has no valid glyph cache, or when a person chooses Spleen in the settings, Spleen draws each of its pixels as a square at the scales 2 and 3: the other choice at that moment is no large text.
- **The glyph cache stays built ahead; an atlas filled on demand is noted, not built** (owner, 2026-11-12: "yes that's fine for now, but note it"). The cache is an atlas filled whole at build time: one read-only copy for the whole system, no font parser at run time. The noted design for the day a text needs a character or a size outside it: a font service, the only program that reads a font file and rasterizes; its atlas is a mapping that it writes and that the others read, with the cache built ahead as its first part; a program asks for the missing glyphs in one batch through a table. A smaller step before it, not decided: the subset widened to Latin-1.
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

A table of drawn glyphs: for each scale (1, 2, 3) and each character 32 to 126. Format: `contract/glyph_cache`, version 2: a header of 128 bytes, a size entry of 16 bytes for each scale, a glyph entry of 12 bytes for each character, position and scale, the advance of each character and scale, the pairs of each scale, then the words; a glyph keeps only its rows with ink. Fixed capacity: 3 sizes, 95 characters, 3 positions, 9 025 pairs; no replacement rule is needed, because the table holds every glyph that the grid can draw. All zero is valid: a program with no cache draws Spleen.

**One format for the two kinds of font** (version 2, section 12.4). The tool writes every cache again, so no reader keeps version 1:

| | A monospace cache (Paper Mono) | A proportional cache (B612) |
|---|---|---|
| Positions of each scale | 1 | 3 at scale 1, 1 at the scales 2 and 3; 3 for the bold weight at scale 1 |
| A glyph | its full cell: `left` 0, `width` the width of the cell | the box of its ink: `left` from the origin (it can be negative), `width` its columns |
| The advance of each character | the width of the cell, in 1/64 of a pixel | the advance of the font, in 1/64 of a pixel |
| Pairs | none | the pairs of `kern` between two characters of the cache, in 1/64 of a pixel, sorted |

`validate` checks each new part as hostile input, as the rest: the positions (1 to 3), the first glyph of each scale (after the glyphs of the scale before), the width (at most 64) and the left side (-16 to 64) of each glyph with its words inside the file, each advance (0 to 64 pixels), and each pair (two characters of the cache, sorted with no pair twice, at most 64 pixels). The draw of a cell (`graphics.character_vector_with`) reads `left` and `width` of the glyph in place of the width of the cell: the same pixels for a monospace cache. Since 2026-11-12 the header says which kind of cache it is: `FLAG_PROPORTIONAL`. A cache with no such flag is monospace, and `validate` requires its form: one position, no pair, each glyph with `left` 0 and `width` at most the width of the cell, each advance the width of the cell; the damage of a grid of text cells depends on a glyph that stays in its cell. `validate` also refuses a flag that it does not know, a filter past the three of `support/vector_font`, and a font name that is not printable bytes with a zero byte at its end. The kernel tool validates each cache that it writes, monospace or proportional.

### Who can write a cache

Each program validates its glyph caches once, then the drawing code reads the counts and the offsets of a cache again at each glyph, with no bounds check. So the bytes of a cache must not change after `validate`, and the place of a cache must not be a choice of another program. Both hold:

- **The address** of each cache is a fixed range (`contract/fixed_addresses`), a constant of the program. It is not read from the settings page.
- **The size** of each cache is a value of the context of the program (the values 20, 21 and 22, `CONTEXT_VALUE_GLYPH_CACHE_SIZE` and the next two), which the root service writes at the start of the program, only for a cache that it maps. `settings.glyph_cache_place` refuses a size larger than the span of the range. Before, the address and the size were fields of the settings page, which the program `settings` writes: it could point every later program at memory that it controls, and change that memory after the validation (`review_fonts_hostile.md`, Fault 1).
- **The bytes**: the root service maps each cache from the boot image with no flag, so with the right Read only, for every program that receives it, the program `settings` and the compositor included (`text_settings_give`). The one handle of the boot image, which the kernel gives the root service, has the rights Read and Give and no right Write (`kernel/main.odin`). So no program, the root service included, writes the bytes of a cache after the root service checked their hash.
- **What `settings` still chooses through the page**, and the worst that each field does to another program:

| Field | Its worst value | What it does to another program |
|---|---|---|
| `values[font]` | any number | a value that the setting does not have reads as 0 (`valid`): the vector font or Spleen, a look |
| `values[subpixel_order]` | any number | the same: one of three orders of the stripes, a look |
| `values[pointer_theme]` | any number | one of the two theme files that the compositor validated, a look |
| `values[grid_fit]` | any number | one of the two caches that the program validated, a look |
| `values[4..7]` | any number | no reader |
| `change_count` | odd for ever, or changed with no end | a reader gives up after 64 reads and takes the defaults (`settings.read`). The compositor tells the windows only when the values differ from the values that it told last (`settings.values_differ`): a new count with the same values sends no record into the ring of a window, which also carries its keys. Values that change with no end make the windows draw again: a cost of time, which the program `settings` also pays |
| `reserved` | any number | no reader |

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

### Where the time goes, and the fast blend (2026-11-11, second part)

Measured on the host, where the same code runs, with `-o:speed`, pinned to one core with `taskset`, each number the least of 3 000 batches of the line `compositor  12.4 ms  2 418 pages {fill} [rings] gi Rb 0O 1lI` (60 glyphs), and the least over four cores (host test `text_speed_parts`, `support/graphics/text_speed_test.odin`). Each batch draws over a fresh background, outside the time.

- **The words of one cell** (128 pixels at scale 1), on the mean: 64.4 pixels in rows with no ink (never read), 19.2 words of zero coverage (skipped), 1.0 word of full coverage (a store), **43.4 words of partial coverage**. So the time is in the partial pixels: each needs three blends in linear light (two squares, a sum, a shift and a load of the table of square roots for each channel). A walk over the words alone costs 11.2 ns a glyph.
- **The fast blend** (`graphics.blend_glyph_rows`, in `blend.odin`): for one text color over one pixel color, each channel of the result is a function of its coverage only. A **blend table** keeps the 3 x 256 results for one pair, in the memory of the program (`Blend_Tables`: 8 tables, 24 KiB, replaced in turn; a value is computed on first use with the formula of the reference, and a new table clears nothing: it takes a new generation in the high byte of each value). The choice is made for each row of a glyph: a row whose two end pixels have one color takes the table of that color, each pixel of that color in the row is three loads and a store; any other pixel takes the reference blend. Bit for bit: the host test `fast_blend_is_the_reference` draws each character at each scale, each order of the stripes, five colors, over a flat color, the gradient of a card, a gradient across and noise, two passes (the second over the first), and compares with the reference: 0 pixels differ. Since 2026-11-12 (after the merge with the SSE2 forms of `master`): a row that no table holds (its two ends differ: a gradient across, a picture) takes the form of the target, `blend_coverage_row_in_form_of_target` (SSE2 on amd64), not the scalar form; a lone pixel of another color inside a row stays scalar (the SSE2 form gives a lone pixel to the scalar form anyway). The host test `three_blends_give_the_same_bytes_for_each_cache` compares the table blend, the SSE2 form alone and the scalar form alone, byte for byte, with the caches of Paper Mono (three scales), Paper Mono SemiBold (scale 1) and B612 (each scale and each position, glyphs that overlap), over the four backgrounds. The host test `text_speed_of_each_blend` gives the time of one glyph in each of the three, over a flat color, a gradient across and noise, for the choice of one path for the flat case; it is written and not yet run on a quiet host. The expectation: the table blend stays faster over a flat color, because a partial pixel there is three loads from a table where the SSE2 form still takes the square roots one channel at a time; if the SSE2 form comes within about 10 % of it, one path (the SSE2 form) is better than two, and the blend tables (24 KiB for each program) go.
- **Not taken**: a run-length or a mask for each row in the cache (the zero words are skipped already, and the walk is 11 ns of 109); 16 bytes at a time (the partial pixels need three table loads each, which the processor does not gather); the tables filled whole when made (89 to 93 ns against 103 to 110 ns, but 768 square roots for each new pair of colors, which a gradient across pays at each row).

| One glyph, the least on the host | Scale 1 | Scale 2 | Scale 3 |
|---|---|---|---|
| Spleen 8x16 (at scale 2 and 3: its pixels enlarged) | 33.8 ns | 253 ns | 286 ns |
| The reference blend, over a flat color | 181 ns | 424 ns | 712 ns |
| The fast blend, over a flat color (the console, the cards) | **109 ns** | 285 ns | 497 ns |
| The fast blend, over the gradient of a card (top to bottom) | 110 ns | | |
| The fast blend, over a gradient across (a title bar) | 178 ns (the reference: 188 ns) | | |
| The fast blend, over noise (a picture) | 188 ns (the reference: 193 ns) | | |

At scale 1, a glyph from the cache over a flat color or a card now costs 3.2 times a glyph of Spleen (5.4 times before). At the scales 2 and 3 the vector font costs 1.1 and 1.7 times the enlarged Spleen, for a glyph drawn from its outline at that size. The rest of the time is the 43 partial pixels: a cell has 43 blends that Spleen does not do. The target "the same order as Spleen" is near at scale 1 and met at the scales 2 and 3; the machine measures of this part were taken at a load of 28 to 31 and are not valid.

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

- **A glyph made of glyphs** is read with two limits: at most 4 levels (`COMPOSITE_DEPTH`) and at most 64 parts in all its levels together (`COMPOSITE_PART_LIMIT`, since 2026-11-12). A part can be an empty glyph, which adds no point, so the limit of points does not bound the work: with no limit of parts, a glyph of 21 000 parts in four levels gives 21 000 to the power 4 calls (`review_fonts_hostile.md`, Weak point 1). The host test `a_composite_of_many_empty_parts_ends_at_once` builds that glyph. The composites of the candidates have 2 parts. A face number past the faces of a collection is the problem `No_Face`.
- **CFF** (Source Code Pro): its outlines are Type 2 charstrings, a small stack machine with cubic curves. The reader would need that interpreter (about 40 operators, subroutines, hints to skip) and the cut of cubic curves. Not built: five candidates have `glyf`.
- **A subset is a Modified Version** of the font under the OFL (OFL FAQ 2.6: "Removing any parts of the font [...] is considered modification. This is permitted by the OFL but would not normally allow the use of RFNs."). So a font with a Reserved Font Name is renamed in its subset ("IBM Mono ASCII"). Each subset keeps the copyright and the license text of its source in its name table and in a `.license` file beside it; `resources/fonts/OFL.txt` and `BITSTREAM_VERA_LICENSE.txt` have the full texts.
- **The subset command**: `kerneltool vector_fonts` reads `VECTOR_FONT_SOURCES` (the development shell sets it), writes for each candidate the characters 32 to 126 and `.notdef` as simple glyphs with no instructions (a glyph made of glyphs is made simple with its offsets and its scale in integers), the tables `OS/2` (of the source), `cmap` (one segment), `glyf`, `head`, `hhea`, `hmtx`, `loca`, `maxp`, `name`, `post`, with their checksums. It uses no time and no random value: the same input gives the same bytes. The subsets are in the repository, as the output of `kerneltool font` is: a build needs no build input.
- **A wider range** costs at most 4 bytes for each pixel of a cell, at three scales: 4 x (8 x 16 + 16 x 32 + 24 x 48) = 7 168 bytes for each character with ink in each row; about 4 100 bytes for each character on the mean with only the rows with ink. The 96 characters of Latin-1 would add about 390 KB; the subset grows by about 150 bytes for each character.

**The first default: JetBrains Mono** (`DEFAULT_VECTOR_FONT` in `tools/kerneltool/vector_fonts.odin`: one line). Why: at 8 x 16 its zero has a dot and its `O` does not, `1`, `l` and `I` differ, its x-height (550 of 1000) gives 7 rows like Spleen, its stems are even at the three scales, and the OFL with no Reserved Font Name lets the subset keep its name. DejaVu Sans Mono is close; Iosevka has the largest letters (its advance is half its em, so its em is 16 pixels) and the most condensed forms; Fira Mono is the heaviest; IBM Plex Mono needs a new name.

### Paper Mono, the font of the system

Decided by the owner: "Paper mono très bien pour monospace". Paper Mono (<https://github.com/paper-design/paper-mono>, SIL OFL 1.1, no Reserved Font Name: "Copyright 2025 The Paper-Mono.Git Project Authors [...] This Font Software is licensed under the SIL Open Font License, Version 1.1", read in `OFL.txt` of the repository; its name table says the same) is the default vector font in the place of JetBrains Mono: the console, the terminal, and every window until the interface font of section 12 exists. Its SemiBold takes the place of the bold weight of the titles. `DEFAULT_VECTOR_FONT` is `paper_mono`, `EMPHASIS_VECTOR_FONT` is `paper_mono_semibold`. JetBrains Mono stays a candidate; the host tests of the renderer keep it, so that a change of the default changes no golden hash.

The cap height and the x-height of Paper Mono (the pinned files, both weights): `OS/2` gives 710 and 509 units, and the tops of the outlines of H, E, F, T, Z, I are all 710, of x, z, v, w all 509. So the path of the monospace fonts, which takes them from the tops of `H` and `x`, gives the values that the font states; nothing changes (checked on 2026-11-12, after the correction of B612 in section 12.2).

The source: Paper Mono is not in nixpkgs. `flake.nix` fetches `fonts/ttf/PaperMono-Regular.ttf` and `PaperMono-SemiBold.ttf` at the commit `74fc5537cc1f7b39aa8cccfa7dd3822e17143cca`, each with its hash (106 088 and 106 900 bytes; the same bytes as the copies that the owner gave).

What its tables say, read on its files, against JetBrains Mono:

| | Paper Mono Regular and SemiBold | JetBrains Mono |
|---|---|---|
| Outlines | `glyf` (TrueType), 800 glyphs | `glyf` |
| Units for one em | 1000 | 1000 |
| Advance of each ASCII character | 606: one for all, monospace | 600 |
| The scale on the grid of 8 | 8 / 606: an em of 13.2 pixels | 8 / 600: 13.3 pixels |
| Ascender, descender (`hhea`, also the typo values of `OS/2`) | 955, -245 | 1020, -300 |
| Ink of ASCII 33 to 126, top and bottom | 803, -194: 13.2 pixels of height, in 16 rows | |
| Baseline (`glyph_style_of`) | row 12: the ink from about row 1.4 to row 14.6 | row 12 |
| x-height, cap height | 509, 710: 6.7 and 9.4 pixels; the grid fit gives 7 and 9 rows | 550, 730: 7 and 10 rows |
| Glyphs of ASCII made of glyphs | `i` and `j` (a stem and the dot glyph 559, placed by x and y offsets, flags `ROUND_XY_TO_GRID` and `USE_MY_METRICS`): the reader takes them, and the subset makes them simple | 4 |
| Pair spacing | `GPOS` only (3.9 KB), no `kern`: a monospace font on the grid uses none | `GPOS` |
| Box drawing U+2500 to 257F, block elements U+2580 to 259F | all 128 and all 32 | |

- Its capitals are one row shorter than those of JetBrains Mono at scale 1 (9 rows against 10) and its letters are 1 % narrower in the em. Its line is the same 16 rows.
- **Not in this step: the box-drawing characters.** The glyph cache holds ASCII 32 to 126; the console and the terminal send ASCII only. Paper Mono has each box-drawing and block character, so a wider cache (section 6, "a wider range") can take them later: about 4 100 bytes for each character with ink at the three scales.
- Not measured yet: the size of its glyph cache and of its SemiBold cache, and its look on the screen: the coordinator runs the tool (the commands are in the report of this step), and `build/fonts/candidates.png` and the picture `font_candidates` show it beside the others.

The picture of the choice: `font_candidates` (the program `vector_glyphs`: the same line in Spleen and in the six fonts, the large number at scale 2, a word enlarged 4 times; each candidate from a cache that the program builds), and `build/fonts/candidates.png` (`kerneltool vector_fonts`: the same lines at scales 1, 2 and 3 in each candidate and in Spleen, the default with and without the grid fit, a word of each enlarged 5 times; drawn on the host by the same `support/graphics`).

### A bold weight for the titles

The titles of the cards (the card of `support/interface` and of the boot display) are drawn in the emphasis weight of the font of the system: Paper Mono SemiBold (`resources/fonts/paper_mono_semibold.ttf`; Paper Mono has no Bold). With JetBrains Mono Bold, the first form, the ASCII subset was 14 212 bytes and its glyph cache at scale 1 only 30 720 bytes (all three scales: 391 936 bytes); the SemiBold has the same cells. The cache is a resource of the boot image mapped like the others. The draw record of the interface package is version 5: the byte `kind_detail` is the weight of a text (0 regular, 1 bold) and the thickness of a line. Bold at another scale, with Spleen, or with no bold cache, is the regular weight; the width of a text does not change.

## 7. The setting

The system had no settings menu. The smallest form that keeps the properties:

- **Where it lives**: one page, the settings page (`contract/settings`). The root service creates it at start. The page holds the choices only (the change count and one value for each setting): since 2026-11-12 it holds no address, no size and no hash of a glyph cache, because the program `settings` writes it (below, "Who can write a cache"). The program `settings` receives it with Write (the role `Settings` of the root service: the one writer). Each program with a surface, each terminal and the compositor receive it read-only at a fixed address, with its address in the value 13 of their context (P20: a grant of the root service, read-only; P9: no shared file). All zero is valid: the vector font, `rgb`.
- **A change while programs run**: `settings` writes the page (the change count is odd during the write) and wakes the threads that wait on the change count. The compositor waits on it: it gives the new choice to its own text, draws its whole screen again, and sends the display event `Settings_Changed` to each window. `support/display` gives the new font to `support/graphics` when the program reads the event, between two frames; `support/interface` draws the whole window at the next frame (each draw record is the same, each pixel of text is not). A program draws again as it does for any event.
- **The settings** (one value of the page and one row of `settings.descriptions` each; the window, the exports and the kept record read the same table): `font` (`vector`, `spleen`), `subpixel_order` (`rgb`, `bgr`, `none`), `pointer_theme` (`owner`, `system`) and `grid_fit` (`on`, `off`). Value 0 of each is its default.
  - **The pointer theme**: the root service gives the compositor both pointer theme files of the boot image (`pointer_theme_choice` in `programs/root/resources.odin` is still the one place of their order: the values 6 and 7, then 18 and 19); the compositor validates each once and the setting chooses one live (`pointer_theme_choose`, a log line "the pointer theme in use").
  - **The grid fit**: two glyph caches of the default font are resources of the boot image (390 624 bytes with the fit, 397 344 without: +397 344 bytes in the image); each program validates both once and the setting chooses one. The picture `font_without_grid_fit`.
  - **The scheduling strategy is not a setting.** The right `Schedule` belongs to `scheduler` (choice 276). The settings service must not get a kernel right to pass it on (P20: a service does not combine its own access with the request of a caller), and asking `scheduler` would need `scheduler` to run as a service at boot with that right. The person changes the strategy in `scheduler`, the program that holds the right. A strategy that survives a stop needs the root service, which holds the machine with each right, to read a record at boot: a later step, with its own grant decision.
- **The program `settings`**: a window of the interface package: each setting as a row of buttons (the pointer and the keyboard: Tab, then Enter), the text of the system at its three sizes, the facts of the glyph cache (size, hash, valid or not used). Exports with descriptions (P19): `settings.set(name, value)` (1, or an error record: `No_Grant` -1 for a caller that does not act for the person, `Absent` -2 for a name, `Bad_Value` -3 for a value) and `settings.get(name)` (a text), and `settings.repeat(count)` (count records kept, one commit each: the case of the loss of power). The console calls them after `connect("settings")`; `kerneltool call` calls them through `remote`.
- **The settings survive a stop** (2026-11-11, second part). `settings` keeps the values as one record of 48 bytes (`Kept_Settings`: a magic, a version, a count, 8 values) in one object of its private store (P9): a change writes the record (one commit) first, then the page. At boot the root service starts `settings` for a **boot pass** (the context value 17): it reads the record, writes the page, wakes the compositor and stops, with no window. The storage service and the block service of the data disk now start at boot for it (they started at the first use before). A record of another version, or none, gives the defaults.
- **The boot display uses the defaults**: it is drawn by the root service before the storage service runs, and reading the store earlier would need a reader of the store in the root service. The simplest right form: the defaults (the vector font, `rgb`) until the boot pass; then the compositor sees the change of the page and each window draws again with the kept settings (its first loop compares with a change count of 0, so a window that read the page before the boot pass is told too). The boot pass takes 23 ms in the machine test with a new disk.
- **A loss of power** (`kerneltool test power`, the case `power_loss_settings_run`): `settings.repeat(1000)` writes 1000 records, and the disk loses its power at the write of a root. Each of 306 images that a loss can leave (72 with a torn write) gives the durable record or the record in flight, never a mix, and each record is valid; the second machine starts on the hard image and its boot pass writes the durable record on the page.

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

- One glyph from the cache costs 3.2 times a glyph of Spleen at scale 1 over a flat color, and 5.3 to 5.6 times over a gradient across or a picture, where the blend tables do not apply (section 5).
- No grid fit of each stem; no stem darkening (`gui_toolkit` thickens the stripes by 0.2 pixel; not tried here).
- The boot display and the first frames use the default settings until the boot pass of `settings` (section 7).
- The scheduling strategy is not a setting and does not survive a stop (section 7).
- A proportional font, kerning and the characters outside ASCII are not built: the cache has no glyph outside 32 to 126 and no subpixel position.
- The order of the stripes of the screen is not detected: under QEMU it is the panel of the host, which the system cannot read.
- The measures of section 9 were taken on a host with a load above 8.

## 11. Decisions that the owner must make

1. **The font file**: decided: Paper Mono (section 6). Another candidate is one line, `DEFAULT_VECTOR_FONT`.
2. **The grid fit by default**: on (now) or off. It is now a setting of the person (both caches are in the boot image); the decision is only which value is 0.
3. **The order of the stripes by default**: `rgb` (now), or `none` until the system can know the panel.
4. **The interface font**: the size of B612 (an em of 13.33 pixels: capitals of 10 rows), and the positions of its cache (3 at scale 1 and 1 at the scales 2 and 3: 509 340 bytes measured with the Bold titles; or 3 everywhere: about 2.45 MB, estimated), section 12.
5. **The scheduling strategy across a stop**: a record that the root service reads at boot, or none (section 7).

## 12. The interface font and the text shaping module (design, not built)

Decided by the owner: "Go b612", and "Il nous faudra un module de text shaping/kerning". B612 (<https://github.com/polarsys/b612>, version 1.008, the package `b612` of nixpkgs; SIL OFL 1.1 with no Reserved Font Name: "Copyright 2012 The B612 Project Authors [...] This Font Software is licensed under the SIL Open Font License, Version 1.1", read in `OFL.txt` of its repository) becomes the font of the interface: the titles, the bar, the menus, the labels, the cards. It is proportional. Paper Mono stays the font of the text that is monospace (section 6). This section is the design; no code exists yet.

### 12.1 What B612 has, read in its files

| | B612 Regular | B612 Bold |
|---|---|---|
| Outlines | `glyf` (TrueType), 593 glyphs; no glyph of ASCII is made of glyphs | the same |
| Units for one em | 2000 | 2000 |
| Advances of ASCII 32 to 126 | 19 different values from 400 to 2000 units, the mean 1148; the space 700; `i` and `I` 600; `m`, `M` 1800; `W` 1900 | the same advances |
| Digits | each 1300: digits are tabular, a column of numbers aligns | the same |
| Ascender, descender (`hhea`, typo of `OS/2`) | 1930, -500; the ink of ASCII from -517 to 1720 | 1930, -500 |
| x-height, cap height (`OS/2` sxHeight, sCapHeight) | 1100, 1500. The flat tops of E, T, Z are at 1500; the stems of H, I, L end with an angle at 1520, and `x` reaches 1117 | 1100, 1500; the top of H is 1527 |
| Ink beyond the advance box | at most 61 units left of the origin (`j`), none past the advance | 126 left (`j`), 52 past the advance (`K`) |
| Pair adjustment | `kern` version 0, one subtable of format 0: 1017 pairs; `GPOS` with one lookup of type 2 (pair adjustment, subtables of format 1 and 2), feature `kern` | `kern`: 1061 pairs; `GPOS` the same form |
| Substitution | `GSUB` with no feature: no ligature, no contextual form | the same |
| Box drawing | none | none |

- **For ASCII, `kern` and `GPOS` give the same pairs**: 232 pairs in Regular and 239 in Bold whose two glyphs are ASCII, each with the same value in both tables, none in one table only (read on the files with a script of the agent, not with code of the system). The values are -200, -150, -100 and +100 units in Regular, and also -50 and +50 in Bold: at the size below, -1.33 to +0.67 pixel. Examples: "To", "LT", "Ty" -100; "LV" -150; "Wa" -100 in Bold only. **"AV" has no pair** in either weight: B612 spaces "A" and "V" by their advances alone.
- So the first version reads `hmtx` and `kern` format 0 only. It reads no `GPOS` and no `GSUB`, and has no ligature and no other script. A font whose pairs are only in `GPOS` needs the `GPOS` reader later, behind the same contract.

### 12.2 The size on the grid

- The line stays 16 pixels at scale 1 (32, 48 at the scales 2 and 3), so a label sits in a line of the grid as text does now.
- The em of B612 at scale 1 is 13.33 pixels (2000 units to 13.33 pixels, one unit is 1/150 of a pixel): its cap height is then 10 pixels and its x-height 7.33 (the grid fit of section 2 gives 7). The cap height and the x-height are the values that the font states in `OS/2` (1500 and 1100), not the tops of the outlines of `H` and `x` (1520 and 1117 in Regular, 1527 and 1124 in Bold), which the monospace path uses (section 2): the flat tops of the capitals must sit on whole rows, and both weights get one scale. A host test checks that E, T and Z have ink on rows 2 to 11 exactly. Its ink, from -517 to 1720 units, is 14.9 pixels: inside 16 rows, with the baseline on row 12.
- Its mean advance in ASCII is 7.65 pixels: a label in B612 is about as wide as in Paper Mono (8 pixels), narrower for lowercase text, wider for capitals (`M` 12 pixels).

### 12.3 The text shaping module

A module (the owner's word; property 10: shared code with exports), with batch exports whose parameters are tables (`MODULE_CONTRACT.md`, "Tables and bytes as parameters"). Its name: `text_shaping`. Written (step 3 of 12.8): the package `support/text_shaping` for a direct call, and the module `modules/text_shaping` over it, as `support/interface` and `interface_module`.

**As written:**

| Export | Parameters | Result |
|---|---|---|
| `shape_text` | the advances (Read, 95 records of an `i32`), the pairs (Read, `glyph_cache.Pair_Entry`), the text (Bytes, Read), the placed glyphs (Append), the error record | the count of placed glyphs of the full answer, or -1 |
| `measure_texts` | the advances, the pairs, one table of bytes (Read), the ranges (Change: `start`, `count`, and `width` that the export writes) | the count of ranges, or -1 |

- **The spacing is two tables of the caller**, the advances and the pairs of one scale of its glyph cache (`text_shaping.spacing_of`). So the module holds no font and no state: an isolated call receives them in the call region like the text.
- **Hostile tables**: the counts are checked (95 advances, at most 9 025 pairs, a text of at most 65 536 bytes, a table of at most 2^40 records). The caller can change its tables during the call, so no value is checked once and used later: each advance, pair, byte and range is read once, and kept in its limits at that read (an advance 0 to 64 pixels, an adjustment -64 to 64 pixels). Pairs out of order give wrong numbers, never a read out of the table. The x of each glyph then holds in an `i32`.
- **A character outside the cache** (a control character, a byte above 126) is placed as `?`, so a person sees that the font does not draw it.
- **The widths in a table of ranges**: the width is a field of each range record, which the export writes (the direction Change), as `sum` in the records of `sample.sum_words`. So `measure_texts` has five parameters, and a sixth (the table of error details of `master`, `MODULE_CONTRACT.md` section 8) fits after the merge.

**The design before the code:**

- **Input**: the font (a record: its kind, its scale, its weight) and a table of characters: the bytes of a text, ASCII 32 to 126 in the first version.
- **Output**: a table of placed glyphs, one for each character, in memory of the caller. A placed glyph is 16 bytes: the glyph (its index in the glyph cache), x (its origin from the origin of the run, in 1/64 of a pixel), the advance in 1/64 of a pixel (with the pair adjustment that follows it), and 4 bytes that are zero (a cluster number for a full shaper later).
- **The measure of a text** is the sum of its advances: one export `text_width` that gives it with no output table, for the layout.
- **Many texts in one call**: a second form takes a table of runs (each a start and a count in one table of bytes) and fills one table of placed glyphs and one table of widths: a window measures all its labels in one call.
- **What it reads**: not the font file. The kernel tool writes the advances and the pairs into the glyph cache of the font (version 2 of the format, below): for each scale, the advance of each character in 1/64 of a pixel, and the pairs of ASCII with their adjustment in 1/64 of a pixel (232 pairs, sorted, 8 bytes each). The module works over a cache that the program already validated: no parse at run time, the same rule as the glyph cache.
- **The work for one character**: one load of its advance, one search of the pair with the next character in a sorted table of 232 (8 compares), or one load of a table of 95 x 95 adjustments (9 025 bytes for each scale, which the tool can write in place of the list).
- **The same contract takes a full shaper later**: characters in, placed glyphs out. A shaper with ligatures gives fewer glyphs than characters and uses the cluster number; the callers already read the count of the output.

### 12.4 The glyph cache with subpixel positions

- **Positions**: a glyph of a proportional font does not start on a whole pixel. With the subpixel bands, the finest step that the screen shows is one third of a pixel: the cache keeps each glyph at 3 positions, 0, 1/3 and 2/3 of a pixel. The draw rounds the x of a placed glyph (in 1/64) to the nearest third, so the error is at most 1/6 of a pixel; the shaper keeps the exact sum, so errors do not add up along a run.
- **The cell of a glyph** is its ink box, not the cell of the grid: its width is the ink width plus the spread of the filter (two thirds of a pixel on each side) plus the position, its left side at a stated bearing from the origin. The glyph entry gains this width and this bearing (`left`, `width`). Written: one format, version 2 of `contract/glyph_cache`, for the monospace caches too (section 5): fewer paths than two formats, and the tool writes every cache again.
- **The renderer** (`vector_font.glyph_render_placed`): the glyph is drawn in a work row of 64 pixels with its origin at column 4 plus the position (one third of a pixel for each step), then cut to the box of its ink. A glyph whose ink reaches a side of the work row is refused. The size on the grid: the cap height is 10 rows at scale 1 (`PROPORTIONAL_CAP_HEIGHT_ROWS`), so 1 200 units of B612 are the 8 pixels of a cell (the stated cap height of 1 500 units times 8 / 10). The advances and the pairs are scaled the same way and rounded to 1/64 of a pixel, each on its own, to the nearest integer, a half toward plus infinity, the same rule for a negative value: "A" 1 300 units is 554.67, so 555/64 of a pixel at scale 1; "To" -100 units is -42.67, so -43/64; "LV" -150 units is -64/64 exactly.
- **The rule of the sum**: the cache keeps the rounded advance and the rounded adjustment, and the shaper adds these integers. So the advance of a glyph followed by a pair is round(advance) + round(adjustment), not round(advance + adjustment): "T" before "o" is 512 - 43 = 469. The two rules can differ by 1/64 of a pixel for one pair; the x of each glyph is the exact sum of the integers before it, so no error adds up along a text beyond the rounding of each term (at most 1/128 of a pixel each).
- **Size, measured** (`kerneltool vector_fonts`, 2026-11-11): B612 Regular with 3 positions at scale 1 and 1 at the scales 2 and 3, **408 524 bytes**; B612 Bold at scale 1 with 3 positions, **100 816 bytes**; together **509 340 bytes**. These two were measured with the cap height taken from `H` (1 520 units), before the correction above: with 1 500 the glyphs are 1.3 % larger on each axis, so the next run gives a few percent more. The table below is the estimate from the boxes of the glyphs, made before the build; it was 10 % (Regular) and 18 % (Bold) above the measures:

| Cache | 1 position | 3 positions at each scale | 3 positions at scale 1, 1 at the scales 2 and 3 |
|---|---|---|---|
| B612 Regular, scales 1 to 3 | 376 KB | 1 165 KB | 452 KB |
| B612 Bold, scales 1 to 3 | 415 KB | 1 288 KB | 497 KB |
| B612 Bold, scale 1 only (the titles) | 39 KB | 123 KB | 123 KB |
| Today: the cache of the monospace font | 390 624 bytes | | |

- **Recommended, and built**: B612 Regular with 3 positions at scale 1 and 1 position at the scales 2 and 3, and B612 Bold at scale 1 with 3 positions: 509 340 bytes measured (575 KB estimated) more in the boot image, when they become resources. At the scales 2 and 3 a glyph on a whole pixel is at most half a pixel from its place in a glyph of 26 to 40 pixels. With 3 positions everywhere, 2.45 MB.

### 12.5 What changes in `support/interface`

- **A font kind**: `Font_Kind` gains `Interface` (B612), beside `Cells_8x16` (the monospace font). The weight stays the byte `kind_detail`.
- **The text record**: its x is the origin of the run, its `text_subpixel_x` the fraction of the origin in 1/64 of a pixel (the field exists since the first format), its width the width that the caller measured with the shaping module. Its rectangle for the damage is the measured box widened by a margin of the font on each side: 2 pixels for B612 (its ink passes the box by at most 126 units, 0.84 pixel, and the filter by two thirds of a pixel). So the damage stays exact with no new field.
- **The draw**: `execute` asks the module for the placed glyphs of the run, then draws each glyph from the cache at its third of a pixel. The glyphs of one run can overlap by their margins: the blend reads the pixel under, so an overlap is drawn right.
- **The grid of 8 stays for the places of the elements**, not for the letters: a card, a button, a line of a table start on the grid; the text inside starts at the inner place of the element, and its width is what it is. A size of a column that came from a count of characters (`characters(n)`) stays n times 8 for the monospace font; a new size `measured(text)` gives the width of a text in the interface font, rounded up to the grid.
- **Elements that change**: the title and the caption of a card, a label of `label_value_line`, a button, a line of a list, the bar and the menus of the compositor, the title bar of a window. The values of `label_value_line` that are numbers stay monospace (the rule below).

### 12.6 Which text stays monospace

A rule that a program can follow:

- **Monospace (Paper Mono)**: each text that is a grid of cells (the terminal, the console, `Text_Grid` records); each text that a person compares character by character or copies (hashes, addresses, names of exports, code, the text of a log record); the columns of a table whose values align by character.
- **Interface (B612)**: each text that names or explains: titles, captions, labels, buttons, menus, the bar, the title of a window, sentences of help.
- **Numbers**: in either. The digits of B612 are tabular (1300 units each), so a column of numbers aligns in B612 too, at the right of its column (`DESIGN.md`, section 5).

### 12.7 The cost for each glyph, against today (estimated, not measured)

- **Shaping**: one advance and one pair for each character: a few nanoseconds, against 0 today (the advance of a monospace font is a constant).
- **Drawing**: the box of a glyph at scale 1 holds about 100 words with 3 positions, against about 64 words in the rows with ink of a cell today; the partial pixels are about the same (the ink is the same). Expected about 1.2 times the fast blend of today (109 ns on the host at scale 1 over a flat color).
- **The measure of a label**: one call of the module for all the labels of a frame; today `text_width` is a multiplication.

### 12.8 The steps, each one working

Steps 1 to 3 are written (2026-11-11); step 2 also writes the two caches of B612 in `build/fonts` at each `kerneltool vector_fonts`, which are not yet resources of the boot image.

1. **The shaping data in the tool**: `kerneltool vector_fonts` subsets B612 Regular and Bold (ASCII, simple glyphs, `kern` format 0 kept as a sorted pair table) to `resources/fonts`; host tests: the advances and the pairs of the subset against the font file, and the pairs of `kern` against those of `GPOS` (the check of 12.1, as code).
2. **The glyph cache version 2**: a glyph entry with its box width, its bearing and its positions; the advances and the pair table of each scale; its validation; the builder in `support/vector_font`; host tests: the bit-for-bit test of each position against a render at that offset, the golden hashes, damaged fields.
3. **The shaping module** `text_shaping` with its exports over a validated cache; host tests: a run of each pair of ASCII gives the advances plus the pairs; the measure is the sum; many runs in one call give the same as one run at a time.
4. **`graphics.text_placed`**: draw a table of placed glyphs with the fast blend at thirds of a pixel; host tests bit for bit against the reference blend; the measure of section 5 for B612.
5. **The resources and the settings page**: the two B612 caches as resources of the boot image, mapped like the others; a fallback to the monospace font when they are absent or refused.
6. **`support/interface`**: the font kind `Interface`, the text record with its origin fraction and its margin, `measured(text)`; the card, the label, the button, the list in B612; the damage tests with overlapping glyphs.
7. **The compositor**: the bar, the menus, the title bars, the launcher in B612.
8. **`DESIGN.md`, section 5**: the rule of the two fonts of 12.6 replaces "one font at a time, on the grid of cells" (a change of a design rule: written when step 6 lands).

### 12.9 Where this design is least sure

- The sizes of 12.4 of the two caches that are built are measured; the other columns of its table are estimates from the glyph boxes, which were 10 % to 18 % above the measures.
- The cost of 12.7 is an estimate; the fast blend tables need two pixel colors at the two ends of a row of a glyph, which holds for a label on a card, not for a title bar with a gradient across (the reference blend there, as today).
- `kern` and `GPOS` agree for ASCII in B612 1.008; a later version of the font, or another interface font, can have pairs in `GPOS` only.
- 3 positions and not 4: the step of the stripes is a third; a finer step is invisible with the subpixel bands and costs one more copy of each glyph.
