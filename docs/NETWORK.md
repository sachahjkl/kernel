# The network: TCP as a library in the program

The first layer of the network is the base: the frame service, the network service, endpoints of datagrams. `GLOSSARY.md` defines the terms.

## The principles

- The network stack is a library in the program that uses the network (property 5).
- The note of property 5: the network service is on the data path for UDP; TCP and QUIC stay libraries in the program.
- The network has UDP, TCP and QUIC, and a server as a scenario.

## The parts

| Part | Where | What it does |
|---|---|---|
| TCP library | `support/tcp` | The state machine, the windows, the timers, the reassembly, the congestion control. Pure code over memory of the caller: no kernel operation, no allocation. The kernel tool uses the same package on the host |
| Network service | `programs/network` | Gives each program with the grant one endpoint. For a segment endpoint: it checks each segment against the grant, writes and checks the IPv4 header, checks the TCP checksum of a segment that arrives, and copies the segment one time. It keeps no state of a connection |
| Server | `programs/server` | A program with a listen grant on the TCP port 80. One thread serves all its connections from one connection table. It speaks a small HTTP/1.1 |
| Client | `programs/fetch` | A program with a segment grant of one remote. It fetches pages and measures |
| QUIC server | `programs/quic_echo` | A program with a listen grant of UDP on the port 4433: QUIC in the program (`docs/QUIC.md`, section 6) |
| Peer | `tools/kerneltool/peer.odin` | The gateway of the test machine. It is also a TCP client that the tool drives, with loss, reorder and duplicates that the tool chooses |

The kernel has no network code.

## The segment endpoint

A segment endpoint is an endpoint (`contract/datagram`) whose grant has the protocol TCP. The ring, the region, the commands and the error records are the ones of a datagram endpoint. Two things differ:

1. A Send names a whole segment in the region: the TCP header, its options and its data. The program writes the header and its checksum. A Receive gives a whole segment.
2. The grant names TCP ports, not UDP ports.

The library writes the segments directly in the places of the datagram region, so a segment is copied one time on its path: by the network service, between the region and the frame.

### The grant of a segment endpoint

The root service names the grant by the name of the program, as for UDP (`endpoint_of`). The person reads it with `grants` and revokes it with `revoke`. Two forms exist:

| Form | Local TCP ports | Remotes | Use |
|---|---|---|---|
| Client grant | A block of 64 ports that the network service chooses | One remote address and one remote TCP port | A program that connects to one server |
| Listen grant | One port that the root service names | Each remote that sent a segment to that port | A server |

A client grant has 64 local ports, because a closed connection stays in TIME-WAIT (below) and one local port serves one connection at a time to one remote. The program chooses a port of its block for each connection.

A listen grant is narrow in another way: the program answers, but it does not reach. The network service keeps one table of admitted remotes for each listen grant: an address and a TCP port that sent a SYN (no ACK, no RST) to the listen port, when a Receive of the endpoint waited for it, from an address that can answer (not 0, a broadcast or multicast address, or the local address). A segment of a remote that is not admitted does not reach the program. A segment to send goes out only to an admitted remote. So a program with a listen grant cannot open a connection to a machine that did not come to it, and cannot send a segment to it. The table has 64 places, each with the time of its last segment in or out. The program releases a remote (command `Release`) when its connection ended, after its last segment. When the table is full, the oldest place with no segment for more than 120 s serves again (twice the longest gap between two probes of a zero window in `support/tcp`, so that a live remote keeps its place); with none, a SYN from a new remote is dropped and counted in the problems of the endpoint (kind `Full`). A program that forgets a `Release` loses only places with no traffic.

This table is the one state of TCP in the network service: addresses and ports, with no sequence number and no window. It is the port table of the network service, with the remotes of a server.

### What the network service does for each segment

