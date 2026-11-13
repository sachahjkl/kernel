package quic

// The packets of QUIC version 1: the reading of a header as hostile input
// (RFC 9000, section 17), and packet protection with header protection
// (RFC 9001, sections 5.3 and 5.4).
//
// Each procedure works on one private copy of a datagram (datagram_take): a
// datagram in a region that the network service or another program can
// write is copied once, and its header is read, unmasked and opened in that
// copy only. So no byte is checked in one place and used from another.

import "contract:errors"

// The version number of QUIC version 1, the one version that this library speaks (RFC 9000, section 15).
//
// A long header carries the version in the 4 bytes after its first byte. `header_read` reads the
// whole header only for this version; a header of another version gives `Unknown_Version`, and the
// version 0 is a Version Negotiation packet.
QUIC_VERSION_1 :: 0x0000_0001

// The Header Form bit of the first byte of a packet: set for a long header, clear for a short header (RFC 9000, section 17.2).
//
// A long header carries the version and both connection identifiers with their lengths: the
// packets of the handshake have one. A short header carries the Destination Connection ID only: the
// 1-RTT packets have one.
LONG_HEADER_FORM :: 0x80

// The Fixed Bit of the first byte of a packet of version 1: always set (RFC 9000, sections 17.2 and 17.3).
//
// A packet of version 1 with this bit clear is not a valid packet: `header_read` refuses it
// (`Bad_Value`), and `packet_seal` refuses to seal one. The bit has no meaning in a Version
// Negotiation packet, where it is not checked.
FIXED_BIT :: 0x40

// The most bytes of one datagram that the library takes: 2048.
//
// It is the size of one place of the datagram region of an endpoint of the network service, and the
// size of the additional data that one call of the module takes. `datagram_take` refuses a longer
// datagram. A connection of this library gives this value as its `max_udp_payload_size`.
DATAGRAM_LIMIT :: 2048

// The type of a QUIC packet, as `header_read` found it.
//
// The first four members are the types of a long header of version 1, with the values of the two
// type bits of the first byte (RFC 9000, section 17.2). The other three are not values of the wire:
// the reader gives them for the headers that have no type bits.
Packet_Type :: enum u8 {
	Initial             = 0, // The first packets of a connection, with a token and the start of the TLS handshake (RFC 9000, section 17.2.2). Their keys come from a connection identifier (`initial_keys`).
	Zero_Rtt            = 1, // A packet of early data (RFC 9000, section 17.2.3). Its header is read; this library has no 0-RTT keys, so it never opens one.
	Handshake           = 2, // A packet with the rest of the TLS handshake, under the handshake keys (RFC 9000, section 17.2.4).
	Retry               = 3, // A packet of a server with a retry token and an integrity tag, with no packet number and no payload (RFC 9000, section 17.2.5). `retry_integrity_check` checks it; no key opens it.
	Version_Negotiation = 4, // A long header with the version 0 (RFC 9000, section 17.2.1). Only its connection identifiers are read; it has no packet number and no protection.
	Unknown_Version     = 5, // A long header with a version that this library does not speak: its connection identifiers are read, for a Version Negotiation answer, and nothing after them.
	One_Rtt             = 6, // A short header (RFC 9000, section 17.3): a packet of the Application level. It is the last packet of its datagram.
}

// The fields of one packet header, as `header_read` found them in the private copy of a datagram.
//
// The record holds the two connection identifiers by value, and each other field as an offset in
// the datagram: the packet number and the payload are still protected, and the later steps
// (`header_protection_remove`, `packet_payload_open`) work on the datagram at these offsets. A
// datagram can hold several packets (coalesced packets, RFC 9000, section 12.2): `end` of one is
// `start` of the next.
//
// Each offset is checked: a record that `header_read` gave with true never names a byte past the
// datagram that it read.
Packet_Header :: struct {
	type:                             Packet_Type, // The type of the packet.
	version:                          u32, // The 4 bytes of the Version field of a long header. 0 for a short header, which has no such field, and for a Version Negotiation packet.
	start:                            int, // The offset of the first byte of this packet in the datagram.
	destination_connection_id:        [CONNECTION_ID_LIMIT]u8, // The Destination Connection ID: the identifier by which the receiver finds its connection.
	destination_connection_id_length: int, // Its bytes: 0 to `CONNECTION_ID_LIMIT`. For a short header, the length that the caller of `header_read` gave.
	source_connection_id:             [CONNECTION_ID_LIMIT]u8, // The Source Connection ID of a long header: the identifier that the sender asks the receiver to use for it.
	source_connection_id_length:      int, // Its bytes: 0 to `CONNECTION_ID_LIMIT`. 0 for a short header, which has no such field.
	token_offset:                     int, // The offset of the token: the Token field of an Initial packet, or the Retry Token of a Retry packet. 0 for each other type.
	token_length:                     int, // The bytes of the token. An Initial packet can have 0; a Retry packet never has 0.
	packet_number_offset:             int, // The offset of the first byte of the packet number, still protected. 0 for a packet with no packet number: Retry, Version Negotiation, an unknown version.
	end:                              int, // The offset of the byte after this packet: the next packet of the datagram starts there. For a short header, a Retry, a Version Negotiation packet and an unknown version it is the end of the datagram.
}

