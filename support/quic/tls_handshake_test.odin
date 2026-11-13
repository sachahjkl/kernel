#+build !freestanding
// TLS 1.3 for QUIC on the host: the key schedule against the trace "Simple
// 1-RTT Handshake" of RFC 8448 (section 3: X25519, SHA-256), a whole
// handshake of a client against a server in memory, and hostile messages:
// each message cut at each length, each byte changed, messages out of order,
// and 20 000 random messages.
package quic

import "contract:errors"
import "core:testing"
import "support:random"

// The values of RFC 8448, section 3, of RFC 8446, section 4.1.3, and of RFC
// 8410, section 4. A script that is not in the repository copied each value
// from the text of the RFCs, and checked its size (no value was typed by
// hand).
CLIENT_X25519_PRIVATE_KEY :: "49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005" // RFC 8448, section 3.
CLIENT_X25519_PUBLIC_KEY :: "99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c" // RFC 8448, section 3.
CLIENT_HELLO :: "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001" // RFC 8448, section 3.
EARLY_SECRET :: "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a" // RFC 8448, section 3.
SERVER_X25519_PRIVATE_KEY :: "b1580eeadf6dd589b8ef4f2d5652578cc810e9980191ec8d058308cea216a21e" // RFC 8448, section 3.
SERVER_X25519_PUBLIC_KEY :: "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f" // RFC 8448, section 3.
SERVER_HELLO :: "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304" // RFC 8448, section 3.
HASH_OF_NOTHING :: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" // RFC 8448, section 3.
DERIVED_FOR_HANDSHAKE :: "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba" // RFC 8448, section 3.
SHARED_SECRET :: "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d" // RFC 8448, section 3.
HANDSHAKE_SECRET :: "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac" // RFC 8448, section 3.
HASH_OF_HELLOS :: "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8" // RFC 8448, section 3.
INFO_OF_CLIENT_HANDSHAKE_TRAFFIC :: "002012746c7331332063206873207472616666696320860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8" // RFC 8448, section 3.
CLIENT_HANDSHAKE_TRAFFIC_SECRET :: "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21" // RFC 8448, section 3.
SERVER_HANDSHAKE_TRAFFIC_SECRET :: "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38" // RFC 8448, section 3.
DERIVED_FOR_MASTER :: "43de77e0c77713859a944db9db2590b53190a65b3ee2e4f12dd7a0bb7ce254b4" // RFC 8448, section 3.
MASTER_SECRET :: "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919" // RFC 8448, section 3.
ENCRYPTED_EXTENSIONS :: "080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000" // RFC 8448, section 3.
CERTIFICATE :: "0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de10000" // RFC 8448, section 3.
CERTIFICATE_VERIFY :: "0f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3" // RFC 8448, section 3.
SERVER_FINISHED_KEY :: "008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8" // RFC 8448, section 3.
SERVER_FINISHED_VERIFY_DATA :: "9b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718" // RFC 8448, section 3.
SERVER_FINISHED :: "140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718" // RFC 8448, section 3.
HASH_TO_SERVER_FINISHED :: "9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13" // RFC 8448, section 3.
CLIENT_APPLICATION_TRAFFIC_SECRET :: "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5" // RFC 8448, section 3.
SERVER_APPLICATION_TRAFFIC_SECRET :: "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643" // RFC 8448, section 3.
CLIENT_FINISHED_KEY :: "b80ad01015fb2f0bd65ff7d4da5d6bf83f84821d1f87fdc7d3c75b5a7b42d9c4" // RFC 8448, section 3.
CLIENT_FINISHED_VERIFY_DATA :: "a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61" // RFC 8448, section 3.
CLIENT_FINISHED :: "14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61" // RFC 8448, section 3.
// RFC 8446, section 4.1.3: the Random of a HelloRetryRequest.
HELLO_RETRY_REQUEST_RANDOM_OF_THE_RFC :: "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c"
// RFC 8410, section 4 (its PEM example): the 12 bytes of an Ed25519 SubjectPublicKeyInfo before the key.
ED25519_PUBLIC_KEY_INFORMATION_PREFIX_OF_THE_RFC :: "302a300506032b6570032100"

// The two byte arrays of tls_handshake.odin are the values of the RFCs.
@(test)
constants_of_the_handshake_are_those_of_the_rfcs :: proc(t: ^testing.T) {
	testing.expect_value(t, hex_of(HELLO_RETRY_REQUEST_RANDOM[:]), HELLO_RETRY_REQUEST_RANDOM_OF_THE_RFC)
	testing.expect_value(t, hex_of(ED25519_PUBLIC_KEY_INFORMATION_PREFIX[:]), ED25519_PUBLIC_KEY_INFORMATION_PREFIX_OF_THE_RFC)
}

