# QUIC

Status: the design of QUIC version 1 in this system, its first three layers (packet protection, TLS 1.3, the transport of one connection), and the fourth (a server of several connections over a listen grant of UDP, `quic_echo`), written on 2026-11-11 (branch `work/tcp`). The owner has not reviewed it. The terms are in `GLOSSARY.md`, section "QUIC".

QUIC (RFC 9000) carries the streams of a connection over UDP, and protects each packet with keys that a TLS 1.3 handshake gives (RFC 9001). The purpose here: the service `remote` gets an authentication (a host program that sends UDP to its port acts for the person today), and `server` gets a second transport.

## 1. Where QUIC runs

| Part | Where | Why |
|---|---|---|
| The datagrams | An endpoint of the network service, as for UDP today. A server needs datagrams from any remote on one port: a listen grant of UDP, with admitted remotes, as for TCP (section 6) | The service multiplexes the one pair of queues of the device (the note of property 5 in `PROPERTIES.md`) |
| QUIC: packets, keys, streams, loss, congestion | `support/quic`, a library in the program that holds the connection | QUIC is a library in the program; its state is memory of the program |
| TLS 1.3 | `support/quic` too: QUIC carries the handshake in CRYPTO frames, with no record layer | One library for one connection |
| The primitives | The module `cryptography`, loaded in the program through its import slots | Proven code, one module, named by its hash (`docs/CRYPTOGRAPHY.md`) |
| The keys | The memory of the program that holds the connection, and nowhere else | A key never crosses a ring: the module runs in the program |

**No kernel change is needed.** QUIC uses the operations that UDP uses today (rings, memory, waits). The changes are in the network service and its contract (a listen grant of UDP, section 6), not in the kernel.

## 2. The form of the library

The same form as `support/tcp`:
- pure code over memory of the caller, with no allocation and no kernel call;
- an error is an `errors.Error_Record`;
- the kernel tool runs the same code on the host.

**The seam to the module.** `quic.Cryptography` is a record of the procedures of the module `cryptography` that QUIC calls. A program fills it from its import slots: each call is a direct call of an export. The host tests fill it with the procedures of the module package. When the module contract describes a table as a parameter (`work/tables`), a batch export (seal or open a table of packets in one call) takes the place of a procedure here, and nowhere else.

**One private copy of each datagram.** A datagram comes into the region of the endpoint, which the network service writes. `quic.datagram_take` copies it once into private memory of the program. Each later step works on that copy only:
- the reading of the header;
- the removal of header protection;
- the open, in place.

So no byte is checked in one place and used from another, and the result of each export of the module is private memory, as section 6 of `docs/CRYPTOGRAPHY.md` asks.

## 3. Packet protection (the first layer, built)

`support/quic`, files `integers.odin`, `keys.odin`, `packets.odin`:

- **Variable-length integers** (RFC 9000, section 16): `variable_length_integer_read`, `_write`, `_size`. A read never goes past the bytes.
- **Packet numbers** (RFC 9000, section 17.1 and appendix A): `packet_number_encoded_size`, `packet_number_decode`.
- **Keys** (RFC 9001, section 5):
  - `hkdf_label_write` and `hkdf_expand_label`: TLS 1.3 HKDF-Expand-Label with SHA-256 and an empty context.
  - `initial_secrets` and `initial_keys`: from the Destination Connection ID of the first Initial packet of the client, with the salt of version 1.
  - `packet_keys_from_secret`: the labels "quic key", "quic iv", "quic hp".
- **Cipher suites**:
  - AES-128-GCM protects each Initial packet, as the RFC asks.
  - ChaCha20-Poly1305 is the suite that this system prefers after the handshake: its portable code is 4.6 times faster than the portable AES here.
- **Header protection** (RFC 9001, section 5.4): the AES mask and the ChaCha20 mask are two new exports of the module (`header_protection_mask_with_aes_128`, `header_protection_mask_with_chacha20`). The library applies the mask to the first byte (4 bits of a long header, 5 of a short one) and to the packet number.
- **The reading of a header as hostile input** (`header_read`). Each length is checked before a byte is read. These give false and an error record, with the offset of the field:
  - a header that does not fit;
  - a connection identifier over 20 bytes;
  - a token or a Length past the end of the datagram;
  - a fixed bit of 0;
  - a packet too short for the sample of header protection.

  - a Retry with an empty token (RFC 9000, section 17.2.5.2: a client discards it).

  A long header of another version is read up to its connection identifiers (`Unknown_Version`), for a later Version Negotiation answer. A connection identifier over 20 bytes is refused for every version, though RFC 8999 allows 255 bytes outside version 1: this library does not answer such a header. The `end` of a packet is where the next packet of the datagram starts (coalesced packets).
- **Seal and open**:
  - the nonce is the iv with the packet number in its last 8 bytes;
  - the additional data is the header without protection;
  - the open is in place, in the private copy.

  The open has two steps, so that the caller chooses the keys from the key phase:
  1. `header_protection_remove` uses the header protection key only (it does not change at a key update, RFC 9001 section 6.1). It gives the first byte, the packet number and the key phase (`Unprotected_Header`).
  2. `packet_payload_open` opens the frames with the keys that the caller chose.

  `packet_open` makes the two steps with one set of keys: for a long header, which has no key phase.

  `packet_seal` writes the packet number itself, truncated to the length in the first byte. For a long header, it reads the header as the peer will, and refuses a Length that does not end the packet after the tag (`Bad_Value`): the peer could not open such a packet, and the loss would be silent.

  Failures:
  - A tag that does not verify gives `Not_Authentic`. The frames are erased (the module erases what it wrote), so the packet cannot be opened again from this copy, with any key.
  - Reserved bits that are not 0 after the open give `Bad_Value`: a PROTOCOL_VIOLATION in RFC 9000, section 17.2. They are checked after the open only, so a packet that is not authentic cannot close a connection.
- **Retry** (RFC 9001, section 5.8): `retry_integrity_tag` and `retry_integrity_check`, with the fixed key and nonce of version 1. The Retry Pseudo-Packet is the additional data of AES-128-GCM; the module takes 2048 bytes of additional data, so a Retry of 2043 bytes (with an original Destination Connection ID of 20 bytes), and an Initial packet with the longest token that a datagram holds, are taken.
- **The duties of the caller** (RFC 9000, sections 7.2, 14.1 and 17.2.2). The transport (section 5) does them; a program that uses this layer alone must do them too:
  - a server drops a client Initial in a datagram of less than 1200 bytes;
  - a server drops a client Initial whose Destination Connection ID has less than 8 bytes;
  - a client drops a server Initial that holds a token.
