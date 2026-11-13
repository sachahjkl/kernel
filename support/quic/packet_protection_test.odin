#+build !freestanding
// The packet protection of QUIC version 1 on the host, against RFC 9001,
// appendix A, and RFC 9000, appendix A, with hostile datagrams. The library
// calls the procedures of the module package `cryptography` itself, so the
// tests run the code that the module ships.
package quic

import "contract:errors"
import "core:encoding/hex"
import "core:testing"
import cryptography_module "../../modules/cryptography"

// The values of RFC 9001, appendix A. A script that is not in the
// repository copied each value from the text of the RFC (no value was typed
// by hand); each line names its appendix.
LABEL_CLIENT_IN :: "00200f746c73313320636c69656e7420696e00" // RFC 9001, appendix A.1.
LABEL_SERVER_IN :: "00200f746c7331332073657276657220696e00" // RFC 9001, appendix A.1.
LABEL_QUIC_KEY :: "00100e746c7331332071756963206b657900" // RFC 9001, appendix A.1.
LABEL_QUIC_IV :: "000c0d746c733133207175696320697600" // RFC 9001, appendix A.1.
LABEL_QUIC_HP :: "00100d746c733133207175696320687000" // RFC 9001, appendix A.1.
INITIAL_SECRET :: "7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44" // RFC 9001, appendix A.1.
CLIENT_INITIAL_SECRET :: "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea" // RFC 9001, appendix A.1.
CLIENT_KEY :: "1f369613dd76d5467730efcbe3b1a22d" // RFC 9001, appendix A.1.
CLIENT_IV :: "fa044b2f42a3fd3b46fb255c" // RFC 9001, appendix A.1.
CLIENT_HP :: "9f50449e04a0e810283a1e9933adedd2" // RFC 9001, appendix A.1.
SERVER_INITIAL_SECRET :: "3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b" // RFC 9001, appendix A.1.
SERVER_KEY :: "cf3a5331653c364c88f0f379b6067e37" // RFC 9001, appendix A.1.
SERVER_IV :: "0ac1493ca1905853b0bba03e" // RFC 9001, appendix A.1.
SERVER_HP :: "c206b8d9b9f0f37644430b490eeaa314" // RFC 9001, appendix A.1.
CLIENT_CRYPTO_FRAME :: "060040f1010000ed0303ebf8fa56f12939b9584a3896472ec40bb863cfd3e86804fe3a47f06a2b69484c00000413011302010000c000000010000e00000b6578616d706c652e636f6dff01000100000a00080006001d0017001800100007000504616c706e000500050100000000003300260024001d00209370b2c9caa47fbabaf4559fedba753de171fa71f50f1ce15d43e994ec74d748002b0003020304000d0010000e0403050306030203080408050806002d00020101001c00024001003900320408ffffffffffffffff05048000ffff07048000ffff0801100104800075300901100f088394c8f03e51570806048000ffff" // RFC 9001, appendix A.2.
CLIENT_UNPROTECTED_HEADER :: "c300000001088394c8f03e5157080000449e00000002" // RFC 9001, appendix A.2.
CLIENT_SAMPLE :: "d1b1c98dd7689fb8ec11d242b123dc9b" // RFC 9001, appendix A.2.
CLIENT_MASK :: "437b9aec36" // RFC 9001, appendix A.2.
CLIENT_PROTECTED_HEADER :: "c000000001088394c8f03e5157080000449e7b9aec34" // RFC 9001, appendix A.2.
CLIENT_PACKET :: "c000000001088394c8f03e5157080000449e7b9aec34d1b1c98dd7689fb8ec11d242b123dc9bd8bab936b47d92ec356c0bab7df5976d27cd449f63300099f3991c260ec4c60d17b31f8429157bb35a1282a643a8d2262cad67500cadb8e7378c8eb7539ec4d4905fed1bee1fc8aafba17c750e2c7ace01e6005f80fcb7df621230c83711b39343fa028cea7f7fb5ff89eac2308249a02252155e2347b63d58c5457afd84d05dfffdb20392844ae812154682e9cf012f9021a6f0be17ddd0c2084dce25ff9b06cde535d0f920a2db1bf362c23e596d11a4f5a6cf3948838a3aec4e15daf8500a6ef69ec4e3feb6b1d98e610ac8b7ec3faf6ad760b7bad1db4ba3485e8a94dc250ae3fdb41ed15fb6a8e5eba0fc3dd60bc8e30c5c4287e53805db059ae0648db2f64264ed5e39be2e20d82df566da8dd5998ccabdae053060ae6c7b4378e846d29f37ed7b4ea9ec5d82e7961b7f25a9323851f681d582363aa5f89937f5a67258bf63ad6f1a0b1d96dbd4faddfcefc5266ba6611722395c906556be52afe3f565636ad1b17d508b73d8743eeb524be22b3dcbc2c7468d54119c7468449a13d8e3b95811a198f3491de3e7fe942b330407abf82a4ed7c1b311663ac69890f4157015853d91e923037c227a33cdd5ec281ca3f79c44546b9d90ca00f064c99e3dd97911d39fe9c5d0b23a229a234cb36186c4819e8b9c5927726632291d6a418211cc2962e20fe47feb3edf330f2c603a9d48c0fcb5699dbfe5896425c5bac4aee82e57a85aaf4e2513e4f05796b07ba2ee47d80506f8d2c25e50fd14de71e6c418559302f939b0e1abd576f279c4b2e0feb85c1f28ff18f58891ffef132eef2fa09346aee33c28eb130ff28f5b766953334113211996d20011a198e3fc433f9f2541010ae17c1bf202580f6047472fb36857fe843b19f5984009ddc324044e847a4f4a0ab34f719595de37252d6235365e9b84392b061085349d73203a4a13e96f5432ec0fd4a1ee65accdd5e3904df54c1da510b0ff20dcc0c77fcb2c0e0eb605cb0504db87632cf3d8b4dae6e705769d1de354270123cb11450efc60ac47683d7b8d0f811365565fd98c4c8eb936bcab8d069fc33bd801b03adea2e1fbc5aa463d08ca19896d2bf59a071b851e6c239052172f296bfb5e72404790a2181014f3b94a4e97d117b438130368cc39dbb2d198065ae3986547926cd2162f40a29f0c3c8745c0f50fba3852e566d44575c29d39a03f0cda721984b6f440591f355e12d439ff150aab7613499dbd49adabc8676eef023b15b65bfc5ca06948109f23f350db82123535eb8a7433bdabcb909271a6ecbcb58b936a88cd4e8f2e6ff5800175f113253d8fa9ca8885c2f552e657dc603f252e1a8e308f76f0be79e2fb8f5d5fbbe2e30ecadd220723c8c0aea8078cdfcb3868263ff8f0940054da48781893a7e49ad5aff4af300cd804a6b6279ab3ff3afb64491c85194aab760d58a606654f9f4400e8b38591356fbf6425aca26dc85244259ff2b19c41b9f96f3ca9ec1dde434da7d2d392b905ddf3d1f9af93d1af5950bd493f5aa731b4056df31bd267b6b90a079831aaf579be0a39013137aac6d404f518cfd46840647e78bfe706ca4cf5e9c5453e9f7cfd2b8b4c8d169a44e55c88d4a9a7f9474241e221af44860018ab0856972e194cd934" // RFC 9001, appendix A.2.
SERVER_PAYLOAD :: "02000000000600405a020000560303eefce7f7b37ba1d1632e96677825ddf73988cfc79825df566dc5430b9a045a1200130100002e00330024001d00209d3c940d89690b84d08a60993c144eca684d1081287c834d5311bcf32bb9da1a002b00020304" // RFC 9001, appendix A.3.
SERVER_UNPROTECTED_HEADER :: "c1000000010008f067a5502a4262b50040750001" // RFC 9001, appendix A.3.
SERVER_SAMPLE :: "2cd0991cd25b0aac406a5816b6394100" // RFC 9001, appendix A.3.
SERVER_MASK :: "2ec0d8356a" // RFC 9001, appendix A.3.
SERVER_PROTECTED_HEADER :: "cf000000010008f067a5502a4262b5004075c0d9" // RFC 9001, appendix A.3.
SERVER_PACKET :: "cf000000010008f067a5502a4262b5004075c0d95a482cd0991cd25b0aac406a5816b6394100f37a1c69797554780bb38cc5a99f5ede4cf73c3ec2493a1839b3dbcba3f6ea46c5b7684df3548e7ddeb9c3bf9c73cc3f3bded74b562bfb19fb84022f8ef4cdd93795d77d06edbb7aaf2f58891850abbdca3d20398c276456cbc42158407dd074ee" // RFC 9001, appendix A.3.
RETRY_PACKET :: "ff000000010008f067a5502a4262b5746f6b656e04a265ba2eff4d829058fb3f0f2496ba" // RFC 9001, appendix A.4.
SHORT_SECRET :: "9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b" // RFC 9001, appendix A.5.
SHORT_KEY :: "c6d98ff3441c3fe1b2182094f69caa2ed4b716b65488960a7a984979fb23e1c8" // RFC 9001, appendix A.5.
SHORT_IV :: "e0459b3474bdd0e44a41c144" // RFC 9001, appendix A.5.
SHORT_HP :: "25a282b9e82f06f21f488917a4fc8f1b73573685608597d0efcb076b0ab7a7a4" // RFC 9001, appendix A.5.
SHORT_NONCE :: "e0459b3474bdd0e46d417eb0" // RFC 9001, appendix A.5.
SHORT_UNPROTECTED_HEADER :: "4200bff4" // RFC 9001, appendix A.5.
SHORT_PAYLOAD :: "01" // RFC 9001, appendix A.5.
SHORT_CIPHERTEXT :: "655e5cd55c41f69080575d7999c25a5bfb" // RFC 9001, appendix A.5.
SHORT_SAMPLE :: "5e5cd55c41f69080575d7999c25a5bfb" // RFC 9001, appendix A.5.
SHORT_MASK :: "aefefe7d03" // RFC 9001, appendix A.5.
SHORT_PROTECTED_HEADER :: "4cfe4189" // RFC 9001, appendix A.5.
SHORT_PACKET :: "4cfe4189655e5cd55c41f69080575d7999c25a5bfb" // RFC 9001, appendix A.5.