// datagram_take copies a datagram that came from the network into private memory of the caller, once, and gives the copy.
//
// A [datagram](term:datagram) arrives in a region that the network service writes, and that another
// program can change at any time. A reader that checks a length there and uses it later can be
// tricked between the two. So the first step of each receive is this copy, and each later step
// (the header, the header protection, the open in place) works on the copy only: no byte is checked
// in one place and used from another (docs/QUIC.md, "2. The form of the library").
//
// **Parameters**
//
// - `received`: the bytes of the datagram in the region of the endpoint.
// - `private_memory`: memory that only the caller writes, of `DATAGRAM_LIMIT` bytes or more.
// - `error`: the error record of a failure.
//
// **Results**: the copy, a slice of `private_memory` with the length of the datagram, and true. nil
// and false with `Too_Long` (argument 1) for a datagram over `DATAGRAM_LIMIT` or over the private
// memory: the record holds the size of the datagram and the size that fits. Such a datagram is
// refused whole; it is never cut.
datagram_take :: proc "contextless" (received: []u8, private_memory: []u8, error: ^errors.Error_Record) -> (copy_of_the_datagram: []u8, ok: bool) {
	if len(received) > DATAGRAM_LIMIT || len(received) > len(private_memory) {
		return nil, fail_at(error, .Too_Long, 1, len(received), min(DATAGRAM_LIMIT, len(private_memory)))
	}
	count := copy(private_memory, received)
	return private_memory[:count], true
}