concatenation :: proc(parts: ..string) -> []u8 {
	total := 0
	for part in parts {
		total += len(part) / 2
	}
	bytes := make([]u8, total, context.temp_allocator)
	position := 0
	for part in parts {
		position += copy(bytes[position:], bytes_of(part))
	}
	return bytes
}

hash_of_hex :: proc(cryptography: ^Cryptography, parts: ..string) -> string {
	hash: [HASH_SIZE]u8
	hash_of(cryptography, concatenation(..parts), &hash)
	return hex_of(hash[:])
}

// RFC 8448, section 3: the X25519 exchange, the transcript hashes, each
// secret of the key schedule, the HkdfLabel with a context, and the two
// Finished messages.
@(test)
key_schedule_of_rfc_8448_section_3 :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	shared: [32]u8
	scalar, point := string(bytes_of(CLIENT_X25519_PRIVATE_KEY)), string(bytes_of(SERVER_X25519_PUBLIC_KEY))
	result := shared[:]
	testing.expect_value(t, cryptography.x25519(&scalar, &point, &result, &error), 32)
	testing.expect_value(t, hex_of(shared[:]), SHARED_SECRET)
	scalar, point = string(bytes_of(SERVER_X25519_PRIVATE_KEY)), string(bytes_of(CLIENT_X25519_PUBLIC_KEY))
	testing.expect_value(t, cryptography.x25519(&scalar, &point, &result, &error), 32)
	testing.expect_value(t, hex_of(shared[:]), SHARED_SECRET)
	base_point: [32]u8
	base_point[0] = 9
	scalar, point = string(bytes_of(CLIENT_X25519_PRIVATE_KEY)), string(base_point[:])
	testing.expect_value(t, cryptography.x25519(&scalar, &point, &result, &error), 32)
	testing.expect_value(t, hex_of(shared[:]), CLIENT_X25519_PUBLIC_KEY)

	testing.expect_value(t, hash_of_hex(&cryptography), HASH_OF_NOTHING)
	testing.expect_value(t, hash_of_hex(&cryptography, CLIENT_HELLO, SERVER_HELLO), HASH_OF_HELLOS)
	testing.expect_value(t, hash_of_hex(&cryptography, CLIENT_HELLO, SERVER_HELLO, ENCRYPTED_EXTENSIONS, CERTIFICATE, CERTIFICATE_VERIFY, SERVER_FINISHED), HASH_TO_SERVER_FINISHED)

	buffer: [HKDF_LABEL_WITH_CONTEXT_LIMIT]u8
	testing.expect_value(t, hex_of(hkdf_label_with_context_write(&buffer, "c hs traffic", bytes_of(HASH_OF_HELLOS), 32)), INFO_OF_CLIENT_HANDSHAKE_TRAFFIC)

	schedule: Key_Schedule
	testing.expect(t, key_schedule_handshake(&cryptography, &schedule, bytes_of(SHARED_SECRET), bytes_of(HASH_OF_HELLOS), &error))
	testing.expect_value(t, hex_of(schedule.early[:]), EARLY_SECRET)
	testing.expect_value(t, hex_of(schedule.handshake[:]), HANDSHAKE_SECRET)
	testing.expect_value(t, hex_of(schedule.client_handshake_traffic[:]), CLIENT_HANDSHAKE_TRAFFIC_SECRET)
	testing.expect_value(t, hex_of(schedule.server_handshake_traffic[:]), SERVER_HANDSHAKE_TRAFFIC_SECRET)
	testing.expect_value(t, hex_of(schedule.master[:]), MASTER_SECRET)
	derived: [HASH_SIZE]u8
	testing.expect(t, derive_secret(&cryptography, schedule.early[:], "derived", bytes_of(HASH_OF_NOTHING), &derived, &error))
	testing.expect_value(t, hex_of(derived[:]), DERIVED_FOR_HANDSHAKE)
	testing.expect(t, derive_secret(&cryptography, schedule.handshake[:], "derived", bytes_of(HASH_OF_NOTHING), &derived, &error))
	testing.expect_value(t, hex_of(derived[:]), DERIVED_FOR_MASTER)

	finished_key: [HASH_SIZE]u8
	testing.expect(t, hkdf_expand_label_with_context(&cryptography, schedule.server_handshake_traffic[:], "finished", nil, finished_key[:], &error))
	testing.expect_value(t, hex_of(finished_key[:]), SERVER_FINISHED_KEY)
	testing.expect(t, hkdf_expand_label_with_context(&cryptography, schedule.client_handshake_traffic[:], "finished", nil, finished_key[:], &error))
	testing.expect_value(t, hex_of(finished_key[:]), CLIENT_FINISHED_KEY)
	verify_data: [HASH_SIZE]u8
	hash_to_certificate_verify: [HASH_SIZE]u8
	hash_of(&cryptography, concatenation(CLIENT_HELLO, SERVER_HELLO, ENCRYPTED_EXTENSIONS, CERTIFICATE, CERTIFICATE_VERIFY), &hash_to_certificate_verify)
	testing.expect(t, finished_verify_data(&cryptography, schedule.server_handshake_traffic[:], hash_to_certificate_verify[:], &verify_data, &error))
	testing.expect_value(t, hex_of(verify_data[:]), SERVER_FINISHED_VERIFY_DATA)
	server_finished := SERVER_FINISHED
	testing.expect_value(t, server_finished[8:], SERVER_FINISHED_VERIFY_DATA)
	testing.expect(t, finished_verify_data(&cryptography, schedule.client_handshake_traffic[:], bytes_of(HASH_TO_SERVER_FINISHED), &verify_data, &error))
	testing.expect_value(t, hex_of(verify_data[:]), CLIENT_FINISHED_VERIFY_DATA)
	client_finished := CLIENT_FINISHED
	testing.expect_value(t, client_finished[8:], CLIENT_FINISHED_VERIFY_DATA)

	testing.expect(t, key_schedule_application(&cryptography, &schedule, bytes_of(HASH_TO_SERVER_FINISHED), &error))
	testing.expect_value(t, hex_of(schedule.client_application_traffic[:]), CLIENT_APPLICATION_TRAFFIC_SECRET)
	testing.expect_value(t, hex_of(schedule.server_application_traffic[:]), SERVER_APPLICATION_TRAFFIC_SECRET)
}

