type: Changed

**The text of the vector font is blended four pixels at a time**: the blend of a glyph over a pixel, in linear light with the three subpixel bands, runs in the SSE2 registers and gives the same pixels as before.
