title: A module of cryptography for every program
date: 2026-11-11
release: 0.70.0
picture: docs/screenshots/cryptography_vectors.png
kind: Shown
guide: docs/CRYPTOGRAPHY.md

The module `cryptography` gives ChaCha20-Poly1305, AES-128-GCM, SHA-256, HMAC, HKDF, X25519 and Ed25519 to each program. Its code is taken from `core:crypto` of Odin, and `kerneltool cryptography-origin` proves that each taken file is its origin with the listed changes only. A tag or a signature that does not verify is an error, and the caller gets no byte of the text. On the machine, the program `cryptography_vectors` runs the vectors of the standards through the module: 7 of 7 pass. The seal of 1200 bytes with ChaCha20-Poly1305 takes 2.4 us, about 490 MB/s, in the mean of 100 calls at a host load of about 20.
