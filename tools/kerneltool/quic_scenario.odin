package kerneltool

// QUIC through the network service (docs/QUIC.md, section 6): the network
// device goes to the peer of the tool. `quic_echo` listens on the UDP port
// 4433 with a listen grant; the peer is its QUIC client, with support/quic
// and the module cryptography compiled for the host, case by case.
//
// The weak seed: the machine of the randomness with no rdrand and no
// rdseed starts quic_echo too (random_scenario.odin): it makes no key.

TEST_OUTPUT_QUIC :: BUILD_FOLDER + "/test_output_quic.txt"

scenario_quic := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "quic_echo"},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: an endpoint for quic_echo: UDP, the listen port 4433, the remotes that send 1200 bytes to it", any_order = true},
	{kind = .Wait, text = "root: started quic_echo"},
	// The key of the server: the client of the peer pins it.
	{kind = .Quic_Key, text = "quic_echo: the public key of this server: "},
	{kind = .Wait, text = "quic_echo: listening on the UDP port 4433, a table of 16 connections of "},
	// 1 MiB each way, through the network service.
	{kind = .Peer_Quic, text = "echo"},
	{kind = .Wait, text = "quic_echo: a connection from 10.0.2.2 port "},
	{kind = .Wait, text = " ended (closed by the client): in 1048576 bytes, out 1048576 bytes"},
	// The same with 5 % of the datagrams lost, 10 % reordered, 10 % repeated.
	{kind = .Peer_Quic, text = "loss"},
	{kind = .Wait, text = " ended (closed by the client): in 1048576 bytes, out 1048576 bytes"},
	// 8 clients at once, from one address: 2 in the handshake at once.
	{kind = .Peer_Quic, text = "crowd"},
	// A client that pins another key: it refuses the server.
	{kind = .Peer_Quic, text = "wrong key"},
	// 1000 forged Initials from 1000 addresses, one datagram of another
	// version, and a real client at the same time: no forged datagram gets
	// an answer, the real client gets its echo.
	{kind = .Peer_Quic, text = "flood"},
	{kind = .Wait, text = ", not authentic 1000, "},
	// A client that sends its first Initial and vanishes: the handshake
	// deadline ends its record.
	{kind = .Peer_Quic, text = "vanish"},
	{kind = .Wait, text = " ended (the handshake deadline)"},
	{kind = .Front, text = "quic_echo"},
	{kind = .Shot, text = "quic_echo"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

quic_tests_run :: proc() -> bool {
	return machine_test(scenario_quic[:], BOOT_VOLUME, TEST_OUTPUT_QUIC, MACHINE_STOP_OK, TEST_DATA_DISK)
}
