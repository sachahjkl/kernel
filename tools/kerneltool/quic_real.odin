package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// QUIC against a stack that this project did not write (docs/QUIC.md,
// section 6): the QUIC client of OpenSSL (`openssl s_client -quic`, OpenSSL
// 3.2 and later; the development shell has the OpenSSL of nixpkgs). The
// network device of the machine goes to the peer of the tool, and s_client
// reaches the UDP port 4433 of the machine through the UDP relay of the
// peer (peer_relay.odin), on the loopback of the host. QEMU user networking
// is not used: with restrict=on, libslirp drops each UDP datagram that the
// machine sends.
//
// What the manual and apps/s_client.c (tag openssl-3.6.0) say, and what the
// step relies on:
// - -quic needs -alpn;
// - -enable_server_rpk offers the server certificate types {raw public
//   key, X.509}; quic_echo takes the raw public key;
// - after the handshake s_client prints "Server-to-client raw public key
//   negotiated", then "Server raw public key" and the key
//   (EVP_PKEY_print_public);
// - s_client goes on whatever the key: the step compares the printed key
//   with the key on the log of the machine (step Quic_Key). That is the pin;
// - with -adv, the line {fin} ends the stream.
//
// What no run has settled yet, and what the step prints when it fails:
// 1. whether s_client waits for the echo and the end of the stream of the
//    server before it ends, when its input ends (the step gives it 20 s
//    with timeout(1), and reads what it printed in that time);
// 2. the form of the printed key: "pub:", then the 32 bytes in hexadecimal
//    with colons, on indented lines (the step reads 64 hexadecimal digits
//    after "pub:", whatever their separators).

TEST_OUTPUT_QUIC_REAL :: BUILD_FOLDER + "/test_output_quic_real.txt"
OPENSSL_WAIT_SECONDS :: 20