ORIGINAL_DESTINATION_CONNECTION_ID :: "8394c8f03e515708" // RFC 9001, appendix A: the connection identifier that the client chose.
SHORT_PACKET_NUMBER :: 654360564 // RFC 9001, appendix A.5.
CLIENT_PAYLOAD_LENGTH :: 1162 // RFC 9001, appendix A.2: the CRYPTO frame and PADDING frames.

bytes_of :: proc(text: string) -> []u8 {
	bytes, ok := hex.decode(transmute([]u8)text, context.temp_allocator)
	assert(ok, text)
	return bytes
}

hex_of :: proc(bytes: []u8) -> string {
	return string(hex.encode(bytes, context.temp_allocator))
}

// The procedures of the module, as a program fills the seam from its
// import slots.
module_cryptography :: proc() -> Cryptography {
	return {
		seal_with_aes_128_gcm                = cryptography_module.seal_with_aes_128_gcm,
		open_with_aes_128_gcm                = cryptography_module.open_with_aes_128_gcm,
		seal_with_chacha20_poly1305          = cryptography_module.seal_with_chacha20_poly1305,
		open_with_chacha20_poly1305          = cryptography_module.open_with_chacha20_poly1305,
		hkdf_sha256_extract                  = cryptography_module.hkdf_sha256_extract,
		hkdf_sha256_expand                   = cryptography_module.hkdf_sha256_expand,
		header_protection_mask_with_aes_128  = cryptography_module.header_protection_mask_with_aes_128,
		header_protection_mask_with_chacha20 = cryptography_module.header_protection_mask_with_chacha20,
		sha256                               = cryptography_module.sha256,
		hmac_sha256                          = cryptography_module.hmac_sha256,
		x25519                               = cryptography_module.x25519_export,
		ed25519_public_key                   = cryptography_module.ed25519_public_key,
		ed25519_sign                         = cryptography_module.ed25519_sign,
		ed25519_verify                       = cryptography_module.ed25519_verify,
	}
}

