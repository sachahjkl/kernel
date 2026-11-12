# The test signing key

`test_signing_key` and `test_signing_key.public` are the key pair of RFC 8032, section 7.1, TEST 1.

- **This is a test key.** Its private key is published in that document and in this repository.
- A system that this key signs is not trusted. The boot program, the boot display and the root service say so.
- The build signs with this key when the environment variable `SYSTEM_SIGNING_KEY` is not set.
- The signing key of a real machine is a file outside the repository: `kerneltool key new <folder>` writes one (`docs/TRUSTED_BOOT.md`, "The signing key").

The format of both files: 64 hexadecimal digits, then an end of line.