// header_read reads the header of the packet that starts at `start` in a datagram, as hostile input.
//
// It is the first reading of a packet, before any key: it finds the type of the packet, its
// connection identifiers, its token and where its packet number and its end are (RFC 9000, section
// 17). The caller then finds the connection by the Destination Connection ID, chooses the keys of
// the type, and opens the packet. Each length is checked before a byte is read, and nothing is read
// past the datagram.
//
// **Parameters**
//
// - `datagram`: the private copy of the datagram (`datagram_take`).
// - `start`: the offset of the first byte of the packet: 0, or the `end` of the packet before.
// - `short_destination_length`: the length of the connection identifiers that this endpoint gives.
//   A short header does not carry the length of its Destination Connection ID: the receiver must
//   know it. 0 to `CONNECTION_ID_LIMIT`.
// - `header`: where the fields go.
// - `error`: the error record of a failure.
//
// **What it reads**, by the form of the header:
//
// - **A short header**: the Fixed Bit, the Destination Connection ID of the given length, the
//   place of the packet number. The type is `One_Rtt`, and the packet runs to the end of the
//   datagram.
// - **A long header of the version 0**: the two connection identifiers. The type is
//   `Version_Negotiation`; the list of versions after them is not read.
// - **A long header of another version than 1**: the two connection identifiers. The type is
//   `Unknown_Version`.
// - **A long header of version 1**: the Fixed Bit, the type, the two connection identifiers; for an
//   Initial packet the token; for an Initial, a 0-RTT and a Handshake packet the Length, which gives
//   the end of the packet; for a Retry packet the token, which runs to the 16 bytes of the tag.
//
// **Result**: true when the header is whole. False, with a record whose value is the offset of the
// field; the record names argument 1, except where the list names another one:
//
// - `Too_Small`: `start` is not in the datagram, or the datagram ends inside a field; or the packet
//   is too short for the sample of header protection, 4 + 16 bytes after the start of its packet
//   number (RFC 9001, section 5.4.2);
// - `Bad_Value`: the Fixed Bit of a packet of version 1 is 0;
// - `Bad_Value` (argument 3): `short_destination_length` is not 0 to 20;
// - `Too_Long`: a connection identifier of a long header has more than 20 bytes. Version 1 allows
//   20; a longer identifier of another version is refused too, because this library does not answer
//   it;
// - `Out_Of_Range`: the token of an Initial packet, or the Length of a packet, passes the end of
//   the datagram;
// - `Empty`: a Retry packet has no token. A client discards such a Retry (RFC 9000, section
//   17.2.5.2).
//
// After a failure the caller drops the rest of the datagram: it cannot know where the next packet
// starts.
//
// **What it does not check**: the reserved bits and the packet number, which are still protected;
// the duties of the transport on an Initial packet (a datagram of 1200 bytes, a Destination
// Connection ID of 8 bytes at a server, no token from a server).
header_read :: proc "contextless" (datagram: []u8, start: int, short_destination_length: int, header: ^Packet_Header, error: ^errors.Error_Record) -> bool {
	header^ = {start = start}
	if start < 0 || start >= len(datagram) {
		return fail_at(error, .Too_Small, 1, start, start + 1, len(datagram))
	}
	first := datagram[start]
	position := start + 1
	if first & LONG_HEADER_FORM == 0 {
		// A short header: the fixed bit, the Destination Connection ID of the
		// length that this endpoint gives, the packet number.
		if first & FIXED_BIT == 0 {
			return fail_at(error, .Bad_Value, 1, start, FIXED_BIT, int(first))
		}
		if short_destination_length < 0 || short_destination_length > CONNECTION_ID_LIMIT {
			return fail_at(error, .Bad_Value, 3, short_destination_length, CONNECTION_ID_LIMIT)
		}
		if short_destination_length > len(datagram) - position {
			return fail_at(error, .Too_Small, 1, position, position + short_destination_length, len(datagram))
		}
		header.type = .One_Rtt
		header.destination_connection_id_length = copy(header.destination_connection_id[:], datagram[position:][:short_destination_length])
		header.packet_number_offset = position + short_destination_length
		header.end = len(datagram)
		return sample_fits(header, error)
	}
	// A long header: the version, then each connection identifier with its
	// length (RFC 9000, section 17.2).
	if 4 + 1 > len(datagram) - position {
		return fail_at(error, .Too_Small, 1, position, position + 5, len(datagram))
	}
	header.version = u32(datagram[position]) << 24 | u32(datagram[position + 1]) << 16 | u32(datagram[position + 2]) << 8 | u32(datagram[position + 3])
	position += 4
	for identifier in 0 ..< 2 {
		if position >= len(datagram) {
			return fail_at(error, .Too_Small, 1, position, position + 1, len(datagram))
		}
		length := int(datagram[position])
		if length > CONNECTION_ID_LIMIT {
			// Version 1 allows 20 bytes. A longer identifier of another
			// version is refused too: this library does not answer it.
			return fail_at(error, .Too_Long, 1, position, CONNECTION_ID_LIMIT, length)
		}
		position += 1
		if length > len(datagram) - position {
			return fail_at(error, .Too_Small, 1, position, position + length, len(datagram))
		}
		if identifier == 0 {
			header.destination_connection_id_length = copy(header.destination_connection_id[:], datagram[position:][:length])
		} else {
			header.source_connection_id_length = copy(header.source_connection_id[:], datagram[position:][:length])
		}
		position += length
	}
	switch header.version {
	case 0:
		// Version Negotiation fills its datagram; its fixed bit has no meaning.
		header.type = .Version_Negotiation
		header.end = len(datagram)
		return true
	case QUIC_VERSION_1:
	case:
		header.type = .Unknown_Version
		header.end = len(datagram)
		return true
	}
	if first & FIXED_BIT == 0 {
		return fail_at(error, .Bad_Value, 1, start, FIXED_BIT, int(first))
	}
	header.type = Packet_Type((first >> 4) & 0x03)
	if header.type == .Retry {
		// A Retry token, then the Retry Integrity Tag: the datagram ends there.
		if TAG_SIZE > len(datagram) - position {
			return fail_at(error, .Too_Small, 1, position, position + TAG_SIZE, len(datagram))
		}
		header.token_offset = position
		header.token_length = len(datagram) - position - TAG_SIZE
		header.end = len(datagram)
		if header.token_length == 0 {
			// A client discards a Retry with an empty token (RFC 9000,
			// section 17.2.5.2), and only a client reads a Retry.
			return fail_at(error, .Empty, 1, position)
		}
		return true
	}
	if header.type == .Initial {
		token_length, size, ok := variable_length_integer_read(datagram, position)
		if !ok {
			return fail_at(error, .Too_Small, 1, position, position + 1, len(datagram))
		}
		position += size
		if token_length > u64(len(datagram) - position) {
			return fail_at(error, .Out_Of_Range, 1, position, len(datagram) - position, int(min(token_length, u64(max(int)))))
		}
		header.token_offset = position
		header.token_length = int(token_length)
		position += int(token_length)
	}
	// The Length field: the bytes of the packet number and of the payload.
	length, size, ok := variable_length_integer_read(datagram, position)
	if !ok {
		return fail_at(error, .Too_Small, 1, position, position + 1, len(datagram))
	}
	position += size
	if length > u64(len(datagram) - position) {
		return fail_at(error, .Out_Of_Range, 1, position, len(datagram) - position, int(min(length, u64(max(int)))))
	}
	header.packet_number_offset = position
	header.end = position + int(length)
	return sample_fits(header, error)
}