// RFC 9001, appendix A.1: the HkdfLabel of each label, the initial secret,
// and the secrets and keys of the client and of the server.
@(test)
initial_keys_of_rfc_9001_appendix_a_1 :: proc(t: ^testing.T) {
	Label :: struct {
		label:    string,
		length:   int,
		expected: string,
	}
	labels := []Label{{"client in", 32, LABEL_CLIENT_IN}, {"server in", 32, LABEL_SERVER_IN}, {"quic key", 16, LABEL_QUIC_KEY}, {"quic iv", 12, LABEL_QUIC_IV}, {"quic hp", 16, LABEL_QUIC_HP}}
	for item in labels {
		buffer: [HKDF_LABEL_LIMIT]u8
		testing.expect_value(t, hex_of(hkdf_label_write(&buffer, item.label, item.length)), item.expected)
	}
	cryptography := module_cryptography()
	error: errors.Error_Record
	secrets: Initial_Secrets
	testing.expect(t, initial_secrets(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &secrets, &error))
	testing.expect_value(t, hex_of(secrets.initial[:]), INITIAL_SECRET)
	testing.expect_value(t, hex_of(secrets.client[:]), CLIENT_INITIAL_SECRET)
	testing.expect_value(t, hex_of(secrets.server[:]), SERVER_INITIAL_SECRET)
	client, server: Packet_Keys
	testing.expect(t, initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error))
	testing.expect_value(t, hex_of(client.key[:16]), CLIENT_KEY)
	testing.expect_value(t, hex_of(client.iv[:]), CLIENT_IV)
	testing.expect_value(t, hex_of(client.header_protection_key[:16]), CLIENT_HP)
	testing.expect_value(t, hex_of(server.key[:16]), SERVER_KEY)
	testing.expect_value(t, hex_of(server.iv[:]), SERVER_IV)
	testing.expect_value(t, hex_of(server.header_protection_key[:16]), SERVER_HP)
	testing.expect_value(t, client.suite, Cipher_Suite.Aes_128_Gcm_Sha256)
}

// The masks of the module for the samples of appendices A.2, A.3 and A.5.
@(test)
header_protection_masks_of_rfc_9001 :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	Case :: struct {
		procedure:     Mask_Procedure,
		key, sample:   string,
		expected_mask: string,
	}
	cases := []Case{{cryptography.header_protection_mask_with_aes_128, CLIENT_HP, CLIENT_SAMPLE, CLIENT_MASK}, {cryptography.header_protection_mask_with_aes_128, SERVER_HP, SERVER_SAMPLE, SERVER_MASK}, {cryptography.header_protection_mask_with_chacha20, SHORT_HP, SHORT_SAMPLE, SHORT_MASK}}
	for item in cases {
		key, sample := string(bytes_of(item.key)), string(bytes_of(item.sample))
		mask: [MASK_SIZE]u8
		result := mask[:]
		testing.expect_value(t, item.procedure(&key, &sample, &result, &error), MASK_SIZE)
		testing.expect_value(t, hex_of(mask[:]), item.expected_mask)
	}
}

// seal_and_compare writes a header without protection and a payload in
// private memory, seals it, and compares it with the packet of the RFC.
seal_and_compare :: proc(t: ^testing.T, cryptography: ^Cryptography, keys: ^Packet_Keys, unprotected_header: string, payload: []u8, packet_number: u64, expected_packet: string) {
	header := bytes_of(unprotected_header)
	number_length := int(header[0] & 0x03) + 1
	packet := make([]u8, len(header) + len(payload) + TAG_SIZE, context.temp_allocator)
	copy(packet, header)
	copy(packet[len(header):], payload)
	error: errors.Error_Record
	end, ok := packet_seal(cryptography, keys, packet, 0, len(header) - number_length, len(payload), packet_number, &error)
	testing.expectf(t, ok, "seal: %v", error)
	testing.expect_value(t, end, len(packet))
	testing.expect_value(t, hex_of(packet), expected_packet)
}

// open_and_compare takes the packet of the RFC as a datagram from the
// network, reads its header and opens it.
open_and_compare :: proc(t: ^testing.T, cryptography: ^Cryptography, keys: ^Packet_Keys, packet_text: string, short_destination_length: int, largest_packet_number: u64, expected_type: Packet_Type, expected_packet_number: u64, expected_payload: []u8) {
	private_memory: [DATAGRAM_LIMIT]u8
	error: errors.Error_Record
	datagram, taken := datagram_take(bytes_of(packet_text), private_memory[:], &error)
	testing.expect(t, taken)
	header: Packet_Header
	testing.expectf(t, header_read(datagram, 0, short_destination_length, &header, &error), "header: %v", error)
	testing.expect_value(t, header.type, expected_type)
	testing.expect_value(t, header.end, len(datagram))
	opened: Opened_Packet
	testing.expectf(t, packet_open(cryptography, keys, datagram, &header, largest_packet_number, &opened, &error), "open: %v", error)
	testing.expect_value(t, opened.packet_number, expected_packet_number)
	testing.expect_value(t, hex_of(datagram[opened.payload_offset:][:opened.payload_length]), hex_of(expected_payload))
}

client_payload :: proc() -> []u8 {
	payload := make([]u8, CLIENT_PAYLOAD_LENGTH, context.temp_allocator)
	copy(payload, bytes_of(CLIENT_CRYPTO_FRAME)) // Then PADDING frames: zeros.
	return payload
}

// RFC 9001, appendix A.2: the client Initial, sealed and opened.
@(test)
client_initial_of_rfc_9001_appendix_a_2 :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	client, server: Packet_Keys
	error: errors.Error_Record
	testing.expect(t, initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error))
	seal_and_compare(t, &cryptography, &client, CLIENT_UNPROTECTED_HEADER, client_payload(), 2, CLIENT_PACKET)
	client_packet, client_protected_header := CLIENT_PACKET, CLIENT_PROTECTED_HEADER
	testing.expect_value(t, client_packet[:len(client_protected_header)], client_protected_header)
	open_and_compare(t, &cryptography, &client, CLIENT_PACKET, 0, 0, .Initial, 2, client_payload())
}