- **Limits**:
  - A datagram has 2048 bytes at most: a place of the region of an endpoint.
  - The header of a packet, with its token, has 2048 bytes at most: the additional data of the module, and a datagram.

**Tests** (`support/quic/packet_protection_test.odin`, host):
- RFC 9001 appendix A:
  - A.1: the labels, the initial secret, the secrets and keys of both sides.
  - A.2: the client Initial, sealed byte for byte and opened.
  - A.3: the server Initial, the same.
  - A.4: the Retry integrity tag, and each changed byte refused.
  - A.5: the ChaCha20-Poly1305 keys, nonce and short header packet.
  - The three masks.
- RFC 9000 appendix A: the variable-length integers, and the size and the decoding of packet numbers.
- Hostile datagrams:
  - each packet of the RFC cut at each length (none opens);
  - a Length, a token length and a connection identifier length that lie;
  - a fixed bit of 0;
  - a packet too short for the sample;
  - two bits of each byte of each packet changed (none opens);
  - 50 000 random datagrams for the AES Initial keys and 50 000 for ChaCha20 keys, a third with a long header of version 1, a third with a short header, one in five with a sample that starts with `ff ff ff ff` (none traps, none opens);
  - the ChaCha20 mask at the counter `ff ff ff ff` (the last block of the stream, which the sender chooses), against a value of an independent implementation;
  - two packets in one datagram (an Initial and a Handshake packet), and a second packet whose Length lies;
  - authentic packets with reserved bits set (`Bad_Value` after the open);
  - the seal that writes the packet number, and refuses a Length that is one byte short or long;
  - the removal of header protection, then an open with the keys of another phase (the frames are erased);
  - a Retry with an empty token, version 0, an unknown version, a connection identifier of 21 bytes for each;
  - packet numbers near 2^62;
  - an Initial packet of 2048 bytes with a token of 2008 bytes.

The values of appendix A were copied from the text of the RFC by a script that is not in the repository; none was typed by hand.

## 4. TLS 1.3 for QUIC (the second layer, built)

`support/quic/tls_key_schedule.odin` and `tls_handshake.odin`: both sides of the handshake as one state machine over bytes in memory of the caller, with no allocation. QUIC carries the messages in CRYPTO frames at their encryption level; there is no record layer (RFC 9001, section 4).

**What it does, and nothing more:**
- the group X25519 only, the signature Ed25519 only;
- TLS_CHACHA20_POLY1305_SHA256 first, TLS_AES_128_GCM_SHA256 also (the client offers both, the server takes ChaCha20-Poly1305 when it is offered);
- one application protocol (ALPN, which RFC 9001 section 8.1 makes required);
- the `quic_transport_parameters` extension of each side, carried as bytes, checked for its form (each parameter an identifier, a length and its bytes), kept for the transport;
- no session resumption, no 0-RTT, no HelloRetryRequest (the client sends its one key share; a HelloRetryRequest gives handshake_failure), no client certificate, no KeyUpdate (QUIC forbids it).

**How a peer is known: a raw public key, pinned by the caller** (RFC 7250).
- The client offers `server_certificate_type` with the one type RawPublicKey. The server answers with that type in EncryptedExtensions; its Certificate holds one entry, the SubjectPublicKeyInfo of its Ed25519 key: 12 fixed bytes (RFC 8410) and the 32 bytes of the key. No other DER is read, and no X.509 certificate is read.
- The client compares the key with `Tls_Configuration.server_public_key`, the key that its caller pinned. Another key gives bad_certificate. Then CertificateVerify proves that the server holds the private key of that key, over the transcript (RFC 8446, section 4.4.3).
- So there is no certificate authority, no name and no date: a client trusts one key, given by its caller. For `remote`, the root service gives the key as a grant (the next layers).

**Who holds the private key.** The server program holds its Ed25519 private key in `Tls_Configuration.server_private_key`, in its own memory; the module `cryptography` runs in the same program, so the key never crosses a ring. The handshake erases its copy, its X25519 private key and its secrets when it fails (`tls_handshake_erase_secrets`); the X25519 private key is erased as soon as the shared secret is made.

**Randomness.** The client random, the server random and each X25519 private key come from the generator of the program through `random.fill_for_a_key`, with the least seed strength of the configuration: QUIC asks for `processor` at least (`docs/RANDOMNESS.md`). `tls_start` refuses a configuration whose least strength is under `processor` (a field left at its zero value would accept a weak seed), and a client whose pinned key is 32 zero bytes (no key was pinned).

**Hostile input.** Each message of the peer:
- has each length checked before a byte is read (`Reader`);
- may come in parts (the side waits for the rest), but over 4096 bytes is refused;
- goes into the transcript, which holds 8192 bytes: a ClientHello of up to 4092 bytes (a peer with large key shares and padding) and the flight of the server. A handshake costs about 33 KiB;
- must come at the level of the keys in use: bytes of a level left when the next keys take its place, or bytes of an earlier level that come later, fail the handshake, and QUIC closes with PROTOCOL_VIOLATION (RFC 9001, section 4.1.3);
- must have the type that the state waits for, at its level: else unexpected_message;
- may hold an extension that the side does not know: it is skipped in a ClientHello, and refused with unsupported_extension where the side did not offer it (ServerHello, EncryptedExtensions);
- may not hold one extension type two times (illegal_parameter);
- gives, at a failure, the alert of TLS in `Tls_Handshake.alert` (QUIC sends it as the error code 0x100 + alert) and an error record whose `found` field is the alert.

**Keys for QUIC.** `tls_packet_keys(handshake, level, sending, keys, error)` gives the packet keys of the Handshake or the Application level, from the traffic secrets, through `packet_keys_from_secret`.

**Tests** (`support/quic/tls_handshake_test.odin`, host):
- The key schedule against the trace "Simple 1-RTT Handshake" of RFC 8448, section 3:
  - the X25519 exchange;
  - the hashes of the transcript after the two Hello messages and after the Finished of the server (from the messages of the trace: its Certificate is RSA, which this handshake does not read, but its bytes go into the hash);
  - the early, handshake and master secrets, the two derived secrets, the four traffic secrets;
  - an HkdfLabel with a context;
  - the two finished keys and the two Finished values.
