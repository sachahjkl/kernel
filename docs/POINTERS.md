# Pointer pictures

The request of the owner (2026-11-11, dictated): the system gets its own format for the pictures of the pointer, simple to manage and to package; the pointer theme that the owner uses on Linux, "Posy's Cursor", is imported, converted and adjusted; a tool packages it; the format is "un format de manifeste simple le format texte qui est facile à parser [...] ou même binaire d'ailleurs mais je te laisse choisir".

The terms are in `GLOSSARY.md`: pointer, pointer shape, pointer picture, hot spot, nominal size, pointer theme, pointer theme file, pointer manifest, resource, caret. The system says "pointer", never "cursor". The caret of a text input is another thing.

## 1. What exists

### The Xcursor format (X11, and Wayland compositors that read X themes)

Source: the manual page `Xcursor(3)` of libXcursor (x.org, read on 2026-11-11), and the files of `posy-cursors` 1.6 read by the tool. All numbers are 32-bit little-endian.

- **File header**: `magic` "Xcur", `header` (16), `version` (0x10000), `ntoc`, then `ntoc` entries of the table of contents: `type`, `subtype`, `position` (an absolute byte offset).
- **Image chunk** (type 0xFFFD0002): `header` (36), `type`, `subtype` (the nominal size), `version` (1), `width`, `height` (each at most 0x7FFF), `xhot` and `yhot` (at most the width and the height), `delay` (milliseconds to the next frame), then `width * height` pixels, each 0xAARRGGBB with premultiplied alpha.
- **Comment chunk** (type 0xFFFE0001): subtype 1 copyright, 2 license, 3 other; a length and UTF-8 bytes. The Posy files have none.
- **Several sizes** in one file: one image chunk for each nominal size. **An animation**: several image chunks of one nominal size, in order, each with its delay.
- **Names and aliases**: a theme is a folder `cursors/` with one file for each name. Aliases are symbolic links. In `posy-cursors` 1.6, `Posy_Cursor/cursors` has 122 names: 17 files and 105 links, some through another link (`no-drop` to `cross` to `precise`). Each file has the nominal sizes 32, 48, 64, 96 and 128 (`watch` and `background`: 77 frames of 33 ms at 32, 48, 64 and 96: 5 MB each).
- **The names**: the freedesktop "cursor naming" draft lists the CSS names (`default`, `pointer`, `text`, `wait`, `progress`, `not-allowed`, `ew-resize`, ...) and the old X names (`left_ptr`, `xterm`, `watch`, `fleur`, ...) and hashes of X bitmaps (`9d800788f1b08800ae810202380a0822`). A theme gives each name as a link to its few real files.

### Windows `.cur` and `.ani`

- `.cur` is the `.ico` container with type 2: a directory of images, each a BMP or a PNG, and the two fields that `.ico` uses for the planes and the bits per pixel hold the hot spot.
- `.ani` is a RIFF file "ACON": an `anih` header (the count of frames and steps, a default rate in 1/60 s), an optional `rate` and `seq ` table, and a `LIST fram` of `.cur` images. Posy made the theme for Windows first; the Linux port converted it with `win2xcur`.

### The Wayland cursor shape protocol (`cursor-shape-v1`, wayland-protocols 1.48)

- A client does not send pictures. It names a shape from an enum of 34 CSS names (36 in version 2: `dnd_ask`, `all_resize`), and the compositor draws its own theme.
- The request carries the serial of the latest `wl_pointer.enter`: a client sets the shape only while the pointer is over its surface. This system takes the same rule (property 20).

## 2. What this system needs

### The pointer shapes

One enum of the system, `Pointer_Shape` in `contract/pointer_pictures`, with one long name for each. Zero is the arrow: a zero record asks for the default (ZII). The CSS names are the sources in the manifest of the theme of the owner.

| Number | Name | CSS name | Where the system uses it today |
|---|---|---|---|
| 0 | `arrow` | `default` | the desktop, the bar, the frame of a window, a surface by default |
| 1 | `text` | `text` | the input line of the launcher; the surface of the terminal (a request of the program) |
| 2 | `pointing_hand` | `pointer` | the close button of a window, the buttons of the bar, a line of an open menu |
| 3 | `move` | `move` | a title bar, and a window while the person moves it |
| 4 | `grab` | `grab` | a request of a program |
| 5 | `grabbing` | `grabbing` | a request of a program |
| 6 | `wait` | `wait` | a request of a program; animated |
| 7 | `busy_with_arrow` | `progress` | a request of a program; animated |
| 8 | `forbidden` | `not-allowed` | a request of a program |
| 9 | `help` | `help` | a request of a program |
| 10 | `crosshair` | `crosshair` | a request of a program |
| 11 | `resize_left_right` | `ew-resize` | a request of a program (a window has no resize yet) |
| 12 | `resize_up_down` | `ns-resize` | a request of a program |
| 13 | `resize_top_left_bottom_right` | `nwse-resize` | a request of a program |
| 14 | `resize_top_right_bottom_left` | `nesw-resize` | a request of a program |

