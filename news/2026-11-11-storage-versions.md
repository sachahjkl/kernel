title: Every program gets versions of its data
date: 2026-11-11
release: 0.67.0
picture: docs/screenshots/notes_versions.png
kind: Shown
guide: docs/ARCHITECTURE.md

The storage service keeps the state of an object before each change, with no save action and no code in the program. In `notes`, Up and Down step through the versions of the note, with the date of each, and Enter restores the version shown. The note before a restore stays a version. From the console or from the host, a person lists the versions of an object, reads one, compares two and restores one. In the main machine test, one commit of the note took 3778 us in the mean of 8. When a store reaches its limit of blocks, the service removes the oldest versions first.