- A whole handshake of a client against a server in memory: both connected with ChaCha20-Poly1305, the same keys in each direction, the transport parameters of the other side, the X25519 private keys erased.
- The refusals: a server key that is not the pinned key (bad_certificate), a protocol that the server does not speak (no_application_protocol), a weak seed (Seed_Too_Weak, nothing sent).
- Hostile messages:
  - each message cut at each length, with its length field set to the cut (the side fails) and left as it was (the side waits);
  - one bit of each byte of each message changed (the two sides never both connect);
  - each server message in the place of another, a message at a level where it does not go (unexpected_message);
  - 20 000 random messages (none traps, none connects a side).

The values of RFC 8448, RFC 8446 (the Random of a HelloRetryRequest) and RFC 8410 (the prefix of an Ed25519 SubjectPublicKeyInfo) were copied from the text of the RFCs by a script that is not in the repository, with the size of each one checked. The two byte arrays in `tls_handshake.odin` were written from that output, and a test compares them with it.

## 5. The transport of one connection (the third layer, built)

`support/quic`, files `connection.odin`, `connection_receive.odin`, `connection_send.odin`, `recovery.odin`, `frames.odin`, `transport_parameters.odin`, `ranges.odin`. One `Connection` record in memory of the caller holds all of the state: no allocation, no kernel call. It has about 214 KiB, most of it the two stream buffers of 64 KiB.

**Where a `Connection` record lives.** Never on a stack: the main thread of a program has 256 KiB of stack, and a record there leaves too little room for the frames of the module `cryptography` and the 16 KiB that it erases below them. A record goes in the global memory of the program or in a mapping that the program owns. No check enforces this: on the host the heap and the stacks of threads are both mappings, so an address test would refuse good records, and a program of the system has no call that gives the bounds of its stack.

**The calls of the caller:**
- `connection_start_client`, `connection_start_server`: a server starts its handshake at the first Initial packet of the client.
- `connection_datagram_receive(connection, datagram, now, error)`: each datagram of the peer. A packet that cannot be read or opened is dropped, with an error record, and changes nothing.
- `connection_datagram_send(connection, buffer, now)`: the next datagram, or 0.
- `connection_deadline(connection)` and `connection_time_passes(connection, now)`: the timers. Time is a count of microseconds that the caller gives; the tests give a fake clock.
- `stream_write`, `stream_read`: the one stream.
- `connection_close(connection, code, now)`: a close of the application.

**What it does:**
- **The three packet number spaces**, each with its keys, its packet numbers, its ACK ranges and its packets in flight. The Initial keys go when the client sends its first Handshake packet and when the server opens one; the Handshake keys go when the handshake is confirmed (RFC 9001, section 4.9).
- **The handshake**: the bytes of TLS go in CRYPTO frames at their level, 4096 bytes at most for each level and direction. The keys of each level are installed when TLS gives them; the secrets of TLS are erased once the 1-RTT keys are installed. A failure of TLS closes the connection with the code 0x100 + alert. The 4096 bytes of the 1-RTT level hold every NewSessionTicket of the life of a connection: a server that sends more gives CRYPTO_BUFFER_EXCEEDED. The servers of this system send none.
- **A server takes a client only with an authentic Initial**: the keys of the first Initial come from its Destination Connection ID into local records, and the record of the connection takes that identifier and those keys only when the packet opens. Anyone can make an authentic Initial (its keys come from a public value), so a handshake that does not complete within 10 s (`HANDSHAKE_TIME_LIMIT`) ends the record, whatever the idle timeout; a client has the same limit. A listening program keeps one record for each Destination Connection ID of a client, with a limit on the count of records (the server of several connections, section 6).
- **Transport parameters**: each side sends its limits and its connection identifiers. The values of the peer are checked (RFC 9000, section 18.2): a repeated parameter, a value out of its range, a parameter that only a server sends, or an identifier that is not the one that the packets carried, gives TRANSPORT_PARAMETER_ERROR.
- **Acknowledgements**: an ACK frame of up to 16 ranges. In the Initial and Handshake spaces it goes at once; in the 1-RTT space after 2 ack-eliciting packets or 25 ms.
- **Loss detection** (RFC 9002, section 6):
  - a packet is lost when a packet 3 numbers later is acknowledged, or when it is older than 9/8 of the round-trip time;
  - the probe timeout sends one or two probes, with the data of the oldest packets in flight or a PING, and doubles at each timeout;
  - a client with nothing in flight probes before the server validated its address, so that a server bound by its limit can send again.
- **The data of a lost packet goes again**: the CRYPTO and STREAM ranges, HANDSHAKE_DONE, MAX_DATA, MAX_STREAM_DATA and RESET_STREAM (with their values of now). A PATH_RESPONSE does not.
- **A fixed congestion window** of 12 000 bytes (the initial window of RFC 9002, section 7.2). Probes go past it.
- **Flow control**: 64 KiB for the stream and for the connection, moved forward when the application read half of it. Data past the limit is FLOW_CONTROL_ERROR.
- **One bidirectional stream**, stream 0, which the client opens with its first write. A server allows one bidirectional stream of the client, a client none of the server; unidirectional streams are not allowed.
- **The idle timeout**: the smaller of the two values, 3 probe timeouts at least. The connection ends with no packet.
- **The anti-amplification limit**: before a Handshake packet of the client came, a server sends at most 3 times the bytes that it received, and its timer stops when it cannot send. A server counts only the datagrams that it processed: stricter than RFC 9000 section 8.1, and safe; such a server can wait for one more datagram before it sends.
- **A range set with no place.** The sets of received bytes, of bytes to send again and of acknowledged bytes have 32 ranges each. A packet of the peer whose data has no place is not recorded and not acknowledged, so the peer declares it lost and sends the data again (its other frames have the same effect when they come again). A sent packet whose data has no place stays in flight, and loss detection tries again.
- **Packet numbers that were forgotten**: the set of received packet numbers keeps 32 ranges. When it drops its lowest range, the numbers below the end of that range are refused from then on, before the open, so that no packet is processed two times (RFC 9000, section 12.3).
- **Times that cannot wrap**: the sums and products of times saturate at the largest value, the ack delay of the peer is at most its max_ack_delay in each state, and the round-trip sample is adjusted with a subtraction that cannot wrap. A peer cannot move a deadline into the past.
- **Datagrams of 1200 bytes**: a datagram with an Initial packet of the client, or an ack-eliciting Initial packet of the server, is padded to 1200 bytes. A server drops a client Initial in a smaller datagram, or with a Destination Connection ID under 8 bytes; a client drops a server Initial with a token.
- **The close**: a side that closes sends CONNECTION_CLOSE and answers each later datagram with it, for 3 probe timeouts (closing). A side that receives it sends nothing for 3 probe timeouts (draining). An application close before the 1-RTT keys goes as APPLICATION_ERROR, with no code of the application.