Not taken: the CSS names that no part of the system has a use for (`context-menu`, `cell`, `vertical-text`, `alias`, `copy`, `no-drop`, the eight single-side resizes, `all-scroll`, `zoom-in`, `zoom-out`). A new name is a new number at the end of the enum.

### The request of a program

A program asks for a pointer shape with the display command `Pointer_Shape` (`support/display`, `display.pointer_shape_set`). The compositor keeps one shape for each surface. It shows that shape only while the pointer is over that surface and the surface is the one in front at that place (property 20: a program does not change the pointer over another program, the bar or a frame). A number out of the enum is ignored.

## 3. The format of the system: one pointer theme file

`contract/pointer_pictures`. One file for a whole theme, mapped read-only and read in place: no parse at run time, one validation at the start. All numbers are little-endian; each header is of fixed size; no field depends on a language.

```
Header           512 bytes  at 0
Shape_Entry      16 bytes   x shape_count, at 512
Picture_Entry    32 bytes   x picture_count, after the shapes
(zero bytes to a multiple of 64)
pixels           u32 each   at pixel_offset, pixel_size bytes
```

- **Header**: `magic` (the bytes "POINTERS"), `version` (1), `shape_count`, `picture_count`, `pixel_offset`, `pixel_size`, `file_size`, `theme_name` (32 bytes), `license` (32 bytes, an SPDX identifier), `attribution` (400 bytes). The texts are ASCII 32 to 126 followed by zero bytes, so that the font of the system shows them.
- **Shape_Entry**: `shape` (the number of the enum), `first_picture`, `size_count`, `frame_count`. The pictures of a shape are `size_count * frame_count` entries from `first_picture`: the frames of the smallest size, then of the next. Two shapes can name the same pictures (two names, one file, as the links of an Xcursor theme).
- **Picture_Entry**: `nominal_size`, `width`, `height`, `hot_spot_x`, `hot_spot_y`, `delay_milliseconds` (0 for a shape with one frame), `pixel_offset` (from the start of the pixels).
- **Pixels**: 0xAARRGGBB with premultiplied alpha, the form of an Xcursor file and the form of a canvas of `support/graphics` (0x00RRGGBB) plus alpha in the high byte. The blend reads the alpha from the same word and adds the source to the destination with no conversion. Straight alpha needs three more multiplications for each pixel.

**The validation** (`pointer_pictures.validate`) is one function that the tool and the compositor run. The compositor does not trust the file, also from the root service. It checks: the magic, the version, the size of the file, the tables inside the file, `pixel_offset` exactly after the tables, the texts, the shapes in increasing order with no repeat and the arrow present, each picture range inside the table, 1 to 8 sizes and 1 to 256 frames, each picture 1 to 256 pixels wide and high, its hot spot inside it, its nominal size 1 to 256, the same nominal size for the frames of one size and an increasing size from one size to the next, a delay of 1 to 60000 ms for an animation and 0 else, the pixels inside the pixel area and aligned on 4 bytes, and each pixel premultiplied (no channel above its alpha). A failure gives a `Problem`: the table, the index, the field, the value and its limit, and a sentence. The host tests damage each field.

## 4. The manifest

A text file in the repository (`resources/pointers/`). One grammar for the two sources of pictures: the files of an Xcursor theme, and grids of squares in the manifest itself.

```
manifest  = { line }                        lines end with "\n"; ASCII 32 to 126 only
line      = [ statement ] [ "#" comment ]   blank lines and comments are skipped
statement = "theme" text                    the name of the theme: 1 to 31 characters; once, first
          | "license" word                  an SPDX identifier: 1 to 31 characters; once
          | "attribution" text              to the end of the line; more lines add to it (399 characters at most)
          | "sizes" number { number }       the nominal sizes of each shape, increasing; once, before the shapes
          | "shape" name { source } { option }    one line for each shape of the theme
          | "frame" number                  a new frame of the shape above, with its delay in ms
          | "|" { "X" | "." | " " }         one line of a grid of the shape above: black, white, nothing
option    = "hot" number number             the hot spot: in pixels of the smallest size for a source, in squares for a grid
          | "sizes" number { number }       the sizes of this shape, in place of the default
source    = file name                       a file of the Xcursor folder; the first one that exists is used
```

