type: Security

**A hostile font file no longer stops the reader.** A glyph made of thousands of empty parts made the font reader run for an unbounded time; the reader now stops at 64 parts, and a glyph cache whose monospace glyphs leave their cells, or whose header has unknown flags or a name with no end, is refused.