// RFC 9001, appendix A.3: the server Initial, sealed and opened.
@(test)
server_initial_of_rfc_9001_appendix_a_3 :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	client, server: Packet_Keys
	error: errors.Error_Record
	testing.expect(t, initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error))
	seal_and_compare(t, &cryptography, &server, SERVER_UNPROTECTED_HEADER, bytes_of(SERVER_PAYLOAD), 1, SERVER_PACKET)
	server_packet, server_protected_header := SERVER_PACKET, SERVER_PROTECTED_HEADER
	testing.expect_value(t, server_packet[:len(server_protected_header)], server_protected_header)
	open_and_compare(t, &cryptography, &server, SERVER_PACKET, 0, 0, .Initial, 1, bytes_of(SERVER_PAYLOAD))
}

// RFC 9001, appendix A.4: the Retry packet and its integrity tag; a changed
// byte gives Not_Authentic.
@(test)
retry_of_rfc_9001_appendix_a_4 :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	private_memory: [DATAGRAM_LIMIT]u8
	datagram, _ := datagram_take(bytes_of(RETRY_PACKET), private_memory[:], &error)
	header: Packet_Header
	testing.expect(t, header_read(datagram, 0, 0, &header, &error))
	testing.expect_value(t, header.type, Packet_Type.Retry)
	testing.expect_value(t, string(datagram[header.token_offset:][:header.token_length]), "token")
	testing.expectf(t, retry_integrity_check(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), datagram, &header, &error), "%v", error)
	for index in 0 ..< len(datagram) {
		datagram[index] ~= 0x01
		changed: Packet_Header
		if header_read(datagram, 0, 0, &changed, &error) && changed.type == .Retry {
			testing.expectf(t, !retry_integrity_check(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), datagram, &changed, &error), "a change of the byte %d was not refused", index)
		}
		datagram[index] ~= 0x01
	}
	other := bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID)
	other[0] ~= 1
	testing.expect(t, !retry_integrity_check(&cryptography, other, datagram, &header, &error) && error.kind == i64(errors.Kind.Not_Authentic))
}

// RFC 9001, appendix A.5: the keys of ChaCha20-Poly1305 from a secret, the
// nonce, and the short header packet, sealed and opened.
@(test)
short_header_of_rfc_9001_appendix_a_5 :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	keys: Packet_Keys
	testing.expect(t, packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &keys, &error))
	testing.expect_value(t, hex_of(keys.key[:32]), SHORT_KEY)
	testing.expect_value(t, hex_of(keys.iv[:]), SHORT_IV)
	testing.expect_value(t, hex_of(keys.header_protection_key[:32]), SHORT_HP)
	nonce := nonce_of(&keys, SHORT_PACKET_NUMBER)
	testing.expect_value(t, hex_of(nonce[:]), SHORT_NONCE)
	seal_and_compare(t, &cryptography, &keys, SHORT_UNPROTECTED_HEADER, bytes_of(SHORT_PAYLOAD), SHORT_PACKET_NUMBER, SHORT_PACKET)
	short_packet, short_protected_header := SHORT_PACKET, SHORT_PROTECTED_HEADER
	testing.expect_value(t, short_packet[len(short_protected_header):], SHORT_CIPHERTEXT)
	testing.expect_value(t, short_packet[:len(short_protected_header)], short_protected_header)
	open_and_compare(t, &cryptography, &keys, SHORT_PACKET, 0, SHORT_PACKET_NUMBER - 1, .One_Rtt, SHORT_PACKET_NUMBER, bytes_of(SHORT_PAYLOAD))
}

// RFC 9000, appendix A.1: the variable-length integers, and each size of
// the encoding.
@(test)
variable_length_integers_of_rfc_9000 :: proc(t: ^testing.T) {
	Case :: struct {
		encoded: string,
		value:   u64,
	}
	cases := []Case{{"c2197c5eff14e88c", 151_288_809_941_952_652}, {"9d7f3e7d", 494_878_333}, {"7bbd", 15_293}, {"25", 37}, {"4025", 37}}
	for item in cases {
		bytes := bytes_of(item.encoded)
		value, size, ok := variable_length_integer_read(bytes, 0)
		testing.expect(t, ok)
		testing.expect_value(t, value, item.value)
		testing.expect_value(t, size, len(bytes))
		written: [8]u8
		testing.expect_value(t, variable_length_integer_write(written[:], 0, item.value, len(bytes)), len(bytes))
		testing.expect_value(t, hex_of(written[:len(bytes)]), item.encoded)
		// The same bytes with one less: nothing is read past the end.
		_, _, short_ok := variable_length_integer_read(bytes[:len(bytes) - 1], 0)
		testing.expect(t, !short_ok)
	}
	testing.expect_value(t, variable_length_integer_size(VARIABLE_LENGTH_INTEGER_LARGEST), 8)
	testing.expect_value(t, variable_length_integer_size(VARIABLE_LENGTH_INTEGER_LARGEST + 1), 0)
	bytes: [8]u8
	testing.expect_value(t, variable_length_integer_write(bytes[:], 0, 64, 1), 0) // 64 needs 2 bytes.
	testing.expect_value(t, variable_length_integer_write(bytes[:], 4, 1, 8), 0) // No room.
}

// RFC 9000, appendices A.2 and A.3: the size of a packet number on the
// wire, and its decoding.
@(test)
packet_numbers_of_rfc_9000 :: proc(t: ^testing.T) {
	testing.expect_value(t, packet_number_encoded_size(0xac5c02, 0xabe8b3, true), 2)
	testing.expect_value(t, packet_number_encoded_size(0xace8fe, 0xabe8b3, true), 3)
	testing.expect_value(t, packet_number_encoded_size(0, 0, false), 1)
	testing.expect_value(t, packet_number_decode(0xa82f30ea, 0x9b32, 16), 0xa82f9b32)
	// A number near the start does not wrap below 0.
	testing.expect_value(t, packet_number_decode(0, 0xff, 8), 0xff)
	testing.expect_value(t, packet_number_decode(0, 2, 32), 2)
}

// Every packet of the RFC, cut at each length: no shorter datagram opens,
// and nothing traps.
@(test)
truncated_datagrams_never_open :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	client, server, short: Packet_Keys
	initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error)
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &short, &error)
	Case :: struct {
		packet: string,
		keys:   ^Packet_Keys,
	}
	cases := []Case{{CLIENT_PACKET, &client}, {SERVER_PACKET, &server}, {SHORT_PACKET, &short}}
	for item in cases {
		whole := bytes_of(item.packet)
		for length in 0 ..< len(whole) {
			private_memory: [DATAGRAM_LIMIT]u8
			datagram, _ := datagram_take(whole[:length], private_memory[:], &error)
			header: Packet_Header
			if !header_read(datagram, 0, 0, &header, &error) || header.packet_number_offset == 0 {
				continue
			}
			opened: Opened_Packet
			testing.expectf(t, !packet_open(&cryptography, item.keys, datagram, &header, SHORT_PACKET_NUMBER - 1, &opened, &error), "a datagram of %d of %d bytes opened", length, len(whole))
		}
	}
}