- The words are separated by spaces. `hot` and `sizes` are reserved: they cannot be a file name.
- A shape has sources or a grid, not both. A grid has at most 12 squares in a line and 12 lines; a square is `size / 12` pixels, so each size of a grid is a multiple of 12.
- A source is followed through its links (8 at most) inside the folder. The Xcursor file is hostile input: each offset and count is checked before a read.
- For a source, a size of the list must be a nominal size of the file: the tool does not scale pixels. A `hot` adjustment is in pixels of the smallest size; the tool multiplies it for the other sizes.
- An error gives the file, the line, the column, and what was expected: `resources/pointers/posy.manifest:12:7: expected a pointer shape name such as "arrow"; found "arow"`.
- No JSON, no TOML: the system has no general parser and needs none.

## 5. The two themes

- **The theme of the system** (`resources/pointers/system.manifest`, under the license of the repository): the 15 shapes as grids of squares, in the style of the arrow of `DESIGN.md`, at the sizes 24 (squares of 2 pixels) and 48 (squares of 4 pixels, for a later screen with twice the pixels). `wait` and `busy_with_arrow` have 4 frames of 250 ms. It is always in the boot image, as the resource `pointers_system`.
- **The theme of the owner** (`resources/pointers/posy.manifest`): "Posy's Cursor" from the build input `posy-cursors` of `flake.nix` (the package of nixpkgs, pinned by `flake.lock`). The flake gives its folder to the tool as `POINTER_THEME_SOURCE`. The tool converts it at each build into `build/pointers/posy.pointers`, which the boot image holds as the resource `pointers_posy`. No file of that theme and no file made from its pixels is in the repository (section 6). Sizes: 32 (the smallest size of the theme) and 64 for the later screen; the two animated shapes keep 32 only (77 frames: 315 KiB at 32, 1.26 MiB more at 64).
- **The choice of the compositor**: `pointers_posy` when the boot image has it, else `pointers_system`. With no build input, the tool makes the theme of the system only, and the system works the same.

## 6. The license of the theme of the owner

Read on 2026-11-11:

- nixpkgs (the pinned input of `flake.nix`), `pkgs/by-name/po/posy-cursors/package.nix`: version 1.6, source `github:simtrami/posy-improved-cursor-linux` tag 1.6, `license = lib.licenses.cc-by-nc-40`. That license has `free = false` and `redistributable = false` in nixpkgs: the flake must allow this one unfree package by name (`allowUnfreePredicate`), and the binary cache of NixOS does not hold it (the build fetches it from GitHub).
- The upstream repository, README: "This is a Linux port of Michiel de Boer's amazing cursor design." and "This work and the original work are licensed under a Creative Commons Attribution-NonCommercial 4.0 International License (free to use, change and distribute for non-commercial use)." The `LICENSE` file is the full text of CC BY-NC 4.0.
- The author, http://www.michieldb.nl/other/cursors/: "Posy's improved cursors for Windows 10 (and older)", "A project from 2018", and "License: \"Attribution-NonCommercial\" (free to use, change and distribute for non-commercial use)" (the license note was added on 2024-10-16; version 1.5 of the Windows sets is of 2026-10-06).
- CC BY-NC 4.0, section 2(a)(1): the right to reproduce and share, and to make and share adapted material, "for NonCommercial purposes only". Section 3(a): a share keeps the name of the creator, a notice of the license with its URI, and says if the material was modified.

What follows for this repository: property 2 of the objective of `PROPERTIES.md` reuses what is "permissively licensed"; a NonCommercial license is not. So the repository holds the manifest and the tool, and the build makes the theme file from the input. The theme file carries the license `CC-BY-NC-4.0` and the attribution: "Posy's Cursor by Michiel de Boer (Posy), michieldb.nl/other/cursors; Linux port 1.6 by simtrami, github.com/simtrami/posy-improved-cursor-linux; CC BY-NC 4.0, creativecommons.org/licenses/by-nc/4.0; converted by kerneltool: the sizes 32 and 64, no pixel changed". The program `pointers` shows it with the theme.

## 7. Decisions that the owner must make

1. **The theme of the owner in the repository.** (a) Vendor the theme file in the repository under CC BY-NC 4.0, with its attribution: then the repository is not under one permissive license, and a commercial use of the system needs another theme. (b) Keep it as a build input, as now. (c) Ask Michiel de Boer for a permissive license for this system.
2. **The default theme.** The theme of the owner when the build has it (now), or the theme of the system always, with the theme of the owner as a choice of the person.
3. **The exception of `DESIGN.md`** (the pointer is the one picture with smooth edges): keep it, or reverse it.
