type: Added

**A cryptography module**: the module `cryptography` gives ChaCha20-Poly1305, AES-128-GCM, SHA-256, HMAC, HKDF, X25519 and Ed25519 to each program, from the code of Odin's `core:crypto` with a check that proves each changed line; a tag or a signature that does not verify is an error with no byte given, and the program `cryptography_vectors` runs the published vectors through it and shows the speed of each primitive.