// A Length past the end of the datagram, a token length past the end, and
// a connection identifier over 20 bytes are refused before a byte is read.
@(test)
lengths_that_lie_are_refused :: proc(t: ^testing.T) {
	error: errors.Error_Record
	private_memory: [DATAGRAM_LIMIT]u8
	datagram, _ := datagram_take(bytes_of(CLIENT_PACKET), private_memory[:], &error)
	header: Packet_Header
	// The Length is the varint at bytes 16 and 17 (0x449e, 1182).
	datagram[16], datagram[17] = 0x7F, 0xFF
	testing.expect(t, !header_read(datagram, 0, 0, &header, &error) && error.kind == i64(errors.Kind.Out_Of_Range))
	datagram[16], datagram[17] = 0x44, 0x9e
	// The token length (byte 15, 0) as the largest value of 8 bytes.
	saved := datagram[15]
	datagram[15] = 0xFF
	testing.expect(t, !header_read(datagram, 0, 0, &header, &error))
	datagram[15] = saved
	// A Destination Connection ID length of 21.
	datagram[5] = 21
	testing.expect(t, !header_read(datagram, 0, 0, &header, &error) && error.kind == i64(errors.Kind.Too_Long))
	datagram[5] = 8
	// A fixed bit of 0.
	datagram[0] ~= FIXED_BIT
	testing.expect(t, !header_read(datagram, 0, 0, &header, &error))
	datagram[0] ~= FIXED_BIT
	testing.expect(t, header_read(datagram, 0, 0, &header, &error))
	// A packet too short for the sample: a Length of 19.
	datagram[16], datagram[17] = 0x40, 19
	testing.expect(t, !header_read(datagram, 0, 0, &header, &error) && error.kind == i64(errors.Kind.Too_Small))
	// A datagram over the limit is not taken.
	large := make([]u8, DATAGRAM_LIMIT + 1, context.temp_allocator)
	_, taken := datagram_take(large, private_memory[:], &error)
	testing.expect(t, !taken)
}

// A changed bit of each byte of each packet of the RFC is refused: the
// header is the additional data of the AEAD once its protection is removed,
// and a change of the packet number length (the 2 low bits of the first
// byte, under header protection) moves the payload. Two bits of each byte:
// the lowest and the highest.
@(test)
each_changed_byte_is_refused :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	client, server, short: Packet_Keys
	initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error)
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &short, &error)
	Case :: struct {
		packet: string,
		keys:   ^Packet_Keys,
	}
	cases := []Case{{CLIENT_PACKET, &client}, {SERVER_PACKET, &server}, {SHORT_PACKET, &short}}
	for item in cases {
		whole := bytes_of(item.packet)
		for index in 0 ..< len(whole) {
			for bit in ([]u8{0x01, 0x80}) {
				private_memory: [DATAGRAM_LIMIT]u8
				datagram, _ := datagram_take(whole, private_memory[:], &error)
				datagram[index] ~= bit
				header: Packet_Header
				if !header_read(datagram, 0, 0, &header, &error) || header.packet_number_offset == 0 {
					continue
				}
				opened: Opened_Packet
				testing.expectf(t, !packet_open(&cryptography, item.keys, datagram, &header, SHORT_PACKET_NUMBER - 1, &opened, &error), "a change of the bit %x of the byte %d of a packet of %d bytes opened", bit, index, len(whole))
			}
		}
	}
}

// 50 000 random datagrams for each of two sets of keys (the Initial keys of
// AES-128-GCM, the ChaCha20-Poly1305 keys of appendix A.5): none traps, and
// none opens. A third of them start as a long header of version 1, a third as
// a short header, so that the reading goes past the first fields; one in
// five has a sample that starts with ff ff ff ff, the last block of the
// ChaCha20 stream.
@(test)
random_datagrams_never_trap_and_never_open :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	client, server, short: Packet_Keys
	initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error)
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &short, &error)
	// A generator of the test, with a fixed seed: each run reads the same
	// datagrams (xorshift64).
	state: u64 = 0x5155_4943_2026_0001
	next :: proc(state: ^u64) -> u64 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		return state^
	}
	for keys in ([]^Packet_Keys{&client, &short}) {
		read, opened_count, last_block_count := 0, 0, 0
		for round in 0 ..< 50_000 {
			private_memory: [DATAGRAM_LIMIT]u8
			length := int(next(&state) % 1300)
			for index in 0 ..< length {
				private_memory[index] = u8(next(&state))
			}
			if round % 3 == 0 && length >= 7 {
				private_memory[0] = 0xC0 | (private_memory[0] & 0x3F)
				private_memory[1], private_memory[2], private_memory[3], private_memory[4] = 0, 0, 0, 1
				private_memory[5] = u8(next(&state) % 24)
			} else if round % 3 == 1 && length >= 1 {
				private_memory[0] = 0x40 | (private_memory[0] & 0x3F)
			}
			datagram := private_memory[:length]
			header: Packet_Header
			if !header_read(datagram, 0, int(next(&state) % 21), &header, &error) {
				continue
			}
			read += 1
			testing.expect(t, header.end <= len(datagram) && header.packet_number_offset <= header.end)
			if header.packet_number_offset == 0 {
				continue
			}
			if round % 5 == 0 {
				for index in 0 ..< 4 {
					datagram[header.packet_number_offset + 4 + index] = 0xFF
				}
				last_block_count += 1
			}
			opened: Opened_Packet
			if packet_open(&cryptography, keys, datagram, &header, u64(next(&state) % (1 << 40)), &opened, &error) {
				opened_count += 1
			}
		}
		testing.expect_value(t, opened_count, 0)
		testing.expect(t, read > 0, "no random header was read: the test reached nothing past the first fields")
		testing.expect(t, last_block_count > 0)
	}
}