**The frames, each read as hostile input:** each field is read with its length checked first. A frame that is cut, a length past the packet, an end past 2^62 - 1, a count of streams over 2^60 or a type that does not exist is FRAME_ENCODING_ERROR. A type that is not in its shortest form, or a frame at a level where it may not go (RFC 9000, section 12.4), is PROTOCOL_VIOLATION.

| Frame | What this layer does |
|---|---|
| PADDING, PING | Read |
| ACK, ACK with ECN counts | Acted on; a number that this side never sent is PROTOCOL_VIOLATION; the ECN counts are read and not used; 64 ranges at most are acted on |
| CRYPTO | Acted on |
| STREAM | Acted on for stream 0; another stream is STREAM_LIMIT_ERROR or STREAM_STATE_ERROR; a final size that changes is FINAL_SIZE_ERROR |
| MAX_DATA, MAX_STREAM_DATA, MAX_STREAMS | Acted on (MAX_STREAMS is kept: this side opens one stream) |
| CONNECTION_CLOSE | Acted on: the draining state |
| HANDSHAKE_DONE | Acted on by a client; to a server, PROTOCOL_VIOLATION |
| RESET_STREAM | Minimal: the stream gives no more data to the application |
| STOP_SENDING | Minimal: this side answers with RESET_STREAM and the same code, and sends no more data |
| NEW_CONNECTION_ID | Minimal: read for its form and not used (no migration). A Retire Prior To above 0 closes the connection with PROTOCOL_VIOLATION: this layer has no other identifier of the peer. A real peer seldom sends it, but it may; this is a known gap |
| RETIRE_CONNECTION_ID | Minimal: this side gave no identifier past the one of the handshake: a number above 0 is PROTOCOL_VIOLATION |
| PATH_CHALLENGE | Answered with PATH_RESPONSE |
| PATH_RESPONSE, DATA_BLOCKED, STREAM_DATA_BLOCKED, STREAMS_BLOCKED | Read and not used |
| NEW_TOKEN | A client reads it and keeps no token; to a server, PROTOCOL_VIOLATION |

**What this layer does not do yet:**
- NewReno: the congestion window does not grow and does not shrink after a loss; there is no persistent congestion.
- Pacing, ECN, and a path MTU larger than 1200 bytes.
- More than one stream, and unidirectional streams.
- Version Negotiation and the stateless reset: a connection drops a datagram of these kinds (the server of section 6 answers another version, and a client takes one Retry: section 6).
- A key update: a 1-RTT packet with the next key phase is dropped.
- A packet number shorter than 4 bytes on the wire.
- Packets of a level whose keys are not ready are dropped, not kept: the peer sends them again.
- A STREAM frame of the peer may write over bytes that came and were not read yet, with other bytes: RFC 9000 allows PROTOCOL_VIOLATION there, and this layer takes the new bytes. Only the authenticated peer can do it, and it can send any bytes at a new offset anyway.

**Tests** (`support/quic/transport_test.odin`, host): two connections in memory, joined by a channel that the test controls (loss, reorder by delay, duplicates, a delay of 10 ms one way), with a fake clock and fixed seeds:
- a handshake: both connected with ChaCha20-Poly1305, the client confirmed, the Initial and Handshake keys dropped, the parameters applied;
- an echo of 5000 bytes with no loss;
- **1 MiB each way** (the server writes back each byte that it reads) with 5 % of the datagrams lost, 5 % delayed out of order and 1 % duplicated;
- a handshake whose first datagram of each side is lost;
- the anti-amplification limit: a server that never hears the client again sends at most 3 times what it received, then its timer stops;
- the idle timeout of both sides, and a close of the application with its code;
- **hostile frames**:
  - each frame type whole, and cut at each length (FRAME_ENCODING_ERROR);
  - lengths near 2^62, an ACK of a packet never sent, STREAM data one byte past the window, streams that may not be, final sizes that change, a frame at the wrong level, each with its error code;
  - **50 000 random packets that pass the AEAD** (sealed with the 1-RTT keys of the client of the test) and carry random frames, to a connected server that answers each one: none may trap;
- the corrections of the third read, each with a test that failed before it:
  - STREAM data in 40 islands: the 8 past the 32nd are not acknowledged, and once the holes and those 8 come, the 8000 bytes are read once, in order; the same for CRYPTO data;
  - a sent packet whose data has no place stays in flight;
  - a random datagram shaped as an Initial does not take the server, and the real client connects after it;
  - an authentic Initial alone ends at the handshake deadline, with no idle timeout;
  - a replayed packet whose number was forgotten is refused;
  - the round-trip time, the probe timeout and the idle deadline with values near 2^64;
  - a least seed strength left at zero, and a client with no pinned key, are refused;
  - a ClientHello of 3900 bytes is taken; bytes left at the Initial level after the ServerHello fail the handshake.

## 6. QUIC on the network (the fourth layer, built; Retry and the budgets written on 2026-11-11, not run yet)

**Where it runs.** QUIC runs in the program, as TCP does in `server` and `fetch`: `support/quic` over a datagram endpoint of the network service. The network service sees UDP datagrams; it reads no QUIC header and keeps no QUIC state.

**What the datagram contract lacked, and what changed.** The contract had a listen grant for TCP only: a UDP endpoint named one remote, and the network service dropped each datagram of another remote. A QUIC server needs datagrams from any client on one port. So the listen grant now has a UDP form (`contract/datagram`, `programs/network`), with the rules of the TCP form:

| Rule | TCP listen grant | UDP listen grant |
|---|---|---|
| The port | One local TCP port that the root service names | One local UDP port that the root service names |
| A new remote is admitted on | A SYN (no ACK, no RST) | A datagram of 1200 bytes at least (`LISTEN_FIRST_LEAST`): the size of the first datagram of a QUIC client (RFC 9000, section 14.1) |
| And only | From an address that can answer, when a Receive waits | The same |
| The table | 64 admitted remotes, each with the time of its last segment in or out | The same table, the same code (`network.Admitted`) |
| When it is full | The oldest place with no traffic for 120 s serves again; else the new remote is dropped and counted (`Full`) | The same |
| A Send | Only to an admitted remote | Only to an admitted remote, and at most 3 times the bytes that came from it until the program validates it (`Validate`) |
| The time of a place | The last segment in or out | The last datagram that came from the remote: a send keeps no place |
| The program forgets a remote | `Release`, after the last segment | `Release`, after the last datagram, and at once for a datagram that the program refused |