// sample_fits says that a packet holds the sample of header protection.
//
// The sample is `SAMPLE_SIZE` bytes, taken 4 bytes after the start of the packet number, as if the
// packet number had its longest form (RFC 9001, section 5.4.2). A packet that ends before the
// sample cannot have its header protection removed, so `header_read` refuses it here (`Too_Small`,
// argument 1) and the caller discards it. A sender never makes such a packet: `packet_seal` asks
// for 4 bytes of packet number and frames before the tag.
@(private)
sample_fits :: proc "contextless" (header: ^Packet_Header, error: ^errors.Error_Record) -> bool {
	if header.packet_number_offset + 4 + SAMPLE_SIZE > header.end {
		return fail_at(error, .Too_Small, 1, header.packet_number_offset, header.packet_number_offset + 4 + SAMPLE_SIZE, header.end)
	}
	return true
}

// What the removal of header protection gives: the fields that header protection hid.
//
// `header_protection_remove` fills it. The caller reads `key_phase` to choose the keys, then gives
// the record to `packet_payload_open` (RFC 9001, section 5.4).
Unprotected_Header :: struct {
	first_byte:           u8, // The first byte of the packet without header protection: its low bits are the reserved bits, the key phase of a short header, and the length of the packet number.
	packet_number:        u64, // The whole packet number, decoded against the largest number of its space (`packet_number_decode`). It makes the nonce of the open.
	packet_number_length: int, // The bytes of the packet number on the wire: 1 to 4.
	key_phase:            bool, // A short header: the Key Phase bit (RFC 9001, section 6). It says which generation of the 1-RTT keys sealed the packet. Always false for a long header.
	payload_offset:       int, // The offset of the first byte of the sealed frames, after the packet number.
}

// What an open gives: the packet number of an authentic packet, and where its frames are.
//
// `packet_payload_open` and `packet_open` fill it. The frames are plain bytes in the private copy
// of the datagram, from `payload_offset`, for `payload_length` bytes; the 16 bytes of the tag after
// them are not part of the frames. A record of a failed open is zero.
Opened_Packet :: struct {
	packet_number:  u64, // The whole packet number. The caller records it, so that it never processes a packet two times.
	first_byte:     u8, // The first byte of the packet without header protection.
	key_phase:      bool, // A short header: the Key Phase bit (RFC 9001, section 6).
	payload_offset: int, // The offset of the frames, decrypted in place in the copy of the datagram.
	payload_length: int, // The bytes of the frames: the sealed payload minus the tag.
}

// header_protection_mask gives the 5 bytes of the mask of a sample, with the cipher of the suite of the keys.
//
// It chooses the export of the module by the suite: AES-128 for `Aes_128_Gcm_Sha256` (RFC 9001,
// section 5.4.3), ChaCha20 for `ChaCha20_Poly1305_Sha256` (section 5.4.4), and gives it the header
// protection key in the size of the suite. The removal and the seal both call it, so the two
// directions cannot choose differently. False with the error of the module when the mask does not
// come whole. The caller checked the suite before (`keys_usable`).
@(private)
header_protection_mask :: proc "contextless" (cryptography: ^Cryptography, keys: ^Packet_Keys, sample: []u8, mask: ^[MASK_SIZE]u8, error: ^errors.Error_Record) -> bool {
	key := string(keys.header_protection_key[:packet_key_sizes[keys.suite]])
	sample_text := string(sample)
	result := mask[:]
	procedure := keys.suite == .Aes_128_Gcm_Sha256 ? cryptography.header_protection_mask_with_aes_128 : cryptography.header_protection_mask_with_chacha20
	return procedure(&key, &sample_text, &result, error) == MASK_SIZE
}

