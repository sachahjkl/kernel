# The pictures of the mark

## Purpose

The mark is data in `src/library/support/mark`: the cells of the heron, the colors of its parts, the animations and the moves. Many files show it: the files of the repository, the pictures and the icons of the site, the tile maps of the animations, a picture for a developer. One generator of the tool turns a request into the bytes of a file, so that a change of the mark changes each picture, and no two places compute the same picture.

The command and its options are in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The pictures of the mark". The variants and the table of the uses are in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The variants of the mark".

## Constraints

- The gradient of each part gives the heron its look. A picture, such as the head of the home of the site, keeps it.
- A small icon, one pixel for a cell, has no room for a gradient inside a cell: there it only lowers the legibility.
- The browser computes no color of the heron. The tool makes each pixel; a page shows a picture at its own size.
- A file loses no pixel: only a lossless encoding.
- The logic of the pictures is in one place. A command that writes pictures holds a list of requests, and no number of a picture.
- A request with no sense is refused with a sentence. It is never bent into another request.

## The chosen form

**Two variants, named by the request** (`docs/DECISIONS.md`, D-245). In the smooth variant a pixel takes the gradient of its part at the centre of the pixel. In the cells variant a pixel takes the gradient at the centre of its cell, so a cell is one color at every cell size. Each drawing procedure of `src/library/support/mark` takes the variant as a required argument: the choice is which mark a place wants, not an option of a renderer, and a caller that does not think about it does not compile.

**The rule of the choice.** A picture is smooth. A small icon is cells. The program `heron` and the boot display are pictures; the bar of the desktop and the bar of the site are small icons.

**The smooth variant needs two pixels for a cell.** At one pixel the centre of the pixel is the centre of the cell, so the picture is the cells variant. The request must say so: `src/library/support/mark` draws nothing for the smooth variant at one pixel, and the generator refuses it.

**A request says what and how.** What: the still mark, a frame of an animation, a tile map, the table of a tile map, the picture for a developer. How: the variant, the cell size, the color scheme, the background, the size of the picture, the name under the heron, the rows of a tile map. The generator gives the bytes of the file, or the sentence of a refusal.

**One table of the uses.** Each file of the mark of the repository and of the site is a row: where it goes, what it holds, how it is drawn. The command that writes the files of the repository and the command that writes the site ask for their rows. A new file is a new row. The guide shows the table, and the command prints it.

**A tile map carries its table.** The table says where each tile is, how long each picture of an animation stays, and how the heron moves, in whole cells. A script that plays the animations copies tiles and places them. It holds no number of the mark and computes no picture.

**The smallest file of the encoder.** The generator encodes at the highest level of the deflate of the standard library, once with each row filter, and keeps the smallest. The pixels decide the result, so the same pixels give the same bytes.

## Refused forms

- **One pixel for a cell on the home, made larger by the page.** The file is small, but a cell is then one color: the gradient of a part goes from cell to cell, and the heron loses its look.
- **A gradient that the script of the page draws.** It gives the same pixels from a small file, but the browser then computes the picture. The pictures of the site are made by the tool.
- **A palette.** A tile map has more than 256 colors in each color scheme. Two files for each color scheme cost more requests than the bytes that they save.
- **A variant chosen from the cell size.** It hides the choice: the same cell size can want either variant, and a picture at one pixel for a cell would be called smooth.
- **A variant as an optional argument with a default.** A caller that was written before the variants would compile and take a variant that nobody chose for it.
- **A lossy encoding.** A picture of square cells shows each wrong pixel.
- **A list of pictures in each command.** Two lists drift, and two places then compute one picture in two ways.

## Subtle points

- **The first tile of a tile map of the home is the still picture of the home, pixel for pixel.** Else the heron changes when the script starts. The site refuses to build when the two rows of the table differ in their variant or their cell size.
- **The icon of the tab has a tile map of its own.** Its tiles are the cells variant at one pixel for a cell in the light scheme, as the icon of 32 pixels of the icon file. A tile of the home cannot be made smaller without a loss.
- **A tile map holds the heron alone, on nothing, each tile at the size of the heron.** A script lays a tile over a page. A request for a tile map with a name, a background or a size is refused.
- **The check of the files of the repository compares pixels, not bytes.** The bytes of the compressed stream depend on the compressor of the compiler release.
- **The cells variant is allowed at each cell size.** It gives one color for a cell in a large picture; the rule of the choice does not use it there, and the generator does not refuse it.
- **A host test reads the sources of the tool.** It fails when a file outside the generator calls a drawing procedure of `src/library/support/mark`. It runs from the root of the repository.
- **The picture for a developer keeps the rule on texts.** The text under a frame or a form is inside its box, on two lines where one is too long, and the tool stops on a text that is wider than its box.

## State

Built: the two variants in `src/library/support/mark`; the generator for the still mark, a frame, a tile map, its table and the picture for a developer; the command; the table of the uses; the two commands that write the files as callers; the host tests of each kind of request and of each refusal.

Left: the icon file with several sizes and the vector icon of the site are written outside the generator, from its pictures and from the cells. The icons of the site have a table of their own. Some names in the files of the generator still say that they belong to the site.
