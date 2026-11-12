title: The settings are kept across a stop
date: 2026-11-11
release: 0.74.0
picture: docs/screenshots/settings_kept.png
kind: Shown
guide: docs/FONTS.md

The font, the order of the color stripes, the pointer theme and the grid fit of the text are kept in the store of the program `settings`. They come back at the next boot. A loss of power during a change gives the old settings or the new ones, never a mix. The settings are one record of 48 bytes, and a change writes the record in one commit before it changes the settings page. Before this release, a stop of the machine lost the settings.