// nonce_of gives the nonce of the AEAD for one packet: the iv with the packet number in its last 8 bytes, by exclusive or.
//
// The packet number is taken as 8 bytes, the most significant byte first, and combined with the
// last 8 of the 12 bytes of the iv (RFC 9001, section 5.3). A packet number is used once in its
// space, so one key never sees one nonce two times: that is the rule that an AEAD needs.
@(private)
nonce_of :: proc "contextless" (keys: ^Packet_Keys, packet_number: u64) -> (nonce: [IV_SIZE]u8) {
	nonce = keys.iv
	for index in 0 ..< 8 {
		nonce[IV_SIZE - 1 - index] ~= u8(packet_number >> (8 * uint(index)))
	}
	return
}

// keys_usable says that a `Packet_Keys` record holds keys: its suite is a member of `Cipher_Suite`.
//
// A zero record, the state of keys that are not ready or that were erased, gives false and
// `Bad_Value` (argument 2, with the suite as its value). Each procedure that protects or opens a
// packet calls it first, so that it never indexes the table of key sizes with a value that is not a
// suite, and never uses a key of zeros.
@(private)
keys_usable :: proc "contextless" (keys: ^Packet_Keys, error: ^errors.Error_Record) -> bool {
	if keys.suite != .Aes_128_Gcm_Sha256 && keys.suite != .ChaCha20_Poly1305_Sha256 {
		return fail_at(error, .Bad_Value, 2, int(keys.suite))
	}
	return true
}

// header_protection_remove removes header protection from a packet, and gives its packet number and its key phase.
//
// It is the first of the two steps of an open (RFC 9001, section 5.4). It takes the sample of 16
// bytes, 4 bytes after the start of the packet number, asks the module for the mask, and unmasks
// the low bits of the first byte (4 bits of a long header, 5 of a short one) and the bytes of the
// packet number. Then it decodes the whole packet number.
//
// **Why it is a step of its own.** Only the header protection key is used, and that key does not
// change at a key update (RFC 9001, section 6.1). So the caller can read the key phase here, and
// choose the keys of the payload from it before `packet_payload_open`. `packet_open` makes both
// steps for a packet that has no key phase.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `keys`: the keys of the level of the packet. Only the suite and the header protection key are
//   read.
// - `datagram`: the private copy of the datagram. The header is unmasked in place.
// - `header`: the header that `header_read` gave for this packet.
// - `largest_packet_number`: the largest number that was opened in the packet number space of the
//   packet (`packet_number_decode`).
// - `unprotected`: where the fields go. It is zero after a failure.
// - `error`: the error record of a failure.
//
// **Result**: true when the header is unmasked. False:
//
// - `Bad_Value` (argument 2): the keys have no suite;
// - `Bad_Value` (argument 4): the header has no packet number (a Retry, a Version Negotiation
//   packet), or its offsets do not fit the datagram;
// - `Too_Small` (argument 3): the packet does not hold the sample;
// - an error of the mask of the module.
//
// **Call it once for each packet.** The removal is in place: a second call would mask the header
// again. Nothing is authenticated yet: the fields are a guess until the open verifies the tag.
header_protection_remove :: proc "contextless" (cryptography: ^Cryptography, keys: ^Packet_Keys, datagram: []u8, header: ^Packet_Header, largest_packet_number: u64, unprotected: ^Unprotected_Header, error: ^errors.Error_Record) -> bool {
	unprotected^ = {}
	if !keys_usable(keys, error) {
		return false
	}
	if header.packet_number_offset == 0 || header.end > len(datagram) || header.start < 0 || header.start >= header.packet_number_offset {
		return fail_at(error, .Bad_Value, 4, header.packet_number_offset)
	}
	start, number_offset := header.start, header.packet_number_offset
	if number_offset + 4 + SAMPLE_SIZE > header.end {
		return fail_at(error, .Too_Small, 3, number_offset, number_offset + 4 + SAMPLE_SIZE, header.end)
	}
	long := datagram[start] & LONG_HEADER_FORM != 0
	mask: [MASK_SIZE]u8
	if !header_protection_mask(cryptography, keys, datagram[number_offset + 4:][:SAMPLE_SIZE], &mask, error) {
		return false
	}
	first := datagram[start] ~ (mask[0] & (long ? 0x0F : 0x1F))
	number_length := int(first & 0x03) + 1
	truncated: u64
	for index in 0 ..< number_length {
		datagram[number_offset + index] ~= mask[1 + index]
		truncated = truncated << 8 | u64(datagram[number_offset + index])
	}
	datagram[start] = first
	unprotected^ = {
		first_byte           = first,
		packet_number        = packet_number_decode(largest_packet_number, truncated, uint(8 * number_length)),
		packet_number_length = number_length,
		key_phase            = !long && first & 0x04 != 0,
		payload_offset       = number_offset + number_length,
	}
	return true
}

