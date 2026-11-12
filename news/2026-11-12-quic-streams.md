title: A QUIC connection carries several streams
date: 2026-11-12
release: 0.80.0
picture: docs/screenshots/quic_echo.png
kind: Shown
guide: docs/QUIC.md

A QUIC connection of the system now carries several streams at one time. The caller gives a table of stream records, and each stream has its own limit of bytes. The server keeps a table of 1024 addresses and gives each address a budget of new connections. An independent read found that a reset stated a wrong count of bytes sent. This is corrected, with a test.