scenario_quic_real := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "quic_echo"},
	{kind = .Wait, text = "network: an endpoint for quic_echo: UDP, the listen port 4433, the remotes that send 1200 bytes to it", any_order = true},
	{kind = .Quic_Key, text = "quic_echo: the public key of this server: "},
	{kind = .Wait, text = "quic_echo: listening on the UDP port 4433, a table of 16 connections of "},
	{kind = .Openssl_Quic, text = "an echo through QUIC, from the OpenSSL of the host"},
	{kind = .Wait, text = "quic_echo: a connection from 10.0.2.2 port "},
	{kind = .Front, text = "quic_echo"},
	{kind = .Shot, text = "quic_echo_openssl"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// quic_real_tests_run runs the machine of `kerneltool test quic-real`.
quic_real_tests_run :: proc() -> bool {
	return machine_test(scenario_quic_real[:], BOOT_VOLUME, TEST_OUTPUT_QUIC_REAL, MACHINE_STOP_OK, TEST_DATA_DISK)
}

// openssl_quic_command gives the command of the step: the line, then {fin}
// (with -adv: the end of the stream), to s_client. With diagnostics, it
// adds -msg (the messages of the protocol), -debug (a hex dump of all the
// traffic) and -state (the states of the handshake), all three in the
// manual of OpenSSL 3.6; not -trace, which needs a build option of
// OpenSSL.
openssl_quic_command :: proc(line: string, port: int, diagnostics := false) -> []string {
	// The input stays open for 3 s after the line: s_client ends at the end
	// of its input, before it prints what the server sent back.
	// The text {fin} is an argument: a brace in the format of fmt starts a
	// field of the format.
	script := fmt.tprintf("(printf '%%s\\n%s\\n' '%s'; sleep 3) | timeout %d openssl s_client -quic -alpn kernel-remote -enable_server_rpk -groups X25519 -sigalgs ed25519 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -adv%s -connect 127.0.0.1:%d 2>&1", "{fin}", line, OPENSSL_WAIT_SECONDS, diagnostics ? " -msg -debug -state" : "", port)
	command := make([]string, 3, context.temp_allocator)
	command[0], command[1], command[2] = "sh", "-c", script
	return command
}

// printed_key reads the 32 bytes of the key after "pub:" in what s_client
// printed: the first 64 hexadecimal digits, whatever separates them.
printed_key :: proc(output: string) -> (key: [32]u8, ok: bool) {
	at := strings.index(output, "Server raw public key")
	if at < 0 {
		return key, false
	}
	rest := output[at:]
	pub := strings.index(rest, "pub:")
	if pub < 0 {
		return key, false
	}
	digits := 0
	for character in transmute([]u8)rest[pub + 4:] {
		value: u8
		switch character {
		case '0' ..= '9':
			value = character - '0'
		case 'a' ..= 'f':
			value = character - 'a' + 10
		case 'A' ..= 'F':
			value = character - 'A' + 10
		case ':', ' ', '\n', '\r', '\t':
			continue
		case:
			return key, false
		}
		key[digits / 2] = key[digits / 2] << 4 | value
		digits += 1
		if digits == 64 {
			return key, true
		}
	}
	return key, false
}

// openssl_quic_run runs s_client against quic_echo through the UDP relay
// of the peer, and checks what it printed: the raw public key negotiated,
// the key that the machine printed, and the line back.
openssl_quic_run :: proc(machine: ^Machine, line: string) -> bool {
	relay_port := machine.peer.relay.port
	if relay_port == 0 {
		fmt.eprintln("kerneltool: test failed: the step Openssl_Quic needs the UDP relay of the peer")
		return false
	}
	command := openssl_quic_command(line, relay_port)
	fmt.printfln("kerneltool: runs %s", command[2])
	state, standard_output, standard_error, err := os.process_exec({command = command}, context.allocator)
	defer delete(standard_output)
	defer delete(standard_error)
	if err != nil {
		fmt.eprintfln("kerneltool: test failed: cannot run openssl (the development shell has it): %v", err)
		return false
	}
	output := string(standard_output)
	// On a failure: all that openssl printed (with its error queue and the
	// close code and reason of either side), the datagrams that the relay
	// carried, the last counts of quic_echo and its last line on a closed
	// connection, and a second attempt with the diagnostics of openssl.
	print_output :: proc(output: string, machine: ^Machine, line: string) {
		fmt.eprintln("kerneltool: what openssl printed:")
		fmt.eprintln(output)
		peer_relay_trace_print(machine.peer)
		fmt.eprintfln("kerneltool: the last counts of quic_echo: %s", log_last_line(machine, "quic_echo: accepted "))
		fmt.eprintfln("kerneltool: the last close that quic_echo logged: %s", log_last_line(machine, " ended ("))
		command := openssl_quic_command(line, machine.peer.relay.port, diagnostics = true)
		fmt.eprintfln("kerneltool: a second attempt, with the diagnostics of openssl: %s", command[2])
		_, again, again_error, err := os.process_exec({command = command}, context.allocator)
		defer delete(again)
		defer delete(again_error)
		if err == nil {
			fmt.eprintln(string(again))
		}
	}
	if !strings.contains(output, "Server-to-client raw public key negotiated") {
		fmt.eprintfln("kerneltool: test failed: openssl did not negotiate a raw public key of the server (exit %v)", state.exit_code)
		print_output(output, machine, line)
		return false
	}
	printed, read := printed_key(output)
	sync.mutex_lock(&machine.peer.lock)
	pinned := machine.peer.quic.configuration.tls.server_public_key
	sync.mutex_unlock(&machine.peer.lock)
	if !read || printed != pinned {
		fmt.eprintfln("kerneltool: test failed: the key that openssl printed is not the key on the log of the machine (read: %v)", read)
		print_output(output, machine, line)
		return false
	}
	// The line goes out once (s_client does not print what it sends): if it
	// is in the output, it came back.
	if !strings.contains(output, line) {
		fmt.eprintfln("kerneltool: test failed: the line did not come back in %d s (exit %v)", OPENSSL_WAIT_SECONDS, state.exit_code)
		print_output(output, machine, line)
		return false
	}
	fmt.printfln("kerneltool: test passed: openssl s_client -quic connected to quic_echo with the raw public key of the log, and its line came back")
	return true
}