// The two sides of a test: their configurations, generators and handshakes.
Test_Pair :: struct {
	cryptography:         Cryptography,
	client_generator:     random.Generator,
	server_generator:     random.Generator,
	client_configuration: Tls_Configuration,
	server_configuration: Tls_Configuration,
	client:               Tls_Handshake,
	server:               Tls_Handshake,
}

// A server key that the test makes: 32 bytes of a fixed pattern.
SERVER_PRIVATE_KEY_OF_THE_TEST :: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

text_into :: proc(destination: []u8, text: string) -> int {
	return copy(destination, text)
}

pair_make :: proc(pair: ^Test_Pair, client_strength: random.Seed_Strength = .Processor, client_protocol := "kernel-remote", pinned_key_change: u8 = 0) {
	pair.cryptography = module_cryptography()
	client_seed, server_seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		client_seed[index] = u8(1 + index)
		server_seed[index] = u8(101 + index)
	}
	random.generator_seed(&pair.client_generator, &client_seed, client_strength)
	random.generator_seed(&pair.server_generator, &server_seed, .Entropy)
	pair.server_configuration = {role = .Server, least_seed_strength = .Processor}
	pair.server_configuration.application_protocol_length = text_into(pair.server_configuration.application_protocol[:], "kernel-remote")
	pair.server_configuration.transport_parameters_length = copy(pair.server_configuration.transport_parameters[:], []u8{0x04, 0x04, 0x80, 0x10, 0x00, 0x00}) // initial_max_data 1 MiB (RFC 9000, section 18.2).
	copy(pair.server_configuration.server_private_key[:], bytes_of(SERVER_PRIVATE_KEY_OF_THE_TEST))
	pair.client_configuration = {role = .Client, least_seed_strength = .Processor}
	pair.client_configuration.application_protocol_length = text_into(pair.client_configuration.application_protocol[:], client_protocol)
	pair.client_configuration.transport_parameters_length = copy(pair.client_configuration.transport_parameters[:], []u8{0x01, 0x02, 0x67, 0x10}) // max_idle_timeout 10 000 ms.
	// The client pins the public key of the server.
	error: errors.Error_Record
	secret := string(pair.server_configuration.server_private_key[:])
	result := pair.client_configuration.server_public_key[:]
	pair.cryptography.ed25519_public_key(&secret, &result, &error)
	pair.client_configuration.server_public_key[0] ~= pinned_key_change
}

