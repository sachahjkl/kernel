title: The calls of the host go over QUIC
date: 2026-11-12
release: next
picture: docs/screenshots/remote.png
kind: Shown
guide: docs/QUIC.md

A person at the host can call a command of the running system with `kerneltool call`. These calls now go over QUIC: one stream for each call, up to 8 at one time. The host checks the public key of the program `remote`, which its window shows. The program accepts the address of the host only, and it proves that address before it runs a call. The earlier transport, with datagrams of its own, is removed.
