title: An HTTP server in the system answers the host
date: 2026-11-11
release: 0.52.0
picture: docs/screenshots/server_real.png
kind: Shown
guide: docs/NETWORK.md

The program `server` is an HTTP/1.1 server. Its TCP is a library in the program, since the release 0.48.0. It keeps connections open, answers pipelined requests in order, and answers `HEAD`. Its pages are in its private store, and `server.put` and `server.remove` change them from the console. The machine test fetches its pages with the TCP of the host, through QEMU user networking, a stack that this project did not write. In the machine test of the release, with a new connection for each request, `server` answered 239 to 250 requests in one second, and `GET /hello` from the program `fetch` took 2.7 ms.