// packet_payload_open opens the frames of a packet whose header protection was removed, with the keys that the caller chose.
//
// It is the second step of an open, the AEAD of [packet protection](term:packet-protection) (RFC
// 9001, section 5.3). The nonce is the iv with the packet number (`nonce_of`). The additional data
// is the header without protection, from the first byte of the packet to the last byte of its
// packet number. The frames are decrypted in place, in the private copy of the datagram.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `keys`: the keys of the level, and for a short header of the key phase, of the packet.
// - `datagram`: the private copy of the datagram.
// - `header`: the header that `header_read` gave.
// - `unprotected`: the record that `header_protection_remove` gave for this packet.
// - `opened`: where the result goes. It is zero after a failure.
// - `error`: the error record of a failure.
//
// **Result**: true for an authentic packet. False:
//
// - `Bad_Value` (argument 2): the keys have no suite;
// - `Bad_Value` (argument 5): the offsets of the two records do not fit the datagram;
// - `Not_Authentic`, from the module: the tag does not verify. The module erased the bytes of the
//   frames, so the packet cannot be opened again from this copy, with these keys or with others;
// - `Bad_Value` (argument 3, with the reserved bits in `found`): the tag verifies, and the reserved
//   bits of the first byte are not 0. RFC 9000, section 17.2, makes that a PROTOCOL_VIOLATION.
//
// **Why the reserved bits come last.** They are checked only after the tag verified. A packet that
// is [not authentic](term:not-authentic) can then never close a connection: the caller drops it.
// A caller that gets `Bad_Value` with argument 3 knows that its peer sent the packet.
packet_payload_open :: proc "contextless" (cryptography: ^Cryptography, keys: ^Packet_Keys, datagram: []u8, header: ^Packet_Header, unprotected: ^Unprotected_Header, opened: ^Opened_Packet, error: ^errors.Error_Record) -> bool {
	opened^ = {}
	if !keys_usable(keys, error) {
		return false
	}
	start, payload_offset := header.start, unprotected.payload_offset
	if header.end > len(datagram) || start < 0 || payload_offset <= start || payload_offset > header.end {
		return fail_at(error, .Bad_Value, 5, payload_offset)
	}
	nonce := nonce_of(keys, unprotected.packet_number)
	key := string(keys.key[:packet_key_sizes[keys.suite]])
	nonce_text := string(nonce[:])
	additional := string(datagram[start:payload_offset])
	sealed := string(datagram[payload_offset:header.end])
	result := datagram[payload_offset:header.end]
	open := keys.suite == .Aes_128_Gcm_Sha256 ? cryptography.open_with_aes_128_gcm : cryptography.open_with_chacha20_poly1305
	count := open(&key, &nonce_text, &additional, &sealed, &result, error)
	if count < 0 {
		return false
	}
	first := unprotected.first_byte
	long := first & LONG_HEADER_FORM != 0
	reserved := long ? first & 0x0C : first & 0x18
	if reserved != 0 {
		return fail_at(error, .Bad_Value, 3, start, 0, int(reserved))
	}
	opened^ = {
		packet_number  = unprotected.packet_number,
		first_byte     = first,
		key_phase      = unprotected.key_phase,
		payload_offset = payload_offset,
		payload_length = int(count),
	}
	return true
}