**The limit of 3 times, in the network service.** The anti-amplification limit of QUIC (RFC 9000, section 8.1) was held only by `support/quic`, in the program. The network service now holds it too, without knowing QUIC: it counts the bytes that came from each admitted remote of a UDP listen grant and the bytes that went to it, and refuses a Send that would pass 3 times the bytes that came (status `Amplification`), until the program says with the command `Validate` that the remote proved its address. `quic_echo` validates a remote when its client came back with the token of a Retry. What a program gains by validating every remote: it lifts that limit for each address that sent it a datagram. It still reaches no address that sent it nothing, and a remote with no datagram for 120 s loses its place. So a program that validates every remote can send any volume, for 120 s after its last datagram, to an address whose name came in one forged datagram. The person revokes the grant of such a program. The listen grant of TCP has no such limit: a remote is admitted on a SYN, and the program answers a SYN with one segment.

The root service names the grant by the name of the program: `quic_echo` has the UDP port 4433 (`programs/root/network.odin`). The person reads it with `grants` and revokes it with `revoke`, as for the other endpoints.

**What the kernel does: nothing new.** No kernel code changed. The endpoint uses the rings, the memory objects and the waits that UDP uses today.

**The records.** A server has a table of `quic.Connection` records (connection records) in memory of the program: one mapping, never a stack (section 5). `quic_echo` has 16 records of about 214 KiB, and 16 echo buffers of 64 KiB: about 1112 pages (4.3 MiB) in one mapping, within its budget of 2048 pages (`programs/root/main.odin`).

**The server of several connections** (`support/quic/server.odin`, `quic.Server`). The caller gives each datagram with its remote address and port; the server chooses the record:

0. The server copies the datagram once into its own memory, and takes each decision on that copy; the record opens the same bytes.
1. A packet whose Destination Connection ID is the identifier of a record goes to that record. In an Initial, the identifier that gave the Initial keys of a record also names it. The same identifier from another remote is dropped: the server sends `disable_active_migration`, and a client does not move.
2. **Retry** (`support/quic/retry.odin`; RFC 9000, sections 8.1.2 and 17.2.5; RFC 9001, section 5.8). An Initial with an unknown identifier and no token gets a Retry packet, and the server keeps nothing: no record, no key, no open of the Initial. The Retry gives a token. Only a client that receives datagrams at its address can send its Initial again with that token, so a forged source address takes nothing.
3. An Initial with a token takes a free record only when its token opens for its remote and names the identifier that the Initial uses, and when the Initial itself opens on a second copy. The record is then validated: the client proved its address.
4. Then the limits. A datagram over a limit gets no answer.
5. A long header of another version, in 1200 bytes at least, gets one Version Negotiation packet that lists version 1.
6. Each datagram that the server keeps nothing of (a Retry, refused, not authentic, of no record) has its remote released at once, so that a flood does not fill the admitted remotes of the network service.
7. The work of datagrams of unknown identifiers has a budget in each second (below). A datagram over the budget is dropped before any cryptography. The datagrams of known records have no budget, and `quic_echo` gives them first in each pass (`server_datagram_is_known`), before the datagrams of unknown identifiers.

**The token of a Retry.** An AEAD value: ChaCha20-Poly1305 of the module `cryptography`, under a key of 32 bytes that the server makes at its start from its generator (`fill_for_a_key`, the least strength of the server). The nonce is a counter of the server, never used two times with one key. It seals:
- the original Destination Connection ID of the client, which the server sends back in the transport parameter `original_destination_connection_id`;
- the Source Connection ID of the Retry, which the client must use as its next Destination Connection ID, and which the server sends in `retry_source_connection_id`;
- the time of the Retry.

The additional data is the remote address and port. The token has 62 bytes. It does not open for another address or port, with a changed byte, after another start of the server (another key), or more than 10 s after the Retry (`RETRY_TOKEN_LIFETIME`: a client sends its Initial again one round trip after the Retry, and 10 s covers its probe timeouts).

**What a replay of a token gives.** Whoever sees a token on the path can send it again, but only from the address and port of that client, to the identifier that the Retry named, within 10 s. That gives the records of that one remote, within the limits of one remote address, for 10 s. An attacker on the path can do worse (drop the datagrams of the client). An attacker off the path gets nothing.

**The client side of Retry.** A client takes one Retry, before any Initial of the server: its Retry Integrity Tag must verify over the identifier that the client chose, its Source Connection ID must not be that identifier, its token must not be empty. A second Retry, or one with a bad tag, changes nothing. After a Retry, the client derives its Initial keys from the Source Connection ID of the Retry, sends its ClientHello again from its first byte in Initial packets that carry the token, and keeps counting its packet numbers. It checks that the server names its first identifier in `original_destination_connection_id` and the identifier of the Retry in `retry_source_connection_id`; a server that names a Retry when there was none, or none when there was one, fails the handshake.

| Limit | Value | Why |
|---|---|---|
| Records | 16 | 16 × 214 KiB and their echo fit the budget of the program |
| Connections of one remote address | 8 | Half the table: one host cannot take all of it |
| Connections in the handshake of one remote address | 2 | A host with authentic Initials of its own holds 2 records for 10 s at most |
| Connections in the handshake at once | 8 | Half the table stays for connections that completed |
| Handshake deadline | 10 s | Anyone can make an authentic Initial; the record is free again after this time |
| Version Negotiation packets | 16 in one second | Each one has 51 bytes at most for a datagram of 1200 bytes: far under the anti-amplification limit; the count bounds the work |
| Retries | 2000 in one second | Each costs 2 exports of the module (the seal of the token, the tag of the Retry), about 10 us; a Retry has 113 bytes at most, for 1200 received |
| Checks of a token | 2000 in one second | Each costs 1 export (the open of 37 bytes), about 3 us |
| Checks of an Initial with a valid token | 500 in one second | Each costs 11 exports (9 for the Initial keys, the mask, the open of about 1160 bytes), about 30 us; a client reaches this only after a Retry at its own address |
| Lifetime of a token | 10 s | The round trip of a Retry and the probe timeouts of a client |
| Idle timeout | 30 s | The value of `quic_echo` |
| The first datagram of a remote | 1200 bytes | The network service admits no remote with less |
| Admitted remotes | 64 | The table of the network service (unchanged) |