| Direction | Work | Why |
|---|---|---|
| Arrives | Checks the Ethernet, IPv4 and TCP headers, and the TCP checksum (`network.parse`) | The service reads the ports to choose the endpoint. A port that the wire damaged must not give a segment to another program. A refused segment is a problem row, as for UDP |
| Arrives | Finds the endpoint by the local port, checks the remote against the grant, admits a remote of a listen grant | Property 20, line 3 |
| Arrives | Copies the segment from the frame to the region | The device writes the frame region of the service, not the region of the program |
| Sent | Copies the segment from the region to the frame, then reads its ports from the copy | A port is checked in bytes that the program cannot change after the check |
| Sent | Checks the local port against the block or the listen port, and the remote against the grant or the table of admitted remotes | Property 20, lines 3 and 11 |
| Sent | Writes the IPv4 and Ethernet headers | It must check them anyway |
| Sent | Does not check the TCP checksum | A wrong checksum harms only the program that wrote it: the remote drops the segment |

The library computes the TCP checksum of each segment that it sends. It does not check the checksum of a segment that arrives through the network service: the service did. The function `tcp.checksum_valid` is for a caller that reads segments from another source.

### The note of property 5

The note says: "the network service stays on the data path for UDP; TCP and QUIC stay libraries in the program." For TCP the system does this:

- The protocol of TCP is in the program: the state of each connection, the sequence numbers, the windows, the timers, the retransmissions, the congestion control, the reassembly. The program can read and change each field of its connections.
- The network service is still on the data path for TCP, as for UDP, with the same work: one copy of each segment, the IPv4 header, a checksum, and the check of the grant. The reason is the same: the device of the first machine has one pair of queues, so one program reads each frame.

So the note is right about the place of the protocol, and not complete about the data path. A complete wording of the note:

> For UDP and TCP, the network service is on the data path: it reads each frame, checks it against the grant of an endpoint, writes the IPv4 header and copies each datagram or segment one time. The protocol of TCP (its connections, windows, timers and retransmissions) is a library in the program; the network service keeps only the ports and, for a listen grant, the remotes that came to it. QUIC will be a library over datagrams.

## The TCP library

### The form of the interface

The interface follows the rule of the system on data-oriented interfaces: many records in one call, in memory of the caller, never a list of pointers.

- A connection is one record of fixed size (`tcp.Connection`, 400 bytes). The caller gives the table of records and one block of memory for the buffers (property 14): each connection has a send buffer and a receive buffer at a place that its index gives. The library allocates nothing.
- One call does the work of a batch: `tcp.step` takes all the segments that arrived, the time, a table of places for the segments to send, and a table of events. It reads all the segments, runs the timers, and writes all the segments to send.
- An event is a record of fixed size: the index of a connection and a set of kinds (Opened, Accepted, Readable, Writable, Peer_Closed, Closed, Reset, Timed_Out, Refused). One record for each connection that has news, so a table with one place for each connection is enough.
- `tcp.step` gives the deadline of the next timer. The program waits on its rings with that deadline. No call blocks and no call has a callback.
- A call that fails gives an error record (`errors.Error_Record`, `MODULE_CONTRACT.md` section 8): a full table, a local port out of the block, a write on a connection that is not open.
- `connect`, `write`, `read`, `close` and `abort` change the record of one connection. The segments that follow come at the next `step`.

The program owns each field. It reads the state, the windows, the round trip estimate and the counts of each connection in its own memory, with no call; `server` draws them.

### What the library does