// A message that one side sent at a level, in order.
Sent_Message :: struct {
	from_client: bool,
	level:       Encryption_Level,
	bytes:       []u8,
}

// handshake_run carries the bytes of each side to the other, level by
// level, until nothing moves. change, when it is set, may change the bytes
// of one message before they go (the index of the message in the order of
// the run). It gives the messages that went.
handshake_run :: proc(pair: ^Test_Pair, change: proc(index: int, message: []u8) -> []u8 = nil) -> [dynamic]Sent_Message {
	sent := make([dynamic]Sent_Message, context.temp_allocator)
	error: errors.Error_Record
	pair.client.state = .Start
	tls_start(&pair.server, &pair.server_configuration, &pair.cryptography, &pair.server_generator, &error)
	tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error)
	for _ in 0 ..< 16 {
		moved := false
		for from_client in ([]bool{true, false}) {
			sender := from_client ? &pair.client : &pair.server
			receiver := from_client ? &pair.server : &pair.client
			for level in Encryption_Level {
				bytes := tls_bytes_to_send(sender, level)
				// One message at a time, by its header.
				for len(bytes) >= MESSAGE_HEADER_SIZE {
					length := MESSAGE_HEADER_SIZE + (int(bytes[1]) << 16 | int(bytes[2]) << 8 | int(bytes[3]))
					message := make([]u8, length, context.temp_allocator)
					copy(message, bytes[:length])
					if change != nil {
						message = change(len(sent), message)
					}
					append(&sent, Sent_Message{from_client, level, message})
					if receiver.state != .Failed {
						tls_receive(receiver, level, message, &error)
					}
					tls_bytes_sent(sender, level, length)
					bytes = tls_bytes_to_send(sender, level)
					moved = true
				}
			}
		}
		if !moved {
			break
		}
	}
	return sent
}

// A whole handshake: both sides connected, with ChaCha20-Poly1305, the
// same keys in each direction, the transport parameters of the other side,
// and the key that the client pinned.
@(test)
a_whole_handshake_in_memory :: proc(t: ^testing.T) {
	pair: Test_Pair
	pair_make(&pair)
	sent := handshake_run(&pair)
	testing.expect_value(t, pair.client.state, Tls_State.Connected)
	testing.expect_value(t, pair.server.state, Tls_State.Connected)
	testing.expect_value(t, pair.client.suite, Cipher_Suite.ChaCha20_Poly1305_Sha256)
	testing.expect_value(t, pair.server.suite, Cipher_Suite.ChaCha20_Poly1305_Sha256)
	// ClientHello, ServerHello, EncryptedExtensions, Certificate,
	// CertificateVerify, Finished of the server, Finished of the client.
	testing.expect_value(t, len(sent), 7)
	error: errors.Error_Record
	for level in ([]Encryption_Level{.Handshake, .Application}) {
		for sending in ([]bool{true, false}) {
			client_keys, server_keys: Packet_Keys
			testing.expect(t, tls_packet_keys(&pair.client, level, sending, &client_keys, &error))
			testing.expect(t, tls_packet_keys(&pair.server, level, !sending, &server_keys, &error))
			testing.expect(t, client_keys == server_keys)
			testing.expect(t, client_keys.key != [32]u8{})
		}
	}
	testing.expect_value(t, hex_of(pair.server.peer_transport_parameters[:pair.server.peer_transport_parameters_length]), "01026710")
	testing.expect_value(t, hex_of(pair.client.peer_transport_parameters[:pair.client.peer_transport_parameters_length]), "040480100000")
	testing.expect(t, pair.client.server_public_key == pair.client_configuration.server_public_key)
	// The private key of the X25519 share is erased once the shared secret
	// is made.
	testing.expect(t, pair.client.x25519_private_key == [32]u8{})
	testing.expect(t, pair.server.x25519_private_key == [32]u8{})
}

// The refusals of a handshake that cannot be: a server key that is not the
// pinned one, an application protocol that the server does not speak, and a
// seed that is weaker than the configuration asks.
@(test)
handshakes_that_are_refused :: proc(t: ^testing.T) {
	pair: Test_Pair
	pair_make(&pair, pinned_key_change = 0x01)
	handshake_run(&pair)
	testing.expect_value(t, pair.client.state, Tls_State.Failed)
	testing.expect_value(t, pair.client.alert, Alert.Bad_Certificate)
	testing.expect(t, pair.server.state != .Connected)
	// The client keeps the key that the server presented: the pinned key
	// with its first byte changed back.
	presented := pair.client_configuration.server_public_key
	presented[0] ~= 0x01
	testing.expect(t, pair.client.refused_server_public_key == presented, "the client keeps the key that it refused")
	testing.expect(t, pair.client.refused_server_public_key != pair.client_configuration.server_public_key)

	pair_make(&pair, client_protocol = "h3")
	handshake_run(&pair)
	testing.expect_value(t, pair.server.state, Tls_State.Failed)
	testing.expect_value(t, pair.server.alert, Alert.No_Application_Protocol)

	pair_make(&pair, client_strength = .Weak)
	error: errors.Error_Record
	testing.expect(t, !tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Seed_Too_Weak))
	testing.expect_value(t, len(tls_bytes_to_send(&pair.client, .Initial)), 0)
}