// packet_open removes header protection and opens the frames of a packet with one set of keys.
//
// It is `header_protection_remove`, then `packet_payload_open`, with the same keys. That fits each
// packet of a long header, which has no key phase: Initial and Handshake packets. A short header of
// a connection that follows key updates goes through the two steps, with the keys of its key phase
// in the second.
//
// The parameters are those of the two steps: `keys` for both, `largest_packet_number` for the
// decoding of the packet number, `opened` for the result. The errors are theirs too. After a
// failure of the second step the frames are erased, and the header stays unmasked: the packet
// cannot be tried again from this copy.
//
// ```odin
// header: Packet_Header
// opened: Opened_Packet
// if header_read(datagram, start, CONNECTION_ID_SIZE, &header, error) &&
//    packet_open(cryptography, &receive_keys, datagram, &header, largest, &opened, error) {
// 	frames := datagram[opened.payload_offset:][:opened.payload_length]
// }
// ```
packet_open :: proc "contextless" (cryptography: ^Cryptography, keys: ^Packet_Keys, datagram: []u8, header: ^Packet_Header, largest_packet_number: u64, opened: ^Opened_Packet, error: ^errors.Error_Record) -> bool {
	opened^ = {}
	unprotected: Unprotected_Header
	if !header_protection_remove(cryptography, keys, datagram, header, largest_packet_number, &unprotected, error) {
		return false
	}
	return packet_payload_open(cryptography, keys, datagram, header, &unprotected, opened, error)
}

// packet_seal protects a packet that the caller wrote in private memory: it writes the packet number, seals the frames and applies header protection.
//
// It is the reverse of `packet_open` (RFC 9001, sections 5.3 and 5.4), in place.
//
// **What the caller wrote before the call**, from `start`:
//
// 1. the header without protection: the first byte with the Fixed Bit set, the reserved bits 0 and
//    the length of the packet number minus 1 in its 2 low bits; for a long header, the version, the
//    identifiers, the token of an Initial packet, and the Length, which counts the packet number,
//    the frames and the tag;
// 2. room for the packet number, at `packet_number_offset`;
// 3. `payload_length` bytes of frames;
// 4. room for the tag of 16 bytes.
//
// **What the call does**: it writes the packet number, truncated to the length that the first byte
// gives; encrypts the frames in place and appends the tag, with the header as additional data; then
// masks the low bits of the first byte and the packet number.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `keys`: the keys of the level to send at.
// - `packet`: the buffer that holds the packet.
// - `start`: the offset of its first byte.
// - `packet_number_offset`: the offset of its packet number.
// - `payload_length`: the bytes of its frames.
// - `packet_number`: the whole packet number.
// - `error`: the error record of a failure.
//
// **Results**: the offset of the byte after the packet, where a next packet of the datagram can
// start, and true. 0 and false:
//
// - `Bad_Value` (argument 2): the keys have no suite;
// - `Bad_Value` (argument 5): `packet_number_offset` is not after `start` and inside the buffer, or
//   `payload_length` is negative;
// - `Too_Small` (argument 6): the packet number and the frames together have less than 4 bytes, so
//   the sample of header protection does not fit (RFC 9001, section 5.4.2). The caller adds PADDING
//   frames;
// - `Too_Small` (argument 3): the buffer has no room for the frames and the tag;
// - `Out_Of_Range` (argument 7): the packet number is over `PACKET_NUMBER_LARGEST`;
// - `Bad_Value` (argument 3): the Fixed Bit of the first byte is 0;
// - `Bad_Value` (argument 3): a long header whose Length does not end the packet after the tag, or
//   whose packet number is not at `packet_number_offset`. The call reads the header as the peer
//   will (`header_read`): the peer could not open such a packet, and the loss would be silent;
// - an error of the seal or of the mask of the module.
//
// After a failure the packet can be partly written: the caller does not send it.
//
// **What it does not check**: that the bytes of the packet number are enough for the peer to decode
// it (`packet_number_encoded_size`), and that a packet number is used once. Both are duties of the
// caller: a number that seals two packets with one key breaks the AEAD.
packet_seal :: proc "contextless" (cryptography: ^Cryptography, keys: ^Packet_Keys, packet: []u8, start: int, packet_number_offset: int, payload_length: int, packet_number: u64, error: ^errors.Error_Record) -> (end: int, ok: bool) {
	if !keys_usable(keys, error) {
		return 0, false
	}
	if start < 0 || packet_number_offset <= start || packet_number_offset >= len(packet) || payload_length < 0 {
		return 0, fail_at(error, .Bad_Value, 5, packet_number_offset)
	}
	first := packet[start]
	long := first & LONG_HEADER_FORM != 0
	number_length := int(first & 0x03) + 1
	payload_offset := packet_number_offset + number_length
	if number_length + payload_length < 4 {
		return 0, fail_at(error, .Too_Small, 6, payload_length, 4 - number_length)
	}
	if payload_length + TAG_SIZE > len(packet) - payload_offset {
		return 0, fail_at(error, .Too_Small, 3, len(packet), payload_offset + payload_length + TAG_SIZE)
	}
	end = payload_offset + payload_length + TAG_SIZE
	if packet_number > PACKET_NUMBER_LARGEST {
		return 0, fail_at(error, .Out_Of_Range, 7, int(min(packet_number, u64(max(int)))), int(PACKET_NUMBER_LARGEST))
	}
	if first & FIXED_BIT == 0 {
		return 0, fail_at(error, .Bad_Value, 3, start, FIXED_BIT, int(first))
	}
	for index in 0 ..< number_length {
		packet[packet_number_offset + index] = u8(packet_number >> (8 * uint(number_length - 1 - index)))
	}
	if long {
		// The header as the peer will read it: its Length must end the
		// packet after the tag.
		written: Packet_Header
		if !header_read(packet[:end], start, 0, &written, error) || written.packet_number_offset != packet_number_offset || written.end != end {
			return 0, fail_at(error, .Bad_Value, 3, packet_number_offset, end, written.end)
		}
	}
	nonce := nonce_of(keys, packet_number)
	key := string(keys.key[:packet_key_sizes[keys.suite]])
	nonce_text := string(nonce[:])
	additional := string(packet[start:payload_offset])
	text := string(packet[payload_offset:][:payload_length])
	result := packet[payload_offset:end]
	seal := keys.suite == .Aes_128_Gcm_Sha256 ? cryptography.seal_with_aes_128_gcm : cryptography.seal_with_chacha20_poly1305
	if seal(&key, &nonce_text, &additional, &text, &result, error) != i64(payload_length + TAG_SIZE) {
		return 0, false
	}
	mask: [MASK_SIZE]u8
	if !header_protection_mask(cryptography, keys, packet[packet_number_offset + 4:][:SAMPLE_SIZE], &mask, error) {
		return 0, false
	}
	packet[start] ~= mask[0] & (long ? 0x0F : 0x1F)
	for index in 0 ..< number_length {
		packet[packet_number_offset + index] ~= mask[1 + index]
	}
	return end, true
}