| Subject | Rule | Source |
|---|---|---|
| Open | Active and passive open; a simultaneous open | RFC 9293 3.5 |
| Sequence numbers | Modulo 2^32: `a` is before `b` when `i32(a - b) < 0` | RFC 9293 3.4 |
| Initial sequence number | `M + F(addresses, ports, secret)`: M counts 4 microseconds, F is the first 4 bytes of BLAKE3 of the secret and the four values | RFC 6528 |
| MSS option | Sent with each SYN (1460); a SYN with no option gives 536 | RFC 9293 3.7.1 |
| Receive window | The free room of the receive buffer, 65 535 at most. The right edge never moves left. It grows only by one MSS or half the buffer (avoidance of the silly window) | RFC 9293 3.8.6 |
| Send window | The segment that carries the newest window updates it (`SND.WL1`, `SND.WL2`) | RFC 9293 3.10.7.4 |
| Out of order | A segment after a hole goes to its place in the receive buffer; 8 ranges remember what arrived. An ACK goes at once | RFC 9293 3.10.7.4, RFC 5681 4.2 |
| Delayed ACK | One ACK for each second full segment, or after 40 ms | RFC 9293 3.8.6.3, RFC 5681 4.2 |
| Retransmission timer | SRTT and RTTVAR from the round trips, in microseconds; one segment timed at a time; no sample from a segment sent two times (Karn); the timer doubles after each timeout | RFC 6298 |
| Least RTO | 200 ms, not the 1 s of RFC 6298 2.4 | A choice of this library: the test link has round trips under 1 ms |
| Retries | 8 timeouts in a row end the connection (event Timed_Out, a RST) | RFC 9293 3.8.3 |
| Congestion control | Slow start, congestion avoidance, fast retransmit after 3 duplicate ACKs, fast recovery: Reno, with the partial ACK of NewReno. The congestion window stops at the largest window of the remote | RFC 5681, RFC 6582 |
| Limited Transmit | The first two duplicate ACKs each send one new segment | RFC 3042 |
| Duplicate ACKs | One ACK at once for each segment after a hole, also when a batch has several | RFC 5681 4.2 |
| Initial window | 3 segments of 1460 bytes | RFC 5681 3.1 |
| Zero window | A persist timer sends a probe (one byte before `SND.UNA`, with no data) until the window opens; it doubles as the retransmission timer does | RFC 9293 3.8.6.1 |
| Close | FIN in both directions: FIN-WAIT-1, FIN-WAIT-2, CLOSING, TIME-WAIT, CLOSE-WAIT, LAST-ACK. A FIN is taken only before the FIN of the remote. FIN-WAIT-2 ends after 20 s with a RST | RFC 9293 3.6 |
| Limits against a remote that does not answer | A passive open ends after 3 timeouts (15 s); 8 probes of a zero window with no answer end a connection; the ACKs that answer segments out of the window, and the challenge ACKs, are 10 in one second for each connection | RFC 5961 7, CVE-2016-5696 |
| TIME-WAIT | 10 s: 2 MSL with an MSL of 5 s | A choice of this library, see below |
| RST | Sent for a segment of no connection, for a SYN when the table is full, and by `abort`. A RST received ends the connection only if its sequence is exactly `RCV.NXT` | RFC 9293 3.10.7.1, RFC 5961 3 |
| Challenge ACK | A RST in the window but not at `RCV.NXT`, a SYN in a synchronized state, and an ACK after `SND.NXT` get an ACK and change nothing | RFC 5961 3, 4, 5 |

The MSL of RFC 9293 is 2 minutes. The library takes 5 s, as an MSL for one link: the TIME-WAIT of 10 s keeps a connection record for 10 s, not for 4 minutes. A program that serves many short connections needs records for them. The initial sequence numbers of RFC 6528 protect a new connection on the same ports.

### What it does not do

- Window scaling (RFC 7323): a window is 65 535 bytes at most. On a link with a round trip of 1 ms, that is 65 MB/s at most for one connection.
- Selective acknowledgments (SACK, RFC 2018), timestamps (RFC 7323), TCP Fast Open (RFC 7413), ECN (RFC 3168), urgent data (the field is read and ignored).
- The Nagle rule (RFC 9293 3.7.4): the library sends a small segment at once.
- Keepalive (RFC 9293 3.8.4).
- SYN cookies: a SYN takes a connection record. A table that is full ends its oldest record in TIME-WAIT and drops the SYN (the remote sends it again), else refuses the SYN with a RST. `Table.remote_limit` limits the open connections of one remote address.
- Path MTU discovery: the MSS is 1460 at most, for one frame of Ethernet.
- IPv6.
- A RST from the network service for a segment to a port with no endpoint: the service drops it and counts it.

### Randomness

RFC 6528 needs a secret that an attacker cannot guess. `server` and `fetch` take it from their random generator: each program has one, seeded by its starter from the seed that the root service gathers from the processor (`docs/RANDOMNESS.md`).

## The tests

### The library on the host

`odin test support/tcp` (in `kerneltool check`): two connection tables on one link that the test controls, with loss, reorder and duplicates; the sequence numbers at the wrap of 2^32; the round trip estimate and the timer of RFC 6298, with its doubling; a zero window that opens; a RST in the window and out of it; a SYN in a synchronized state.

### Against an independent implementation

The peer uses `support/tcp` too: it tests the library against itself. So the test also runs the system's TCP against a stack that this project did not write:

