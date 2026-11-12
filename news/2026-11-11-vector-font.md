title: The text of the system is a vector font
date: 2026-11-11
release: 0.58.0
picture: docs/screenshots/font_candidates.png
kind: Shown
guide: docs/FONTS.md

Every window, the console, the terminal and the boot display draw their text with a vector font, with subpixel bands, blended in linear light. The first font was JetBrains Mono. The font is monospace on the grid of 8 by 16 pixels, so no window changes its size. The build draws each character 32 to 126 at three scales into one glyph cache of 390 624 bytes in the boot image. One glyph from the cache takes 309 ns, against 35 ns for Spleen 8x16, in the machine of the test. The program `settings` changes the font to Spleen 8x16 and back while every program runs. The picture compares six candidate fonts.
