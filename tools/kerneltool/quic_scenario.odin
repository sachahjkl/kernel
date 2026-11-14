package kerneltool

// QUIC through the network service (docs/QUIC.md, section 6): the network
// device goes to the peer of the tool. `quic_echo` listens on the UDP port
// 4433 with a listen grant; the peer is its QUIC client, with src/library/support/quic
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
	{kind = .Wait, text = " ended (closed by the client, the code 0000000000000000 of the application, the frame type 0000000000000000, the reason of the client \"\"): in 1048576 bytes, out 1048576 bytes"},
	// One client with 4 streams at once, 256 KiB each way on each: the
	// same 1 MiB in all.
	{kind = .Peer_Quic, text = "streams"},
	{kind = .Wait, text = " ended (closed by the client, the code 0000000000000000 of the application, the frame type 0000000000000000, the reason of the client \"\"): in 1048576 bytes, out 1048576 bytes"},
	// The same with 5 % of the datagrams lost, 10 % reordered, 10 % repeated.
	{kind = .Peer_Quic, text = "loss"},
	// The close of the client goes outside the loss, 3 times
	// (PEER_QUIC_CLOSE_COPIES): the server ends the record by the close.
	{kind = .Wait, text = " ended (closed by the client, the code 0000000000000000 of the application, the frame type 0000000000000000, the reason of the client \"\"): in 1048576 bytes, out 1048576 bytes"},
	// 8 clients at once, from one address: 2 in the handshake at once. The
	// server checks 4 Initials of one address at once, then one in each
	// second, and drops the others with no answer: a client whose
	// handshake ends at its deadline starts a new connection, so the case
	// ends whatever the cases before it left of that budget.
	{kind = .Peer_Quic, text = "crowd"},
	// A client that pins another key: it refuses the server.
	{kind = .Peer_Quic, text = "wrong key"},
	// 1000 forged Initials from 1000 addresses, 8 authentic Initials from 4
	// forged addresses, one datagram of another version, and a real client
	// at the same time: each Initial of the flood gets one Retry and no
	// record, the other version one Version Negotiation packet, the real
	// client its echo.
	{kind = .Peer_Quic, text = "flood"},
	// A client that takes its Retry, sends its Initial with the token, and
	// vanishes: the handshake deadline ends its record.
	{kind = .Peer_Quic, text = "vanish"},
	{kind = .Wait, text = " ended (the handshake deadline, "},
	// A client that goes silent after its echo, with no close, while the
	// server has a packet in flight that the client never acknowledges: the
	// server probes, and ends the record by its idle timeout, whatever the
	// count of its probes. quic_echo measures the silence in time of the
	// machine, checks that the end did not come before the idle timeout of
	// 30 s, and prints its verdict with the numbers (how late the end came
	// is printed, not checked): the step reads the verdict, so it means the
	// same under KVM and under emulation. The time of the host only ends a
	// test that hangs (HANG_BOUND): QEMU gives the machine the clock of the
	// host (no -icount), so 30 s of the machine are about 30 s of the host.
	{kind = .Peer_Quic, text = "silent"},
	{kind = .Wait, text = " ended (the idle timeout, the code 0000000000000000, the frame type 0000000000000000, the reason of the client \"\"): in 65536 bytes, out 65536 bytes"},
	{kind = .Wait, text = ": the idle end held its bound: "},
	{kind = .Front, text = "quic_echo"},
	{kind = .Shot, text = "quic_echo"},
	// The end of the endpoint: the passes of the network service over the
	// bytes of the datagrams of QUIC: one copy each way, and no checksum
	// (quic_echo writes the UDP checksum, and does not check one).
	{kind = .Close, text = "quic_echo"},
	{kind = .Wait, text = "root: quic_echo stopped with code 0"},
	{kind = .Wait, text = "network: the endpoint of quic_echo ended: "},
	{kind = .Wait, text = "network: a measure: the endpoint of quic_echo, UDP: the passes of this service over the data for each payload byte: "},
	{kind = .Wait, text = "network: the endpoint of quic_echo, UDP: this service read each payload byte one time on receive and one time on send, for the copy, and computed no checksum of it: as it must"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

quic_tests_run :: proc() -> bool {
	return machine_test(scenario_quic[:], BOOT_VOLUME, TEST_OUTPUT_QUIC, MACHINE_STOP_OK, TEST_DATA_DISK)
}