- A second network machine (`scenario_tcp_real`) has QEMU user networking (`-netdev user`). Its TCP is the one of libslirp, which comes from the TCP of 4.4BSD.
- `hostfwd` gives a port of the host loopback to the port 80 of the machine: the tool connects with `core:net` (the TCP of the host kernel to libslirp, then libslirp to the machine) and fetches the pages of `server`.
- `guestfwd` gives the address 10.0.2.100 port 80 of the network of the machine to a port that the tool listens on with `core:net`: `fetch` connects to it.

### With the controlled peer

A third network machine (`scenario_tcp`) has the peer of the tool on `-netdev dgram`, as `scenario_network`. The tool tells the peer to run one case at a time. The peer is a TCP client of `server`, and it changes the frames between its library and the machine with a generator of numbers that the case seeds, so each run makes the same changes: 5 % loss, a reorder, duplicates, a zero window of its receive buffer.

### What the tests found

- With batches of segments, a receiver must still send one duplicate ACK for each segment after a hole; with one ACK for a batch, no fast retransmit starts. The record counts the ACKs that it owes.
- `recover` of NewReno starts at the initial sequence number, not at 0: with 0 and an initial number above 2^31, no fast retransmit can start.
- Avoidance of the silly window can stop a sender with a small window and nothing in flight: the persist timer ends that case too.
- The congestion window stops at the largest window that the remote gave: without that limit, it grows with no end when the window of the remote limits the sender.
- 1 MiB with 5 % loss in each direction, on the host link of the tests: 5 to 10 s with Reno and NewReno, 1.5 to 2.7 s with Limited Transmit. The timeouts that remain come mostly from a retransmission that the link dropped too: SACK would remove more of them.
- libslirp acknowledges the FIN of a connection of `guestfwd` and does not send its own: the connection of `fetch` stays in FIN-WAIT-2.
- The measures (the machine test, QEMU with KVM, 4 processors, while other machine tests ran on the host; one run unless said):
  - Between the peer and `server`: 1 MiB from the server in 52.9 ms (19.8 MB/s), 1 MiB to the server at 20.2 MB/s.
  - With 5 % loss in each direction: 0.8 and 0.7 MB/s (48 segments sent again; 2.2 and 0.8 MB/s in another run). With 10 % reordered: 16.6 and 15.3 MB/s. With 10 % repeated: 16.1 and 14.9 MB/s. A zero window of 1.5 s: 4 probes.
  - The handshake seen by `server` (SYN to the ACK of its SYN, ACK): 61 to 135 us at least. `GET /` answered and acknowledged in 157 to 224 us.
  - With libslirp: the host fetched 1 MiB at 58.6 to 64.9 MB/s and sent 1 MiB at 57.6 to 61.0 MB/s (the clock of the host). `server` measured 92.9 to 98.4 MB/s out and 81.9 to 90.4 MB/s in.
  - `fetch` measured the handshake in 261 to 266 us, 1 MiB in at 105.3 to 140.7 MB/s, 1 MiB out at 11.4 to 11.9 MB/s, and `GET /hello` in 42.6 to 43.5 ms. The cause of that time is not known: the tool answers at once, so the time is in QEMU, libslirp or the wait of `fetch`.
  - With 16 connections, the answers were acknowledged 0.2 to 30 ms after their request, in the order of the connections: the peer runs one step for each frame.
  - The window of a connection is 32 KiB (the receive buffer), so one connection cannot exceed 32 KiB for each round trip. The test asserts no speed.

## The HTTP server

`server` is a simple HTTP/1.1 server (RFC 9110, RFC 9112), in the program as its TCP is: one thread, one table of 48 connections, one session of fixed size for each (its input of 8192 bytes, its answer), and no allocation.

