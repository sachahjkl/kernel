type: Added

**A news entry can show a film**: an entry names a film with the line `film: docs/films/<name>.webm`, and the page of the news plays it when the reader starts it, with the picture of the entry in its place before that. `kerneltool film <name>` now writes a WebM file with AV1 beside its MP4 file, and puts it in the repository when an entry names it: for the film of the palette, 36.8 s of the whole screen, 1 572 784 bytes, half of the MP4 file. The entry of the palette has its film; the feed `news.xml` names it as an enclosure.