// retry_integrity_check says if the tag at the end of a Retry packet is the tag of that packet for the identifier that the client sent.
//
// A client calls it for each Retry packet, before it believes it (RFC 9001, section 5.8). It
// computes the tag again (`retry_integrity_tag`) over the packet without its last 16 bytes and the
// original Destination Connection ID, and compares the two in a time that does not depend on the
// bytes.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `original_destination_connection_id`: the Destination Connection ID of the Initial packet that
//   the client sent.
// - `datagram`: the private copy of the datagram.
// - `header`: the header that `header_read` gave: a Retry packet that ends the datagram.
// - `error`: the error record of a failure.
//
// **Result**: true when the tag is right. False:
//
// - `Bad_Value` (argument 4): the header is not a Retry packet that runs to the end of the
//   datagram;
// - `Not_Authentic` (argument 3, with the offset of the tag): the tag is another one. The Retry
//   does not answer the Initial packet of this client, or the network damaged it: the client drops
//   it;
// - an error of `retry_integrity_tag`.
//
// A right tag does not prove who sent the Retry: see `retry_integrity_tag`. The other rules of a
// client for a Retry (one Retry only, a Source Connection ID that is not its own identifier) are
// the transport's.
retry_integrity_check :: proc "contextless" (cryptography: ^Cryptography, original_destination_connection_id: []u8, datagram: []u8, header: ^Packet_Header, error: ^errors.Error_Record) -> bool {
	if header.type != .Retry || header.end != len(datagram) || header.end - header.start < TAG_SIZE {
		return fail_at(error, .Bad_Value, 4, int(header.type))
	}
	expected: [TAG_SIZE]u8
	if !retry_integrity_tag(cryptography, original_destination_connection_id, datagram[header.start:header.end - TAG_SIZE], &expected, error) {
		return false
	}
	difference: u8
	for index in 0 ..< TAG_SIZE {
		difference |= expected[index] ~ datagram[header.end - TAG_SIZE + index]
	}
	if difference != 0 {
		return fail_at(error, .Not_Authentic, 3, header.end - TAG_SIZE)
	}
	return true
}
