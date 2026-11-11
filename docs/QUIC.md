# QUIC

Status: the design of QUIC version 1 in this system, and its first layer, packet protection, written on 2026-11-11 (branch `work/tcp`). The owner has not reviewed it. The terms are in `GLOSSARY.md`, section "QUIC".

QUIC (RFC 9000) carries the streams of a connection over UDP, and protects each packet with keys that a TLS 1.3 handshake gives (RFC 9001). The purpose here: the service `remote` gets an authentication (a host program that sends UDP to its port acts for the person today), and `server` gets a second transport.

## 1. Where QUIC runs

| Part | Where | Why |
|---|---|---|
| The datagrams | An endpoint of the network service, as for UDP today. A server needs datagrams from any remote on one port: a listen grant for datagrams, with admitted remotes, as for TCP (section 4) | The service multiplexes the one pair of queues of the device (the note of property 5 in `PROPERTIES.md`) |
| QUIC: packets, keys, streams, loss, congestion | `support/quic`, a library in the program that holds the connection | QUIC is a library in the program; its state is memory of the program |
| TLS 1.3 | `support/quic` too (the next layer): QUIC carries the handshake in CRYPTO frames, with no record layer | One library for one connection |
| The primitives | The module `cryptography`, loaded in the program through its import slots | Proven code, one module, named by its hash (`docs/CRYPTOGRAPHY.md`) |
| The keys | The memory of the program that holds the connection, and nowhere else | A key never crosses a ring: the module runs in the program |

**No kernel change is needed.** QUIC uses the operations that UDP uses today (rings, memory, waits). The changes are in the network service and its contract (a listen grant for datagrams, section 4), not in the kernel.

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

  A long header of another version is read up to its connection identifiers (`Unknown_Version`), for a later Version Negotiation answer. The `end` of a packet is where the next packet of the datagram starts (coalesced packets).
- **Seal and open** (`packet_seal`, `packet_open`):
  - the nonce is the iv with the packet number in its last 8 bytes;
  - the additional data is the header without protection;
  - the open is in place, in the private copy.

  Failures:
  - A tag that does not verify gives `Not_Authentic`. The header is put back as it came; the frames are erased (the module erases what it wrote). To try another key, take the datagram again.
  - Reserved bits that are not 0 after the open give `Bad_Value`: a PROTOCOL_VIOLATION in RFC 9000, section 17.2.
- **Retry** (RFC 9001, section 5.8): `retry_integrity_tag` and `retry_integrity_check`, with the fixed key and nonce of version 1. The Retry Pseudo-Packet is the additional data of AES-128-GCM, and the module takes 1024 bytes of additional data at most: a Retry token over about 980 bytes is refused. The tokens of this system will be short.
- **Limits**:
  - A datagram has 2048 bytes at most: a place of the region of an endpoint.
  - The header of a packet, with its token, has 1024 bytes at most: the additional data of the module.

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
  - 50 000 random datagrams, half of them with a long header of version 1 (none traps, none opens).

The values of appendix A were copied from the text of the RFC by a script that is not in the repository; none was typed by hand.

## 4. The next layers (designed, not built)

1. **TLS 1.3 for QUIC** (RFC 8446, RFC 9001):
   - the key schedule;
   - ClientHello, ServerHello, EncryptedExtensions, Certificate, CertificateVerify and Finished in CRYPTO frames;
   - the transport parameters extension and ALPN.

   Authentication by raw public keys (RFC 7250) with Ed25519: no X.509 is read.
   - The kernel tool makes the key pair of the host at build time.
   - The root service gives the public key of the host to `remote` as a grant, which the person can read and revoke.
   - The host knows the public key of the machine.
2. **The transport**:
   - packet number spaces, ACK frames and loss detection with the PTO of RFC 9002;
   - congestion control, from the ideas and the tests of the Reno of `support/tcp`;
   - bidirectional streams with flow control per stream and per connection;
   - connection identifiers (no migration);
   - Version Negotiation and Retry;
   - the 3x amplification limit before address validation (a MUST of RFC 9000, section 8);
   - the idle timeout, CONNECTION_CLOSE and the stateless reset.
3. **The endpoint**: a listen grant for datagrams. The service admits a remote on its first datagram to the listen port, with the limits of the TCP table of admitted remotes (64 places, a place idle for 120 s serves again). The amplification limit and Retry of QUIC protect the server; the service keeps checking the port and the size.
4. **The users**, in order:
   - an echo between the tool and a test program, with loss through the peer;
   - a stack that this project did not write, over QEMU user networking;
   - `remote` over QUIC with mutual authentication.

## 5. What is not built, and will not be in version 1 of this library

- Connection migration.
- 0-RTT.
- Key update (the key phase bit is read, `Opened_Packet.key_phase`).
- ECN.
- The datagram extension (RFC 9221).
- HTTP/3.
- AES-256-GCM and AES-128-CCM: the suites of TLS 1.3 that this library does not offer.
