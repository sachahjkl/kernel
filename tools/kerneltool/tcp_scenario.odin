package kerneltool

// TCP: two machines of their own (docs/NETWORK.md, "The tests").
//
// scenario_tcp: the network device goes to the peer of the tool. `server`
// listens on the TCP port 80; the peer is its TCP client, case by case,
// with loss, reorder, duplicates, a zero window, a RST, a segment of no
// connection, challenge ACKs and 16 connections at once.
//
// scenario_tcp_real: the network device goes to QEMU user networking: the
// TCP at the other end is the one of libslirp. The TCP of the host fetches
// the pages of `server` (hostfwd), and `fetch` fetches from a listener of
// the tool (guestfwd).

TEST_OUTPUT_TCP :: BUILD_FOLDER + "/test_output_tcp.txt"
TEST_OUTPUT_TCP_REAL :: BUILD_FOLDER + "/test_output_tcp_real.txt"

scenario_tcp := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "server"},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: an endpoint for server: TCP, the listen port 80, the remotes that send to it", any_order = true},
	{kind = .Wait, text = "root: started server"},
	{kind = .Wait, text = "server: listening on the TCP port 80, a table of 48 connections, the secret of the initial sequence numbers from "},
	// A page, and a close from the peer first.
	{kind = .Peer, text = "page"},
	{kind = .Wait, text = "server: 1 connections open at once"},
	{kind = .Wait, text = "server: GET / for 10.0.2.2 port "},
	{kind = .Wait, text = " closed, the remote first: in "},
	// 1 MiB each way, and a close from the server first.
	{kind = .Peer, text = "large"},
	{kind = .Wait, text = "server: sent /large to 10.0.2.2 port "},
	{kind = .Wait, text = " closed, this server first: in "},
	{kind = .Peer, text = "sink"},
	{kind = .Wait, text = "server: received /sink from 10.0.2.2 port "},
	{kind = .Wait, text = " bytes, fnv1a64 e7867887f2822325, "},
	// The same with 5 % loss, a reorder of 10 %, duplicates of 10 %.
	{kind = .Peer, text = "loss"},
	{kind = .Peer, text = "reorder"},
	{kind = .Peer, text = "duplicate"},
	// The window of the peer goes to 0 for 1.5 s: the server probes it.
	{kind = .Peer, text = "zero window"},
	// RST: the peer resets a transfer; the server answers a segment of no
	// connection with a RST; a RST and a SYN in the window get challenge ACKs.
	{kind = .Peer, text = "reset"},
	{kind = .Wait, text = " reset by the remote: in "},
	{kind = .Peer, text = "stray"},
	{kind = .Peer, text = "challenge"},
	{kind = .Wait, text = " 2 challenges"},
	{kind = .Peer, text = "crowd"},
	{kind = .Wait, text = "server: 16 connections open at once"},
	// Three more rounds of 1 MiB each way: the spread of the measure.
	{kind = .Peer, text = "large again"},
	{kind = .Peer, text = "sink again"},
	{kind = .Peer, text = "large again"},
	{kind = .Peer, text = "sink again"},
	{kind = .Peer, text = "large again"},
	{kind = .Peer, text = "sink again"},
	// B1: segments that must not fill the admitted remotes, then a page.
	{kind = .Peer, text = "leak"},
	// B2: 32 connections of one host that make no progress: 8 refused by
	// the limit for each remote, each other one ended by a limit, then a page.
	{kind = .Peer, text = "slow"},
	{kind = .Wait, text = ": no request in 10 s, closed", any_order = true},
	{kind = .Wait, text = " aborted: a body under 4096 bytes in one second: in ", any_order = true},
	{kind = .Wait, text = " aborted: no byte acknowledged in 10 s: in "},
	{kind = .Shot, text = "server"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"server\")"},
	{kind = .Wait, text = "[console] server has: log, network"},
	{kind = .Close, text = "server"},
	{kind = .Wait, text = "root: server stopped with code 0"},
	{kind = .Wait, text = "network: the endpoint of server ended: "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = " pages: all the free pages"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_tcp_real := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "server"},
	{kind = .Wait, text = "server: listening on the TCP port 80"},
	{kind = .Fetch, text = "/"},
	{kind = .Wait, text = "server: GET / for 10.0.2.2 port "},
	{kind = .Fetch, text = "/large"},
	{kind = .Wait, text = "server: sent /large to 10.0.2.2 port "},
	{kind = .Fetch, text = "/sink"},
	{kind = .Wait, text = "server: received /sink from 10.0.2.2 port "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"fetch\")"},
	{kind = .Wait, text = "network: an endpoint for fetch: TCP, the local ports "},
	{kind = .Wait, text = "fetch: the grant: TCP to 10.0.2.100 port 80 only, from the local ports "},
	{kind = .Wait, text = "fetch: a SYN to 10.0.2.2 port 80: refused by the network service: the grant names 10.0.2.100 port 80"},
	{kind = .Wait, text = "fetch: a SYN from the local port 1234: refused: the local ports are "},
	{kind = .Wait, text = "fetch: the handshake with 10.0.2.100 port 80: established in "},
	{kind = .Wait, text = "fetch: GET /hello: status 200, \"hello from the host\" in "},
	{kind = .Wait, text = "fetch: GET /large: 1048576 bytes, fnv1a64 e7867887f2822325 as expected, "},
	{kind = .Wait, text = "fetch: POST /sink, 1 MiB: the remote got the same hash, "},
	// libslirp acknowledges the FIN of a connection of guestfwd and keeps
	// its half open: FIN-WAIT-2 (a sending of its FIN gives TIME-WAIT).
	{kind = .Wait, text = "fetch: the close from this side: the remote acknowledged the FIN, and "},
	{kind = .Wait, text = "fetch: ok, 8 cases"},
	{kind = .Shot, text = "fetch"},
	{kind = .Front, text = "server"},
	{kind = .Shot, text = "server_real"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

tcp_tests_run :: proc() -> bool {
	if !machine_test(scenario_tcp[:], BOOT_VOLUME, TEST_OUTPUT_TCP, MACHINE_STOP_OK, TEST_DATA_DISK) || !machine_test(scenario_tcp_real[:], BOOT_VOLUME, TEST_OUTPUT_TCP_REAL, MACHINE_STOP_OK, TEST_DATA_DISK, user_network = true) {
		return false
	}
	frames_of_the_fetch_report()
	return true
}