**The work that one forged datagram costs now** (the speeds of `docs/CRYPTOGRAPHY.md`, section 6, with the erasure of 16 KiB of stack after each export):
- Every datagram: one copy into the memory of the server (two in `quic_echo`, which first asks whether the datagram is known), and the reading of its header.
- An Initial with no token, within the budget: 8 random bytes from the generator of the program, and 2 exports (the token, about 1 us of ChaCha20-Poly1305; the Retry Integrity Tag, AES-128-GCM over about 100 bytes), then one Send of 113 bytes and one Release. About 10 us, by the measured speeds; not measured yet.
- An Initial with a token, within the budget: 1 export, the open of the token. A token that does not open stops there.
- An Initial whose token opens: the 11 exports of the open of the Initial. Only a client that received a Retry at its address reaches this.
- Over a budget: the copy and the header, then nothing.

Before this round, each forged Initial cost the 11 exports (about 30 us), with no budget. The worst second of work for new identifiers is now about 41 ms of one processor (2000 Retries, 2000 checks of a token, 500 checks of an Initial).

**What a flood can do after this round, and what it cannot.**
- It cannot take a record from a forged address: a record needs a token that came back to the address. It cannot make the server open an Initial without a valid token, or spend more than the budgets of each second on cryptography.
- It cannot make the server, or the network service, send more than 3 times what came from a remote that did not prove its address. A Retry (113 bytes at most) answers a datagram of 1200 bytes: a reflection to a forged address carries less than a tenth of what the attacker sent.
- It can fill the 96 places that `quic_echo` posts for datagrams, and the 64 admitted remotes of the network service, faster than the program empties them. Then the network service drops datagrams with no place, those of real connections too: the order of known datagrams first works only on the datagrams that reached the program. A flood that outruns one pass of the program is a limit of the device and of the network service (one pair of queues), not of QUIC.
- A host with a real address can take records within the limits of one address (2 in the handshake, 8 in all) for the handshake deadline or the idle timeout, from each address that it really has.
- An attacker on the path can replay a token (above), or drop datagrams.

**A NAT that changes the address or the port of a client ends its connection.** The server finds a record by its identifier and its remote, and sends `disable_active_migration`: a datagram with the identifier of a record from another address or port is dropped. RFC 9000, section 9, allows this. A client behind a NAT that gives it another port after a silence (often 30 s or more) loses its connection until the idle timeout. Later: validate the new path with PATH_CHALLENGE for a datagram that opens.

**What the closing state answers.** In the closing state a record answers the 1st, 2nd, 4th, 8th... datagram with its identifier, not each one (RFC 9000, section 10.2.1). These datagrams are not opened, so a third party that knows the identifier and forges the address of the client makes at most a few CONNECTION_CLOSE packets of about 50 bytes.

**A record and its generation.** Each time a record is taken it gets a new generation number; `quic_echo` ties its echo state to it, so a new client of a place never takes the echo state of the client before.

**What a client over a limit gets: nothing.** A CONNECTION_CLOSE would need an Initial packet built outside a record, for a client whose identity no one checked; an attacker that fills the table would learn when it is full. A real client tries again at its probe timeout, and ends at its own handshake deadline.

**Version negotiation: one packet, within a count.** RFC 9000, section 6.1, says a server SHOULD answer a version that it does not speak. The answer is small (51 bytes at most for 1200 received), and 16 in one second bound the work. A Version Negotiation packet of this server has no authentication; a client of this system speaks only version 1 and never needs one.

**The stateless reset: not done.** A server that restarts forgets its connections; their clients end at their idle timeout.


**The key of a server.** `quic_echo` makes an Ed25519 key at its start from its own generator (`random.fill_for_a_key`, the strength "processor" at least). The private key stays in the memory of the program: in the configuration of its `quic.Server`, which copies it into each handshake, and each handshake erases its copy. The public key goes on the log ("quic_echo: the public key of this server: " and 64 hexadecimal digits) and in the window; a client pins it. A new start makes a new key, which the client must pin again: a key that lasts needs a store of the program and a grant, a later step.

**A weak seed.** A seed weaker than "processor" makes no key (`Seed_Too_Weak`): `quic_echo` writes "the random seed of this program is weak: it makes no key of a server, and listens on nothing" on the log and in its window, and opens no endpoint. This is the rule of the owner (`docs/RANDOMNESS.md`): the program chooses what it accepts.

**The programs.**
- `programs/quic_echo`: the server. Each connection has one stream; each byte goes back, then the end of the stream after the end of the client. Its window shows its public key, its connections (remote, state, bytes in and out, smoothed round-trip time) and its counts (accepted, ended, not authentic, refused by a limit). It writes each new connection and each end on the log (50 lines in one second at most), and its counts once in a second when they change.
- The client: the peer of the tool on the host (`tools/kerneltool/peer_quic.odin`). It links `support/quic` and the module `cryptography` compiled for the host, and pins the key that the machine printed. It sends its datagrams as the gateway 10.0.2.2, through the network device of the machine, so the network service of the machine is on the path. A client inside the machine would need a second program with a client grant of UDP to the local address; the network service sends no datagram to its own address (no loopback), so this is not possible today.

**The tests.**
- On the host (`support/quic/server_test.odin`, `retry_test.odin`):
  - 8 clients at once from 8 addresses, each with an echo of 64 KiB; 8 clients of one address, which wait their turn; a client that vanishes after it came back with its token; a Version Negotiation packet, byte for byte, and its count in one second; a known identifier from another remote;
  - a flood of 1000 forged Initials from 1000 addresses and 15 authentic Initials from 3 addresses: 1015 Retries, no record, no open of an Initial; the real client connects in under 1 s;
  - the flood of the fourth independent read: 8 authentic Initials from 4 forged addresses every 10 s, and a real client that starts in the middle of it: no record is taken, and the real client connects in under 1 s;
  - the Retry packet of RFC 9001, appendix A.4, written byte for byte; a client through a Retry, with both identifiers checked in the transport parameters;
  - tokens: another address, another port, each byte changed, too old, a time to come, another key, too short; at the server, a token from another remote, to another identifier, too old, and the right one;
  - a client refuses a Retry with a bad tag, a Retry whose Source Connection ID is its own identifier, and a second Retry;
  - the budgets: 3000 Initials with no token in one second get 2000 Retries; 3000 with tokens that do not open cost 2000 checks;
  - the closing state answers 4 of 15 datagrams;
  - on the network service (`support/network/tables_test.odin`): the limit of 3 times for a remote that is not validated, the end of the limit when it is validated, and a place that a send does not keep.