// The messages of a good handshake, to change one of them in the tests
// below.
messages_of_a_good_handshake :: proc() -> [dynamic]Sent_Message {
	pair := new(Test_Pair, context.temp_allocator)
	pair_make(pair)
	return handshake_run(pair)
}

// state_after_one_message gives the state of a fresh side after it got the
// messages of a good handshake before one message, then that message
// changed. receiver_of_index is the side that gets the message.
receiver_after :: proc(pair: ^Test_Pair, messages: []Sent_Message, index: int, changed: []u8) -> ^Tls_Handshake {
	error: errors.Error_Record
	pair_make(pair)
	tls_start(&pair.server, &pair.server_configuration, &pair.cryptography, &pair.server_generator, &error)
	tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error)
	receiver := messages[index].from_client ? &pair.server : &pair.client
	for item, earlier in messages[:index] {
		if item.from_client == messages[index].from_client {
			tls_receive(receiver, item.level, item.bytes, &error)
		}
		_ = earlier
	}
	tls_receive(receiver, messages[index].level, changed, &error)
	return receiver
}

// Each message of a good handshake, cut at each length, with its length
// field set to the cut: the side that gets it fails, and is never
// connected. The same cut with its length field left as it was is a part
// of a message: the side waits for the rest.
@(test)
messages_cut_at_each_length :: proc(t: ^testing.T) {
	messages := messages_of_a_good_handshake()
	pair := new(Test_Pair, context.temp_allocator)
	for item, index in messages {
		for length in MESSAGE_HEADER_SIZE ..< len(item.bytes) {
			cut := make([]u8, length, context.temp_allocator)
			copy(cut, item.bytes[:length])
			body := length - MESSAGE_HEADER_SIZE
			cut[1], cut[2], cut[3] = u8(body >> 16), u8(body >> 8), u8(body)
			receiver := receiver_after(pair, messages[:], index, cut)
			testing.expectf(t, receiver.state == .Failed, "message %d cut to %d bytes: the state is %v", index, length, receiver.state)
		}
		for length in 0 ..< len(item.bytes) {
			receiver := receiver_after(pair, messages[:], index, item.bytes[:length])
			testing.expectf(t, receiver.state != .Failed && receiver.state != .Connected, "message %d, %d bytes of it: the state is %v", index, length, receiver.state)
		}
	}
}

// One changed bit of each byte of each message of a good handshake: the two
// sides never end connected. The transcript of the side that got the
// changed message differs from the transcript of the sender, so a Finished
// does not verify, when a check of the message itself did not refuse it.
@(test)
each_changed_byte_of_each_message :: proc(t: ^testing.T) {
	messages := messages_of_a_good_handshake()
	for item, index in messages {
		for place in 0 ..< len(item.bytes) {
			change_now = {index, place}
			pair := new(Test_Pair, context.temp_allocator)
			pair_make(pair)
			handshake_run(pair, proc(message_index: int, message: []u8) -> []u8 {
				if message_index == change_now.message && change_now.byte < len(message) {
					message[change_now.byte] ~= 0x01
				}
				return message
			})
			testing.expectf(t, !(pair.client.state == .Connected && pair.server.state == .Connected), "a change of the byte %d of the message %d: both sides connected", place, index)
		}
	}
}

// The change that each_changed_byte_of_each_message makes: the procedure
// that handshake_run calls cannot take it as an argument.
Change :: struct {
	message: int,
	byte:    int,
}
change_now: Change