- **The reading of a head** is `support/web.request_read`, for hostile input: a bound for each part, and a problem with its status (400, 405, 408, 413, 414, 431, 501, 505) for each rule that a head breaks.
- **Connections** stay open after an answer; "Connection: close" or HTTP/1.0 ends them. The bytes after a head stay in the input: they are the body, or the next request (pipelining). The answers go in the order of the requests.
- **What it serves** comes from its grants (property 20): its own counts (`/`, `/counts.json`), and the pages of its private store (property 9). A person changes the pages from the console through its exports (property 19): `server.put`, `server.remove`, `server.pages`, `server.served`. PUT and DELETE over HTTP stay off: without TLS the network is not authenticated.
- **Limits** against a client that makes no progress (without them, one host could keep each record): 10 s with no request, 408 for a head after 10 s (also a head that starts after an answer), no byte of a body in 10 s, a body and the bytes to send under 4096 bytes in one second over a period of 10 s (also after this server closed), 24 connections for each remote address.
- **The pages and their origin**: an answer of a page keeps the generation of its place, and a page that changes during it ends the connection with a RST. `put` and `remove` change the store first. The pages, `/` and `/counts.json` share one origin, and a page of the store runs script on it by design: the origin holds no secret, no cookie and no authority. Each answer says `X-Content-Type-Options: nosniff`.
- **No Date field**: the system has no clock of the day, and a server with no clock sends none (RFC 9110 6.6.1).
- **No TLS** over TCP: the TLS 1.3 of the system is the one of QUIC (`docs/QUIC.md`).

## The listen grant of UDP

Written for QUIC (`docs/QUIC.md`, section 6); `kerneltool test quic` and `kerneltool test quic-real` run it. A datagram endpoint can have a listen grant: one local UDP port that the root service names, and the remotes that came to it. Its rules are the ones of the listen grant of TCP above, with one change: a new remote is admitted on a datagram of 1200 bytes at least (`datagram.LISTEN_FIRST_LEAST`), where TCP admits it on a SYN. 1200 bytes is the least first datagram of a QUIC client (RFC 9000, section 14.1), so a stray small datagram of an unknown remote takes no place.

- The table of admitted remotes is the one of TCP (`network.Admitted`): 64 places, the oldest place with no traffic for 120 s serves again, `Release` forgets a remote.
- A UDP listen port is not a port PORT_FIRST + n of a client grant, and no other UDP listen grant has it.
- A Send goes only to an admitted remote. To a remote that the program did not validate, the network service sends at most 3 times the bytes that came from it (status `Amplification`, error kind `Over_Limit`); the command `Validate` lifts that limit for a remote that proved its address to the program (`docs/QUIC.md`, section 6, says what a program that validates every remote gains). A send does not keep a place alive: only a datagram of the remote does.
- `Resolve` and `Echo` are refused, as for each listen grant: the program answers, but it does not reach.
- The program releases a remote whose datagram it refused (a forged Initial, a datagram of no connection), so that a flood of many addresses does not hold the table.

The kernel has no code for it. The network service does for a datagram of a listen grant what it does for each datagram: it checks the headers and the checksum, finds the endpoint by the local port, checks the remote, and copies the datagram one time.

## QUIC: what it reuses, and what it needs

The design of QUIC is in `docs/QUIC.md`. QUIC runs over UDP (RFC 9000), so it is a library in the program over a datagram endpoint.

It reuses from TCP:

- The endpoint and its grant: a client grant of one remote, and the listen grant with its admitted remotes, for UDP in place of TCP. The table of admitted remotes is the one of the datagram endpoint, unchanged (the section above).
- The form of the interface: a table of connection records and buffers of the caller, one `step` for a batch of datagrams, a table of events, the deadline of the next timer.
- The ideas of loss and congestion: RFC 9002 takes the round trip estimate of RFC 6298, and its congestion control is NewReno. The code of the estimate and of the congestion window can be shared, as a package that both libraries import.
- The tests: the peer with loss, reorder and duplicates, and a machine with libslirp for UDP.

It needs more than TCP gives:

- TLS 1.3 (RFC 8446, RFC 9001): the key exchange (X25519), AEAD (AES-GCM or ChaCha20-Poly1305), HKDF. `docs/CRYPTOGRAPHY.md` has the primitives.
- Randomness: keys need a secret that an attacker cannot guess. `rdrand` in each program is not a service of the system (`docs/RANDOMNESS.md`).
- A check of the peer. A certificate needs a time of the day that an attacker cannot set: the date page has the date of the real-time clock, read one time, and the clock of the machine is not such a time. So QUIC uses raw public keys in place of certificates and a date (`docs/QUIC.md`, section 4).
