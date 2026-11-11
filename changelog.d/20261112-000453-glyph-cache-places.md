type: Security

**No program chooses where another program reads its glyph caches.** The program `settings` could write the address and the size of the glyph caches on the settings page, and so make each program that started later read and draw memory that `settings` controlled; the caches are now at fixed addresses with their sizes in the context that the root service writes, mapped read-only for every program. A program also no longer waits for ever on a settings page left in the middle of a change.