// Messages out of order: each message of the server flight given to the
// client in the place of another, and a message at a level where it does
// not go, give unexpected_message.
@(test)
messages_out_of_order :: proc(t: ^testing.T) {
	messages := messages_of_a_good_handshake()
	pair := new(Test_Pair, context.temp_allocator)
	error: errors.Error_Record
	// The server messages are 1 (ServerHello) to 5 (Finished). After the
	// messages before position, each other server message is refused.
	for position in 1 ..= 5 {
		for other in 1 ..= 5 {
			if other == position {
				continue
			}
			pair_make(pair)
			tls_start(&pair.server, &pair.server_configuration, &pair.cryptography, &pair.server_generator, &error)
			tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error)
			for earlier in 1 ..< position {
				tls_receive(&pair.client, messages[earlier].level, messages[earlier].bytes, &error)
			}
			tls_receive(&pair.client, messages[other].level, messages[other].bytes, &error)
			testing.expectf(t, pair.client.state == .Failed && pair.client.alert == .Unexpected_Message, "message %d in the place of %d: %v %v", other, position, pair.client.state, pair.client.alert)
		}
	}
	// A ServerHello at the Handshake level, and a ClientHello to a client.
	pair_make(pair)
	tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error)
	tls_receive(&pair.client, .Handshake, messages[1].bytes, &error)
	testing.expect_value(t, pair.client.alert, Alert.Unexpected_Message)
	pair_make(pair)
	tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error)
	tls_receive(&pair.client, .Initial, messages[0].bytes, &error)
	testing.expect_value(t, pair.client.alert, Alert.Unexpected_Message)
	// The Finished of the client at the Initial level.
	pair_make(pair)
	tls_start(&pair.server, &pair.server_configuration, &pair.cryptography, &pair.server_generator, &error)
	tls_receive(&pair.server, .Initial, messages[0].bytes, &error)
	tls_receive(&pair.server, .Initial, messages[6].bytes, &error)
	testing.expect_value(t, pair.server.alert, Alert.Unexpected_Message)
}

// 20 000 random messages to a server that waits for a ClientHello and to a
// client that waits for each message of the server: none traps, none
// connects a side. A third of them have the type that the side waits for,
// so that the reading goes past the header.
@(test)
random_messages_never_trap :: proc(t: ^testing.T) {
	messages := messages_of_a_good_handshake()
	state: u64 = 0x544c_5331_3320_0001
	next :: proc(state: ^u64) -> u64 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		return state^
	}
	pair := new(Test_Pair, context.temp_allocator)
	error: errors.Error_Record
	types := [?]u8{1, 2, 8, 11, 15, 20}
	for round in 0 ..< 20_000 {
		target := int(next(&state) % 6) // 0: the server; 1 to 5: the client after that many messages of the server.
		pair_make(pair)
		tls_start(&pair.server, &pair.server_configuration, &pair.cryptography, &pair.server_generator, &error)
		tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error)
		receiver := &pair.server
		level := Encryption_Level.Initial
		if target > 0 {
			receiver = &pair.client
			for earlier in 1 ..< target {
				tls_receive(receiver, messages[earlier].level, messages[earlier].bytes, &error)
			}
			level = messages[target].level
		}
		body_length := int(next(&state) % 300)
		message := make([]u8, MESSAGE_HEADER_SIZE + body_length, context.temp_allocator)
		for &byte in message {
			byte = u8(next(&state))
		}
		message[0] = round % 3 == 0 ? (target == 0 ? 1 : messages[target].bytes[0]) : types[next(&state) % len(types)]
		message[1], message[2], message[3] = 0, u8(body_length >> 8), u8(body_length)
		tls_receive(receiver, level, message, &error)
		testing.expect(t, receiver.state != .Connected)
	}
}

// client_hello_with_padding gives the ClientHello of a client with a
// padding extension (21, which the server does not know and skips) that
// makes it total bytes long.
client_hello_with_padding :: proc(hello: []u8, total: int) -> []u8 {
	// The fields before the extensions: the header, legacy_version, random,
	// legacy_session_id, cipher_suites, legacy_compression_methods.
	position := MESSAGE_HEADER_SIZE + 2 + 32
	position += 1 + int(hello[position])
	position += 2 + (int(hello[position]) << 8 | int(hello[position + 1]))
	position += 1 + int(hello[position])
	extensions_length := int(hello[position]) << 8 | int(hello[position + 1])
	padding_length := total - len(hello) - 4
	larger := make([]u8, total, context.temp_allocator)
	copy(larger, hello)
	at := len(hello)
	larger[at], larger[at + 1] = 0, 21
	larger[at + 2], larger[at + 3] = u8(padding_length >> 8), u8(padding_length)
	extensions_length += 4 + padding_length
	larger[position], larger[position + 1] = u8(extensions_length >> 8), u8(extensions_length)
	body := total - MESSAGE_HEADER_SIZE
	larger[1], larger[2], larger[3] = u8(body >> 16), u8(body >> 8), u8(body)
	return larger
}