- On the machine (`kerneltool test quic`, `tools/kerneltool/quic_scenario.odin`): 1 MiB each way; the same with 5 % lost, 10 % reordered and 10 % repeated; 8 clients at once; a client that pins another key (it refuses the server: bad_certificate); a flood of 1000 forged Initials from addresses of 198.18.0.0/15 and 8 authentic Initials from 4 forged addresses, at the pace of their answers. What must hold: no answer to a forged address is anything but a Retry (so no record answered one), at most one Retry for each Initial, never more than 3 times the 1200 bytes that one address sent, and the real client gets its echo; the count of Retries is reported, not required, because the network service may drop a datagram of a flood. Before this pace, the peer read one frame of the machine for 5 that it sent, and its own socket on the host dropped the Retries (445 of 1008 counted); a datagram of another version (one Version Negotiation packet), and a real client at the same time; a client that takes its Retry, sends its Initial with the token, and vanishes (the server ends its record at the handshake deadline). The machine of the weak seed starts `quic_echo` too (`random_scenario.odin`).

**A stack that this project did not write: written, not run yet** (`kerneltool test quic-real`, `tools/kerneltool/quic_real.odin`). OpenSSL has a QUIC client since 3.2, with raw public keys of a server (`openssl s_client -quic`, `-enable_server_rpk`); the nixpkgs of the flake has OpenSSL 3.6.5, now in the development shell. What the manual and the source of `apps/s_client.c` (tag openssl-3.6.0) say:
- `-quic` needs `-alpn`.
- `-enable_server_rpk` offers the server certificate types {raw public key, X.509}; this server accepts a list that has the raw public key.
- After the handshake, `s_client` prints "Server-to-client raw public key negotiated", then "Server raw public key" and the key (`EVP_PKEY_print_public`).
- `s_client` goes on after any check of the key (it is a test tool): the test compares the printed key with the key on the log of the machine. That is the pinning.
- With `-adv`, the line `{fin}` ends the stream.

The network device of the machine of `test quic-real` goes to the peer of the tool (`-netdev dgram`), as in `test quic`. `s_client` reaches `quic_echo` through the UDP relay of the peer (`tools/kerneltool/peer_relay.odin`):
- the relay has one UDP socket on the loopback of the host, at a port that the system chooses;
- a datagram of a client of the host becomes a frame from 10.0.2.2 to 10.0.2.15 port 4433, from a port that the relay gives that client (42000 + its place in a table of 16; a new client takes a free place, or the place whose last datagram is the oldest);
- a datagram of the machine to 10.0.2.2 at one of those ports goes back to its client from the socket of the relay;
- a datagram over 1472 bytes (the UDP data of a frame of 1500 bytes), from either side, is dropped and counted; the relay prints its counts when the peer stops.

The thread of the peer runs the relay. `peer_run` reads each frame of the machine that waits, and runs the ticks of the cases and of the relay when no frame waits, or after 1 ms of frames: the answers of the machine never wait in the socket of the peer behind the next sends. The socket of the relay does not block; each tick takes 64 datagrams at most. The test needs no network of the host but its loopback.

The machine starts `quic_echo`; the step Quic_Key reads its key; the step Openssl_Quic runs:
```
printf '%s\n{fin}\n' 'an echo through QUIC, from the OpenSSL of the host' | timeout 20 openssl s_client -quic -alpn kernel-remote -enable_server_rpk -groups X25519 -sigalgs ed25519 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -adv -connect 127.0.0.1:<port of the relay> 2>&1
```
The output must have "Server-to-client raw public key negotiated", the key of the log in the 64 hexadecimal digits after "pub:", and the line back. On a failure, the step prints:
- all that OpenSSL printed, with its error queue;
- the first 60 datagrams that the relay carried: the direction, the port, the length, and the first 160 bytes;
- the last counts of `quic_echo` (with the Sends that the network service refused, and the status of the last one);
- the last end of a connection that `quic_echo` logged: its cause, the error code and the frame type of the close, and the first 48 bytes of the reason phrase of the client (each byte that is not printable ASCII as "?");
- the output of a second attempt with `-msg -debug -state`.

**The first run (2026-11-11): OpenSSL never came back with the token.** `quic_echo` sent a Retry for each of its Initials (5 in 20 s); no Initial carried a token. What the source of OpenSSL 3.6.0 says, read after the run:
- its client of one connection uses a connection identifier of 0 bytes (`quic_impl.c`: the port of a client has `is_multi_conn` 0, so `rx_short_dcid_len` is 0 in `quic_port.c`). The Retry of `quic_echo` then has an empty Destination Connection ID. No test of this system had sent one: the client of this system always has 8 bytes. A host test now checks that Retry, byte for byte, with the tag computed by the rule of RFC 9001, section 5.8, for an original identifier of 8 and of 20 bytes;
- its port finds the connection by that empty identifier; its decoder takes a Retry with a zero-length Destination Connection ID; it checks the tag over its first identifier by the same rule (`quic_wire_pkt.c`), and takes one Retry before any encrypted packet (`quic_channel.c`).

So nothing in the source refuses the Retry of `quic_echo`.

**The second run (2026-11-11): the cause was QEMU user networking.** The capture had the Initial of OpenSSL (Source Connection ID of 0 bytes) and the Retry of `quic_echo` (93 bytes, its tag right by a computation outside this code, its UDP and IP checksums right); `quic_echo` refused no Send; OpenSSL with `-debug` received no datagram. libslirp drops each UDP datagram that the machine sends when the user network has `restrict=on` (`src/udp.c`, `udp_input`), before it looks for a forward; TCP answers pass, so the HTTP tests through `hostfwd` worked. `restrict=on` stays: the machine must not reach the network of the host for one test. The step now goes through the UDP relay of the peer, and the `hostfwd=udp` part is gone. The same run showed that the text `{fin}` in the format of `fmt` broke the command (a brace starts a field of the format); it is now an argument.

