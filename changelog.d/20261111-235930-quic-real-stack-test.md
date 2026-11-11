type: Added

**A test of QUIC against OpenSSL**: `kerneltool test quic-real` connects `openssl s_client -quic` of the host to `quic_echo` through QEMU user networking, pins the key that the machine printed, and checks the echo; the development shell has OpenSSL.
