type: Added

**QUIC packet protection**: the library `support/quic` reads QUIC version 1 packet headers as hostile input, derives the Initial keys of a connection, and seals and opens packets with header protection, with AES-128-GCM or ChaCha20-Poly1305 from the module `cryptography`; it gives the packets of RFC 9001 appendix A byte for byte.