// A ClientHello of 3900 bytes (a peer with large key shares and padding):
// with the flight of the server, the transcript passes 4096 bytes, and the
// server takes it. Before the correction (a transcript of 4096 bytes), the
// server failed with internal_error.
@(test)
a_large_client_hello_is_taken :: proc(t: ^testing.T) {
	pair := new(Test_Pair)
	defer free(pair)
	pair_make(pair)
	error: errors.Error_Record
	testing.expect(t, tls_start(&pair.server, &pair.server_configuration, &pair.cryptography, &pair.server_generator, &error))
	testing.expect(t, tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error))
	hello := client_hello_with_padding(tls_bytes_to_send(&pair.client, .Initial), 3900)
	testing.expectf(t, tls_receive(&pair.server, .Initial, hello, &error), "%v %v", pair.server.alert, error)
	testing.expect_value(t, pair.server.state, Tls_State.Server_Waits_For_Finished)
	testing.expect(t, pair.server.transcript_length > 4096)
}

// Bytes of the Initial level left after the ServerHello, whose keys replace
// the Initial keys, and bytes of the Initial level that come later: both
// fail the handshake, as a PROTOCOL_VIOLATION of QUIC (RFC 9001, section
// 4.1.3). Before the correction, the left bytes waited for ever and the
// handshake went on.
@(test)
bytes_after_a_change_of_keys :: proc(t: ^testing.T) {
	for later in ([]bool{false, true}) {
		pair := new(Test_Pair, context.temp_allocator)
		pair_make(pair)
		error: errors.Error_Record
		tls_start(&pair.server, &pair.server_configuration, &pair.cryptography, &pair.server_generator, &error)
		tls_start(&pair.client, &pair.client_configuration, &pair.cryptography, &pair.client_generator, &error)
		tls_receive(&pair.server, .Initial, tls_bytes_to_send(&pair.client, .Initial), &error)
		server_hello := tls_bytes_to_send(&pair.server, .Initial)
		if later {
			testing.expect(t, tls_receive(&pair.client, .Initial, server_hello, &error))
			testing.expect_value(t, pair.client.state, Tls_State.Client_Waits_For_Encrypted_Extensions)
			testing.expect(t, !tls_receive(&pair.client, .Initial, []u8{0x08}, &error))
		} else {
			// The ServerHello and 3 bytes of a message after it.
			with_rest := make([]u8, len(server_hello) + 3, context.temp_allocator)
			copy(with_rest, server_hello)
			with_rest[len(server_hello)] = 0x08
			testing.expect(t, !tls_receive(&pair.client, .Initial, with_rest, &error))
		}
		testing.expect_value(t, pair.client.state, Tls_State.Failed)
		testing.expect(t, pair.client.protocol_violation)
	}
}

// After the secrets of a handshake are erased, tls_packet_keys gives no
// keys: it fails with State, and the record of the keys is zero. The same
// after a failure of the handshake, which erases them too. Before the
// correction, both calls gave keys made from a secret of zeros, with no
// error.
@(test)
no_packet_keys_after_the_secrets_are_erased :: proc(t: ^testing.T) {
	pair := new(Test_Pair)
	defer free(pair)
	pair_make(pair)
	handshake_run(pair)
	testing.expect_value(t, pair.client.state, Tls_State.Connected)
	error: errors.Error_Record
	keys: Packet_Keys
	testing.expect(t, tls_packet_keys(&pair.client, .Application, true, &keys, &error))
	tls_handshake_erase_secrets(&pair.client)
	for level in ([]Encryption_Level{.Handshake, .Application}) {
		for sending in ([]bool{true, false}) {
			error = {}
			testing.expectf(t, !tls_packet_keys(&pair.client, level, sending, &keys, &error), "keys of the level %v came after the erase", level)
			testing.expect_value(t, error.kind, i64(errors.Kind.State))
			testing.expect_value(t, error.argument, 2)
			testing.expect(t, keys == Packet_Keys{}, "a failed call left keys")
		}
	}
	testing.expect(t, !pair.client.handshake_keys_ready && !pair.client.application_keys_ready)
	// A handshake that fails after its handshake secrets were made: a
	// client that refuses the key of the server.
	pair_make(pair, pinned_key_change = 0x01)
	handshake_run(pair)
	testing.expect_value(t, pair.client.state, Tls_State.Failed)
	error = {}
	testing.expect(t, !tls_packet_keys(&pair.client, .Handshake, true, &keys, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.State))
	testing.expect(t, keys == Packet_Keys{})
}

