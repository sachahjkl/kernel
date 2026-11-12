title: Paper Mono is the font of the system
date: 2026-11-11
release: 0.74.0
picture: docs/screenshots/font_vector.png
kind: Decided
guide: docs/FONTS.md

Paper Mono is now the monospace font of the system. The console, the terminal and every window now draw their text in Paper Mono, in place of JetBrains Mono. The grid stays 8 by 16 pixels. The titles of the cards are in Paper Mono SemiBold. Paper Mono is under the SIL OFL 1.1. In the same release, a glyph of the vector font over a plain background takes 109 ns in place of 181 ns on the host, the least of many runs, with the same pixels.
