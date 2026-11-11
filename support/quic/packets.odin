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

QUIC_VERSION_1 :: 0x0000_0001
LONG_HEADER_FORM :: 0x80
FIXED_BIT :: 0x40
DATAGRAM_LIMIT :: 2048 // The bytes of one datagram that the library takes: a place of the region of an endpoint.

Packet_Type :: enum u8 {
	Initial             = 0,
	Zero_Rtt            = 1,
	Handshake           = 2,
	Retry               = 3,
	Version_Negotiation = 4, // A long header with the version 0 (RFC 9000, section 17.2.1).
	Unknown_Version     = 5, // A long header with a version that this library does not speak: its connection identifiers are read, for a Version Negotiation answer.
	One_Rtt             = 6, // A short header (RFC 9000, section 17.3).
}

// The fields of one packet header, as offsets in the private copy of its
// datagram. A packet that has a packet number has packet_number_offset > 0.
Packet_Header :: struct {
	type:                             Packet_Type,
	version:                          u32,
	start:                            int, // The first byte of this packet in the datagram.
	destination_connection_id:        [CONNECTION_ID_LIMIT]u8,
	destination_connection_id_length: int,
	source_connection_id:             [CONNECTION_ID_LIMIT]u8,
	source_connection_id_length:      int,
	token_offset:                     int, // Initial: the token; Retry: the Retry token.
	token_length:                     int,
	packet_number_offset:             int,
	end:                              int, // The byte after this packet: the next packet of the datagram starts there.
}

// datagram_take copies a datagram that came from the network into private
// memory of the caller, once, and gives the copy. A datagram over the
// private memory, or over DATAGRAM_LIMIT, is refused: it is not cut.
datagram_take :: proc "contextless" (received: []u8, private_memory: []u8, error: ^errors.Error_Record) -> (copy_of_the_datagram: []u8, ok: bool) {
	if len(received) > DATAGRAM_LIMIT || len(received) > len(private_memory) {
		return nil, fail_at(error, .Too_Long, 1, len(received), min(DATAGRAM_LIMIT, len(private_memory)))
	}
	count := copy(private_memory, received)
	return private_memory[:count], true
}

// header_read reads the header of the packet that starts at start in a
// datagram. short_destination_length is the length of the connection
// identifiers that this endpoint gives (a short header does not carry it).
// Each length is checked before a byte is read: a header that does not fit,
// a connection identifier over 20 bytes, a token or a Length past the end of
// the datagram, a fixed bit of 0, or a packet too short for the sample of
// header protection gives false and an error record (argument 1, value the
// offset of the field). Nothing is read past the datagram.
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

// sample_fits says that a packet holds the sample of header protection: 16
// bytes from 4 bytes after the start of the packet number (RFC 9001, section
// 5.4.2). A packet that does not is discarded.
@(private)
sample_fits :: proc "contextless" (header: ^Packet_Header, error: ^errors.Error_Record) -> bool {
	if header.packet_number_offset + 4 + SAMPLE_SIZE > header.end {
		return fail_at(error, .Too_Small, 1, header.packet_number_offset, header.packet_number_offset + 4 + SAMPLE_SIZE, header.end)
	}
	return true
}

// What the removal of header protection gives: the fields of the header
// that header protection hid (RFC 9001, section 5.4).
Unprotected_Header :: struct {
	first_byte:           u8, // Without header protection.
	packet_number:        u64, // The whole number, decoded against the largest number of its space.
	packet_number_length: int, // 1 to 4 bytes on the wire.
	key_phase:            bool, // A short header: the key phase bit (RFC 9001, section 6). It chooses the keys of the open.
	payload_offset:       int, // The first byte of the sealed frames.
}

// What an open gives.
Opened_Packet :: struct {
	packet_number:  u64,
	first_byte:     u8, // Without header protection.
	key_phase:      bool, // A short header: the key phase bit (RFC 9001, section 6).
	payload_offset: int, // The frames, decrypted in place in the copy of the datagram.
	payload_length: int,
}