// with_extension gives a copy of a message whose body is one extension
// block (EncryptedExtensions), with one more extension at the end of the
// block, and the two lengths set.
with_extension :: proc(message: []u8, extension: []u8) -> []u8 {
	larger := make([]u8, len(message) + len(extension), context.temp_allocator)
	copy(larger, message)
	copy(larger[len(message):], extension)
	body := len(larger) - MESSAGE_HEADER_SIZE
	larger[1], larger[2], larger[3] = u8(body >> 16), u8(body >> 8), u8(body)
	block := body - 2
	larger[MESSAGE_HEADER_SIZE], larger[MESSAGE_HEADER_SIZE + 1] = u8(block >> 8), u8(block)
	return larger
}

// A server may name the groups that it prefers in EncryptedExtensions, to a
// client that offered supported_groups (RFC 8446, sections 4.2 and 4.2.7):
// the client takes the extension and goes on. Before the correction it
// failed with unsupported_extension. An extension that the client did not
// offer is still refused there: server_name, and one that is not known.
@(test)
supported_groups_in_encrypted_extensions_is_taken :: proc(t: ^testing.T) {
	messages := messages_of_a_good_handshake()
	pair := new(Test_Pair, context.temp_allocator)
	// The message 2 is EncryptedExtensions.
	testing.expect_value(t, messages[2].bytes[0], u8(Handshake_Message.Encrypted_Extensions))
	// supported_groups: a list of 4 bytes, X25519 and secp256r1.
	groups := with_extension(messages[2].bytes, []u8{0x00, 0x0a, 0x00, 0x06, 0x00, 0x04, 0x00, 0x1d, 0x00, 0x17})
	client := receiver_after(pair, messages[:], 2, groups)
	testing.expectf(t, client.state == .Client_Waits_For_Certificate, "the client is in the state %v with the alert %v", client.state, client.alert)
	// server_name with no data: the client did not offer it.
	name := with_extension(messages[2].bytes, []u8{0x00, 0x00, 0x00, 0x00})
	client = receiver_after(pair, messages[:], 2, name)
	testing.expect_value(t, client.state, Tls_State.Failed)
	testing.expect_value(t, client.alert, Alert.Unsupported_Extension)
	// An extension that this side does not know.
	unknown := with_extension(messages[2].bytes, []u8{0xfa, 0xfa, 0x00, 0x00})
	client = receiver_after(pair, messages[:], 2, unknown)
	testing.expect_value(t, client.state, Tls_State.Failed)
	testing.expect_value(t, client.alert, Alert.Unsupported_Extension)
}

// A ClientHello with a session identifier asks for the compatibility mode
// of TLS, which QUIC does not have: the server fails, and the transport
// closes with PROTOCOL_VIOLATION (RFC 9001, section 8.4), not with the code
// of an alert. Before the correction the close had the code of
// illegal_parameter.
@(test)
a_client_hello_with_a_session_identifier_is_a_protocol_violation :: proc(t: ^testing.T) {
	messages := messages_of_a_good_handshake()
	hello := messages[0].bytes
	// The session identifier is after the header, the legacy version and
	// the Random: one byte of length, 0 in a ClientHello of this library.
	place := MESSAGE_HEADER_SIZE + 2 + 32
	testing.expect_value(t, hello[place], 0)
	with_session := make([]u8, len(hello) + 4, context.temp_allocator)
	copy(with_session, hello[:place])
	with_session[place] = 4
	copy(with_session[place + 5:], hello[place + 1:])
	body := len(with_session) - MESSAGE_HEADER_SIZE
	with_session[1], with_session[2], with_session[3] = u8(body >> 16), u8(body >> 8), u8(body)
	pair := new(Test_Pair, context.temp_allocator)
	server := receiver_after(pair, messages[:], 0, with_session)
	testing.expect_value(t, server.state, Tls_State.Failed)
	testing.expect(t, server.protocol_violation, "the failure is not marked as a PROTOCOL_VIOLATION")
	connection := new(Connection)
	defer free(connection)
	connection.tls.protocol_violation = server.protocol_violation
	connection.tls.alert = server.alert
	testing.expect_value(t, tls_failure_code(connection), u64(Transport_Error.Protocol_Violation))
	// The same ClientHello with no session identifier is taken.
	server = receiver_after(pair, messages[:], 0, hello)
	testing.expect_value(t, server.state, Tls_State.Server_Waits_For_Finished)
	testing.expect(t, !server.protocol_violation)
}
