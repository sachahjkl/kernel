# The test keys

`test_signing_key` and `test_signing_key.public` are the key pair of RFC 8032, section 7.1, TEST 1.

`test_firmware_signing_key.pem` and `test_firmware_signing_key.crt` are the test firmware signing key: an RSA-2048 key and its certificate, for Secure Boot. `kerneltool key test-firmware-new` wrote them once. Its private key is in this repository.

- **These are test keys.** Their private keys are published.
- A system that these keys sign is not trusted. The boot program, the boot display and the root service say so, and the file `<volume>.signed_by` beside each boot volume says so too.
- The build signs with these keys when the environment variable `SYSTEM_SIGNING_KEY` is not set.
- The signing key of a real machine is a file outside the repository: `kerneltool key new <folder>` writes one (`docs/TRUSTED_BOOT.md`, "The signing key").

The format of the two Ed25519 files: 64 hexadecimal digits, then an end of line. The firmware key files are PEM.
