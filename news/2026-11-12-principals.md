title: A named principal, unlocked by its passphrase
date: 2026-11-12
release: next
picture: none
kind: Shown
guide: docs/PRINCIPALS.md

The machine is principal 0, and the record of the root service holds the measure of the system when the boot program measured it. The console now creates a named principal with `principal_create("alice")`. Its passphrase is typed two times in the window of `unlock`, as dots, and never in the console. Argon2id with 19 MiB derives the key that seals its two secret keys. A wrong passphrase gives another key, and the seal does not open. A program that the desktop starts during the session belongs to the principal, and `notes` there has a store of its own, apart from the store of `notes` of the machine. `lock()` stops the programs of the session, and the note is there again after the unlock and after a restart. No TPM seals the key yet: the passphrase alone protects it.