**A client with an empty identifier, after the Retry** (read of the server path, then a host test). Every packet that the server sends to that client has a Destination Connection ID of 0 bytes:
- a long header has 1 + 4 + 1 + 0 + 1 + 8 bytes before its token and Length, and a short header 1 + 0 bytes before its packet number. Both writers take the length of the identifier of the peer, so no size is fixed to 8;
- the sample of header protection is 4 bytes after the start of the packet number, whatever the identifier: a packet number of 4 bytes and a tag of 16 bytes always cover it;
- the client sends to the identifier of the record (8 bytes), and the server finds the record by that identifier and the remote; the empty Source Connection ID of each later long header must stay empty, and does;
- the transport parameters of the client name an empty `initial_source_connection_id`, which equals the empty Source Connection ID of its packets.

The host test `a_handshake_with_a_client_with_an_empty_identifier` (`support/quic/server_test.odin`) builds a real ClientHello with an empty `initial_source_connection_id`, sends it after the Retry in an Initial with an empty Source Connection ID and the token, and checks:
- the record stays in the handshake;
- the first datagram of the server has 1200 bytes, an Initial and a Handshake packet, each with an empty Destination Connection ID and the identifier of the record as its source;
- the Initial opens with the keys of the identifier of the Retry.

What the server sends to OpenSSL, against what its client requires (`quic_channel.c`, `ssl/statem`):
- the transport parameters: `original_destination_connection_id` (the first identifier of the client, before the Retry), `retry_source_connection_id`, and `initial_source_connection_id` (the identifier of the record, which is the Source Connection ID of the Initial of the server);
- EncryptedExtensions: ALPN, `server_certificate_type` with the one value 2, which a server sends only when the client offered it (this server requires that offer), and the transport parameters;
- Certificate: one entry, the 44 bytes of the SubjectPublicKeyInfo of the Ed25519 key; CertificateVerify with ed25519;
- HANDSHAKE_DONE in the first 1-RTT packet after the Finished of the client;
- an empty legacy session ID is required of the ClientHello: OpenSSL clears its middlebox compatibility mode for QUIC (`quic_tls.c`), so its ClientHello has one.

Where this code is stricter than RFC 9000 and RFC 9001, and why none of them refuses OpenSSL in this test:
- **A key update of the peer is not followed.** A 1-RTT packet with the next key phase is dropped (no close). RFC 9001, section 6 requires an endpoint to follow one. OpenSSL starts one by itself at half the limit of its AEAD: for ChaCha20-Poly1305 that is about 2^61 packets.
- **A server sends no HelloRetryRequest.** A ClientHello without a key share of X25519 fails with handshake_failure; RFC 8446 asks for a HelloRetryRequest. `-groups X25519` makes OpenSSL send that key share.
- **A NEW_CONNECTION_ID with Retire Prior To above 0 closes the connection** (PROTOCOL_VIOLATION): this side has no other identifier of the peer to move to. A client with an empty identifier sends no NEW_CONNECTION_ID (RFC 9000, section 19.15).
- **The server requires `server_certificate_type` with the raw public key, ed25519, X25519 and ALPN `kernel-remote`.** These are choices of this protocol, not of QUIC.
What is not stricter, read in the code: a ClientHello with GREASE values or extensions that this side does not know (skipped); PING and PADDING at each level; ACK and ACK_ECN with ranges and the delay exponent of the peer; NEW_TOKEN at a client (dropped); a coalesced datagram of Initial, Handshake and 1-RTT packets (each packet in order, with the keys that the packet before made ready); zero bytes after the last packet of a datagram (the rest is dropped); a packet with keys that this side does not have yet, or a 1-RTT packet before the server completed its handshake (dropped, the peer sends it again; never a close).

Two points that no run has settled, which the first run reports:
1. Whether `s_client` waits for the echo and the end of the stream of the server before it ends, when its input ends. The step gives it 20 s (`timeout 20`) and reads what it printed in that time.
2. The exact form of the printed key: "pub:", then the bytes in hexadecimal with colons, on indented lines, by `EVP_PKEY_print_public` of an Ed25519 key. The step reads the first 64 hexadecimal digits after "pub:", whatever separates them.

The part stays out of the whole test until a first run settles both.

## 7. `remote` over QUIC (designed, not built)

**Today.** The service `remote` has a datagram endpoint whose grant names the host (10.0.2.2, port `remote.HOST_PORT`), and the grant to act for the person. A call is one UDP datagram with a request header of 112 bytes (`contract/remote`) and its arguments; an answer comes in one or more datagrams. Nothing is encrypted and nothing is authenticated: whoever can send a datagram from the address and port of the host calls as the person.

**What changes.**
- `remote` becomes a QUIC server, as `quic_echo`: a listen grant of UDP in the place of its grant of the host, its key made at its start, its public key on its log and in its window.
- The host tool pins that key (the step Quic_Key), and connects through the peer, or through the UDP relay of the peer with a stack of the host.
- Each call rides one bidirectional stream of its own: the request (the header of 112 bytes and its arguments) then the end of the stream; the answer (its header, its result, its error record) then the end of the stream. The limit of one datagram for an answer, and the answers in parts, go away. This needs more than the one stream of the transport today: the next part of the transport.
- The tool sends a new call on a new stream; a lost datagram is the work of QUIC, not of the tool.

**What is protected, and what is not.**
- Protected: the host knows that it speaks to the machine whose key it pinned, and not to another one on the path. No one on the path reads a call or an answer, changes one, or plays one again.
- Not protected: the machine does not know who the client is. Any program that can send UDP to the port of `remote` can make a connection and call as the person, as today. QUIC adds nothing there.
- What would protect it: the host proves a key of its own (a client certificate of TLS, a raw public key too), and the root service gives that key to `remote` as a grant that the person reads and revokes. That is a principal of property 21, which is not built. Until then, the guard of the person stays the grant of `remote` and the closed network of the test.

## 8. The next layers (designed, not built)

1. **The transport, second part**:
   - NewReno congestion control, from the ideas and the tests of the Reno of `support/tcp`;
   - more streams (for `remote`), connection identifiers, the validation of a new path (NAT rebinding), the stateless reset.
2. **A stack that this project did not write**: the first run of `kerneltool test quic-real` (section 6).
3. **`remote` over QUIC** (section 7), then mutual authentication when principals exist.

## 9. What is not built, and will not be in version 1 of this library

- Connection migration.
- 0-RTT.
- Key update (the key phase bit is read before the open, `Unprotected_Header.key_phase`, so that it can come).
- ECN.
- The datagram extension (RFC 9221).
- HTTP/3.
- X.509 certificates, session resumption, HelloRetryRequest, the groups and signatures other than X25519 and Ed25519.
- AES-256-GCM and AES-128-CCM: the suites of TLS 1.3 that this library does not offer.