// The header protection of ChaCha20 at the last counter: the first 4 bytes
// of the sample are the counter (RFC 9001, section 5.4.4), and the sender
// chooses them, so ff ff ff ff must give a mask and not stop the program.
// With a key of zeros and the rest of the sample zeros, the mask is the first
// 5 bytes of the block at the counter 0xffffffff, from an independent
// implementation. Then a short packet whose sample starts with ff ff ff ff
// is refused as not authentic.
@(test)
chacha20_mask_at_the_last_counter :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	zero_key: [32]u8
	sample: [SAMPLE_SIZE]u8
	sample[0], sample[1], sample[2], sample[3] = 0xFF, 0xFF, 0xFF, 0xFF
	key, sample_text := string(zero_key[:]), string(sample[:])
	mask: [MASK_SIZE]u8
	result := mask[:]
	testing.expect_value(t, cryptography.header_protection_mask_with_chacha20(&key, &sample_text, &result, &error), MASK_SIZE)
	testing.expect_value(t, hex_of(mask[:]), "ace4cd09e2")

	keys: Packet_Keys
	testing.expect(t, packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &keys, &error))
	private_memory: [DATAGRAM_LIMIT]u8
	datagram, _ := datagram_take(bytes_of(SHORT_PACKET), private_memory[:], &error)
	header: Packet_Header
	testing.expect(t, header_read(datagram, 0, 0, &header, &error))
	for index in 0 ..< 4 {
		datagram[header.packet_number_offset + 4 + index] = 0xFF
	}
	opened: Opened_Packet
	testing.expect(t, !packet_open(&cryptography, &keys, datagram, &header, SHORT_PACKET_NUMBER - 1, &opened, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Not_Authentic))
}

// long_packet_write writes a long header packet of version 1 at start, with
// its frames, and seals it. reserved goes into the 2 reserved bits of the
// first byte. It gives the byte after the packet.
long_packet_write :: proc(cryptography: ^Cryptography, keys: ^Packet_Keys, datagram: []u8, start: int, type: Packet_Type, token: []u8, frames: []u8, packet_number: u64, reserved: u8, error: ^errors.Error_Record) -> (end: int, ok: bool) {
	number_length := 4
	position := start
	datagram[position] = 0xC0 | u8(type) << 4 | reserved << 2 | u8(number_length - 1)
	position += 1
	position += copy(datagram[position:], []u8{0, 0, 0, 1})
	destination := bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID)
	datagram[position] = u8(len(destination))
	position += 1
	position += copy(datagram[position:], destination)
	datagram[position] = 0 // An empty Source Connection ID.
	position += 1
	if type == .Initial {
		position += variable_length_integer_write(datagram, position, u64(len(token)), 2)
		position += copy(datagram[position:], token)
	}
	position += variable_length_integer_write(datagram, position, u64(number_length + len(frames) + TAG_SIZE), 2)
	number_offset := position
	copy(datagram[number_offset + number_length:], frames)
	return packet_seal(cryptography, keys, datagram, start, number_offset, len(frames), packet_number, error)
}

// Two packets in one datagram (RFC 9000, section 12.2): an Initial, then a
// Handshake packet with other keys. Each one opens with its keys. A second
// packet whose Length runs past the datagram is refused, and the first one
// still opens.
@(test)
coalesced_packets :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	client, server, handshake: Packet_Keys
	initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error)
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &handshake, &error)
	frames := []u8{0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00} // PING, then PADDING.
	for lying in ([]bool{false, true}) {
		buffer: [DATAGRAM_LIMIT]u8
		first_end, first_ok := long_packet_write(&cryptography, &client, buffer[:], 0, .Initial, nil, frames, 0, 0, &error)
		testing.expectf(t, first_ok, "%v", error)
		second_end, second_ok := long_packet_write(&cryptography, &handshake, buffer[:], first_end, .Handshake, nil, frames, 0, 0, &error)
		testing.expectf(t, second_ok, "%v", error)
		datagram := buffer[:second_end]
		if lying {
			// The Length of the second packet (2 bytes before its packet
			// number, after 1 + 4 + 1 + 8 + 1 bytes) as 16383.
			length_offset := first_end + 15
			datagram[length_offset], datagram[length_offset + 1] = 0x7F, 0xFF
		}
		header: Packet_Header
		testing.expect(t, header_read(datagram, 0, 0, &header, &error))
		testing.expect_value(t, header.type, Packet_Type.Initial)
		testing.expect_value(t, header.end, first_end)
		opened: Opened_Packet
		testing.expectf(t, packet_open(&cryptography, &client, datagram, &header, 0, &opened, &error), "%v", error)
		testing.expect_value(t, hex_of(datagram[opened.payload_offset:][:opened.payload_length]), hex_of(frames))
		second: Packet_Header
		read := header_read(datagram, header.end, 0, &second, &error)
		if lying {
			testing.expect(t, !read && error.kind == i64(errors.Kind.Out_Of_Range))
			continue
		}
		testing.expect(t, read)
		testing.expect_value(t, second.type, Packet_Type.Handshake)
		testing.expect_value(t, second.end, len(datagram))
		testing.expectf(t, packet_open(&cryptography, &handshake, datagram, &second, 0, &opened, &error), "%v", error)
		testing.expect_value(t, hex_of(datagram[opened.payload_offset:][:opened.payload_length]), hex_of(frames))
	}
}

// An authentic packet whose reserved bits are not 0 is refused after the
// open (Bad_Value), for a long header and for a short header.
@(test)
authentic_packets_with_reserved_bits :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	client, server, short: Packet_Keys
	initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error)
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &short, &error)
	frames := []u8{0x01, 0x00, 0x00, 0x00}
	for reserved in u8(1) ..= 3 {
		buffer: [DATAGRAM_LIMIT]u8
		end, ok := long_packet_write(&cryptography, &client, buffer[:], 0, .Initial, nil, frames, 7, reserved, &error)
		testing.expectf(t, ok, "%v", error)
		header: Packet_Header
		testing.expect(t, header_read(buffer[:end], 0, 0, &header, &error))
		opened: Opened_Packet
		testing.expect(t, !packet_open(&cryptography, &client, buffer[:end], &header, 0, &opened, &error))
		testing.expect_value(t, error.kind, i64(errors.Kind.Bad_Value))
		testing.expect(t, opened.authentic_with_reserved_bits, "the open does not say that the packet is authentic")
	}
	// A short header: the reserved bits are 0x18.
	for reserved in ([]u8{0x08, 0x10}) {
		buffer: [64]u8
		buffer[0] = 0x40 | reserved | 0x03
		copy(buffer[1 + 4:], frames)
		end, ok := packet_seal(&cryptography, &short, buffer[:], 0, 1, len(frames), 9, &error)
		testing.expectf(t, ok, "%v", error)
		header: Packet_Header
		testing.expect(t, header_read(buffer[:end], 0, 0, &header, &error))
		opened: Opened_Packet
		testing.expect(t, !packet_open(&cryptography, &short, buffer[:end], &header, 0, &opened, &error))
		testing.expect_value(t, error.kind, i64(errors.Kind.Bad_Value))
		testing.expect(t, opened.authentic_with_reserved_bits, "the open does not say that the packet is authentic")
	}
}