// header_protection_mask gives the mask of a sample with the header
// protection of a suite.
@(private)
header_protection_mask :: proc "contextless" (cryptography: ^Cryptography, keys: ^Packet_Keys, sample: []u8, mask: ^[MASK_SIZE]u8, error: ^errors.Error_Record) -> bool {
	key := string(keys.header_protection_key[:packet_key_sizes[keys.suite]])
	sample_text := string(sample)
	result := mask[:]
	procedure := keys.suite == .Aes_128_Gcm_Sha256 ? cryptography.header_protection_mask_with_aes_128 : cryptography.header_protection_mask_with_chacha20
	return procedure(&key, &sample_text, &result, error) == MASK_SIZE
}

// nonce_of gives the nonce of a packet: the iv with the packet number in its
// last 8 bytes, by exclusive or (RFC 9001, section 5.3).
@(private)
nonce_of :: proc "contextless" (keys: ^Packet_Keys, packet_number: u64) -> (nonce: [IV_SIZE]u8) {
	nonce = keys.iv
	for index in 0 ..< 8 {
		nonce[IV_SIZE - 1 - index] ~= u8(packet_number >> (8 * uint(index)))
	}
	return
}

@(private)
keys_usable :: proc "contextless" (keys: ^Packet_Keys, error: ^errors.Error_Record) -> bool {
	if keys.suite != .Aes_128_Gcm_Sha256 && keys.suite != .ChaCha20_Poly1305_Sha256 {
		return fail_at(error, .Bad_Value, 2, int(keys.suite))
	}
	return true
}

// header_protection_remove removes header protection from a packet whose
// header header_read read, in the private copy of its datagram, and gives
// the packet number and the key phase. Only the header protection key of
// keys is used: it does not change at a key update (RFC 9001, section 6.1),
// so the caller chooses the keys of the payload from the key phase after
// this call. largest_packet_number is the largest number that was opened in
// the packet number space of the packet. The removal is in place and is done
// once for each packet: a second removal would mask the header again.
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

// packet_payload_open opens the frames of a packet whose header protection
// header_protection_remove removed, with the keys that the caller chose: the
// frames are decrypted in place. A packet whose tag does not verify gives
// Not_Authentic, and the module erased the bytes of its frames: the packet
// cannot be opened again from this copy, with these keys or others. Reserved
// bits that are not 0 after the open give Bad_Value (RFC 9000, section 17.2:
// a PROTOCOL_VIOLATION); they are checked only after the open, so that a
// packet that is not authentic cannot cause a close.
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

// packet_open removes header protection and opens the frames with one set
// of keys: the packets of a long header, which have no key phase. A short
// header of a connection that answers key updates goes through
// header_protection_remove and packet_payload_open, with the keys of its key
// phase. A failure leaves the frames erased (packet_payload_open).
packet_open :: proc "contextless" (cryptography: ^Cryptography, keys: ^Packet_Keys, datagram: []u8, header: ^Packet_Header, largest_packet_number: u64, opened: ^Opened_Packet, error: ^errors.Error_Record) -> bool {
	opened^ = {}
	unprotected: Unprotected_Header
	if !header_protection_remove(cryptography, keys, datagram, header, largest_packet_number, &unprotected, error) {
		return false
	}
	return packet_payload_open(cryptography, keys, datagram, header, &unprotected, opened, error)
}

// packet_seal protects a packet that the caller wrote in private memory: its
// header without protection (the first byte with the fixed bit and the
// length of the packet number in its 2 low bits; for a long header, the
// Length that counts the packet number, the frames and the tag), room for
// the packet number, then payload_length bytes of frames, then room for the
// tag of 16 bytes. It writes the packet number, truncated to the length that
// the first byte gives, encrypts the frames in place, appends the tag and
// applies header protection. The packet number and the frames together must
// have 4 bytes at least, so that the sample fits (RFC 9001, section 5.4.2):
// the caller adds PADDING frames. A long header whose Length does not end
// the packet after the tag, or whose packet number is not at
// packet_number_offset, is refused (Bad_Value, argument 3): the peer could
// not open it, and the loss would be silent. It gives the byte after the
// packet.
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

// retry_integrity_check says if the tag at the end of a Retry packet is the
// tag of the packet for the original Destination Connection ID that the
// client sent: Not_Authentic if not.
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
