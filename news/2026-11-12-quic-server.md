title: A QUIC server answers on the network
date: 2026-11-12
release: 0.76.0
picture: none
kind: Shown
guide: docs/QUIC.md

The program `quic_echo` listens on the UDP port 4433 and writes back each stream that a client sends. QUIC is a library in the program. `quic_echo` makes its key at its start and shows its public key in its window: a client pins that key. `kerneltool test quic` runs a client of the host against it: 1 MiB each way, the same with loss, 8 clients, a wrong pinned key and a flood of 1000 forged packets. `kerneltool test quic-real` runs the QUIC client of OpenSSL 3.6.5, `openssl s_client -quic`, against `quic_echo`, and checks the echo and the pinned key. In the machine tests of the step, the first test made 19 checks and the second 9.