// short_packet_without_header_protection gives a private copy of the short
// header packet of RFC 9001, appendix A.5, with its header read and its
// header protection removed: the state before `packet_payload_open`.
short_packet_without_header_protection :: proc(module: ^Cryptography, packet_keys: ^Packet_Keys, memory: []u8, read_header: ^Packet_Header, removed: ^Unprotected_Header) -> []u8 {
	problem: errors.Error_Record
	datagram, _ := datagram_take(bytes_of(SHORT_PACKET), memory, &problem)
	header_read(datagram, 0, 0, read_header, &problem)
	header_protection_remove(module, packet_keys, datagram, read_header, SHORT_PACKET_NUMBER - 1, removed, &problem)
	return datagram
}

// Bad_Value alone does not say that a packet is authentic: an open that
// fails with Bad_Value before any tag is checked (offsets that do not fit the
// datagram, keys with no suite) leaves `authentic_with_reserved_bits` false,
// and so does a packet that is not authentic, with its reserved bits set or
// not. Only that field lets a caller close a connection for reserved bits.
// Before the correction the caller told the cases apart by the kind
// Bad_Value, which the first two failures give too.
@(test)
only_an_authentic_packet_is_marked_for_its_reserved_bits :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	keys, other, none: Packet_Keys
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &keys, &error)
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(CLIENT_INITIAL_SECRET), &other, &error)
	private_memory: [DATAGRAM_LIMIT]u8
	header: Packet_Header
	unprotected: Unprotected_Header
	opened: Opened_Packet
	// Offsets that do not fit: Bad_Value before the open.
	datagram := short_packet_without_header_protection(&cryptography, &keys, private_memory[:], &header, &unprotected)
	unprotected.payload_offset = header.end + 1
	opened.authentic_with_reserved_bits = true
	testing.expect(t, !packet_payload_open(&cryptography, &keys, datagram, &header, &unprotected, &opened, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Bad_Value))
	testing.expect(t, !opened.authentic_with_reserved_bits, "a failure before the open marked the packet as authentic")
	// Keys with no suite: Bad_Value before the open.
	datagram = short_packet_without_header_protection(&cryptography, &keys, private_memory[:], &header, &unprotected)
	opened.authentic_with_reserved_bits = true
	testing.expect(t, !packet_payload_open(&cryptography, &none, datagram, &header, &unprotected, &opened, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Bad_Value))
	testing.expect(t, !opened.authentic_with_reserved_bits, "a failure before the open marked the packet as authentic")
	// A packet that is not authentic, with reserved bits set in the header
	// that the removal gave.
	datagram = short_packet_without_header_protection(&cryptography, &keys, private_memory[:], &header, &unprotected)
	unprotected.first_byte |= 0x18
	opened.authentic_with_reserved_bits = true
	testing.expect(t, !packet_payload_open(&cryptography, &other, datagram, &header, &unprotected, &opened, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Not_Authentic))
	testing.expect(t, !opened.authentic_with_reserved_bits, "a packet that is not authentic was marked as authentic")
}

// The seal writes the packet number itself, and refuses a long header whose
// Length does not end the packet after the tag.
@(test)
seal_writes_the_number_and_checks_the_length :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	client, server: Packet_Keys
	initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error)
	// The header of appendix A.2 with a packet number of zeros: the seal
	// writes 2 and gives the packet of the RFC.
	header := bytes_of(CLIENT_UNPROTECTED_HEADER)
	header[len(header) - 1] = 0
	payload := client_payload()
	packet := make([]u8, len(header) + len(payload) + TAG_SIZE, context.temp_allocator)
	copy(packet, header)
	copy(packet[len(header):], payload)
	end, ok := packet_seal(&cryptography, &client, packet, 0, len(header) - 4, len(payload), 2, &error)
	testing.expect(t, ok && end == len(packet))
	testing.expect_value(t, hex_of(packet), CLIENT_PACKET)
	// A Length of one byte less (0x449d) and one byte more (0x449f).
	for wrong in ([]u8{0x9d, 0x9f}) {
		copy(packet, header)
		packet[len(header) - 5] = wrong
		copy(packet[len(header):], payload)
		_, wrong_ok := packet_seal(&cryptography, &client, packet, 0, len(header) - 4, len(payload), 2, &error)
		testing.expect(t, !wrong_ok && error.kind == i64(errors.Kind.Bad_Value))
	}
	// A packet number past the largest.
	copy(packet, header)
	_, large_ok := packet_seal(&cryptography, &client, packet, 0, len(header) - 4, len(payload), PACKET_NUMBER_LARGEST + 1, &error)
	testing.expect(t, !large_ok && error.kind == i64(errors.Kind.Out_Of_Range))
}

// The removal of header protection gives the key phase before the open, so
// that the caller chooses the keys. A failed open erases the frames.
@(test)
header_protection_removal_then_open :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	keys, other: Packet_Keys
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(SHORT_SECRET), &keys, &error)
	packet_keys_from_secret(&cryptography, .ChaCha20_Poly1305_Sha256, bytes_of(CLIENT_INITIAL_SECRET), &other, &error)
	private_memory: [DATAGRAM_LIMIT]u8
	datagram, _ := datagram_take(bytes_of(SHORT_PACKET), private_memory[:], &error)
	header: Packet_Header
	testing.expect(t, header_read(datagram, 0, 0, &header, &error))
	unprotected: Unprotected_Header
	testing.expect(t, header_protection_remove(&cryptography, &keys, datagram, &header, SHORT_PACKET_NUMBER - 1, &unprotected, &error))
	testing.expect_value(t, unprotected.packet_number, SHORT_PACKET_NUMBER)
	testing.expect_value(t, unprotected.packet_number_length, 3)
	testing.expect_value(t, unprotected.key_phase, false)
	testing.expect_value(t, hex_of(datagram[:unprotected.payload_offset]), SHORT_UNPROTECTED_HEADER)
	opened: Opened_Packet
	testing.expectf(t, packet_payload_open(&cryptography, &keys, datagram, &header, &unprotected, &opened, &error), "%v", error)
	testing.expect_value(t, hex_of(datagram[opened.payload_offset:][:opened.payload_length]), SHORT_PAYLOAD)
	// The same packet, opened with keys of another phase: Not_Authentic,
	// and the sealed frames are erased.
	datagram, _ = datagram_take(bytes_of(SHORT_PACKET), private_memory[:], &error)
	testing.expect(t, header_protection_remove(&cryptography, &keys, datagram, &header, SHORT_PACKET_NUMBER - 1, &unprotected, &error))
	testing.expect(t, !packet_payload_open(&cryptography, &other, datagram, &header, &unprotected, &opened, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Not_Authentic))
	for byte in datagram[unprotected.payload_offset:header.end - TAG_SIZE] {
		testing.expect_value(t, byte, 0)
	}
}

// A Retry with an empty token is refused (RFC 9000, section 17.2.5.2).
// Version 0 is a Version Negotiation, another version is read up to its
// connection identifiers, and a connection identifier over 20 bytes is
// refused for any version: this library does not answer such a header,
// though RFC 8999 allows 255 bytes outside version 1.
@(test)
versions_and_an_empty_retry_token :: proc(t: ^testing.T) {
	error: errors.Error_Record
	header: Packet_Header
	retry := bytes_of(RETRY_PACKET)
	// The Retry of appendix A.4 without its token "token": 5 bytes after
	// the first byte, the version, an empty Destination Connection ID and a
	// Source Connection ID of 8 bytes (from the byte 15).
	empty_token := make([]u8, len(retry) - 5, context.temp_allocator)
	copy(empty_token, retry[:15])
	copy(empty_token[15:], retry[15 + 5:])
	testing.expect(t, !header_read(empty_token, 0, 0, &header, &error) && error.kind == i64(errors.Kind.Empty))
	testing.expect(t, header_read(retry, 0, 0, &header, &error) && header.token_length == 5)

	negotiation := []u8{0x80, 0, 0, 0, 0, 1, 0xAA, 1, 0xBB, 0, 0, 0, 1}
	testing.expect(t, header_read(negotiation, 0, 0, &header, &error))
	testing.expect_value(t, header.type, Packet_Type.Version_Negotiation)
	testing.expect_value(t, header.destination_connection_id_length, 1)
	testing.expect_value(t, header.source_connection_id_length, 1)
	unknown := []u8{0xC0, 0xFF, 0x00, 0x00, 0x1D, 2, 0xAA, 0xAA, 0, 0x99}
	testing.expect(t, header_read(unknown, 0, 0, &header, &error))
	testing.expect_value(t, header.type, Packet_Type.Unknown_Version)
	testing.expect_value(t, header.version, 0xFF00001D)
	for version in ([]u32{0, 0xFF00001D}) {
		long_identifier := make([]u8, 1 + 4 + 1 + 21 + 1, context.temp_allocator)
		long_identifier[0] = 0xC0
		long_identifier[1], long_identifier[2], long_identifier[3], long_identifier[4] = u8(version >> 24), u8(version >> 16), u8(version >> 8), u8(version)
		long_identifier[5] = 21
		testing.expect(t, !header_read(long_identifier, 0, 0, &header, &error) && error.kind == i64(errors.Kind.Too_Long))
	}
}

// packet_number_decode near 2^62: no value wraps, and a number past the
// largest is not made by adding a window.
@(test)
packet_numbers_near_the_largest :: proc(t: ^testing.T) {
	largest := u64(PACKET_NUMBER_LARGEST)
	testing.expect_value(t, packet_number_decode(largest - 1, 0xFF, 8), largest)
	// The expected number is the largest; the truncated 0 is the start of
	// its window, and the next window would pass the largest.
	testing.expect_value(t, packet_number_decode(largest - 1, 0x00, 8), largest + 1 - 256)
	testing.expect_value(t, packet_number_decode(largest - 1, 0x00, 32), largest + 1 - (1 << 32))
	// After the largest, a truncated number below the expected one goes
	// back one window.
	testing.expect_value(t, packet_number_decode(largest, 0xFF, 8), largest)
	for truncated in u64(0) ..< 256 {
		for distance in u64(1) ..< 300 {
			decoded := packet_number_decode(largest - distance, truncated, 8)
			testing.expect(t, decoded <= largest)
			testing.expect_value(t, decoded & 0xFF, truncated)
		}
	}
}

// An Initial packet with the longest token that a datagram of 2048 bytes
// holds: its header (2031 bytes) is the additional data of the AEAD, which
// the module takes.
@(test)
initial_with_the_longest_token :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	client, server: Packet_Keys
	initial_keys(&cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client, &server, &error)
	// 1 + 4 + 1 + 8 + 1 + 2 + token + 2 + 4 + 1 (PING) + 16 = 2048.
	token := make([]u8, DATAGRAM_LIMIT - 40, context.temp_allocator)
	for &byte, index in token {
		byte = u8(index)
	}
	buffer: [DATAGRAM_LIMIT]u8
	end, ok := long_packet_write(&cryptography, &client, buffer[:], 0, .Initial, token, []u8{0x01}, 0, 0, &error)
	testing.expectf(t, ok, "%v", error)
	testing.expect_value(t, end, DATAGRAM_LIMIT)
	header: Packet_Header
	testing.expect(t, header_read(buffer[:end], 0, 0, &header, &error))
	testing.expect_value(t, header.token_length, len(token))
	opened: Opened_Packet
	testing.expectf(t, packet_open(&cryptography, &client, buffer[:end], &header, 0, &opened, &error), "%v", error)
	testing.expect_value(t, opened.payload_length, 1)
}
