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
	{kind = .Wait, text = "server: listening on the TCP port 80, a table of 48 connections, the secret of the initial sequence numbers from the generator of the program"},
	// A page, and a close from the peer first.
	{kind = .Peer, text = "page"},
	{kind = .Wait, text = "server: 1 connections open at once"},
	{kind = .Wait, text = "server: GET / 200, "},
	{kind = .Wait, text = " closed, the remote first: "},
	// 1 MiB each way, and a close from the server first.
	{kind = .Peer, text = "large"},
	{kind = .Wait, text = "server: GET /large 200, 1048576 bytes, "},
	{kind = .Wait, text = " closed, this server first: "},
	{kind = .Peer, text = "sink"},
	{kind = .Wait, text = "server: received /sink: 1048576 bytes, fnv1a64 e7867887f2822325, "},
	// The same with 5 % loss, a reorder of 10 %, duplicates of 10 %.
	{kind = .Peer, text = "loss"},
	{kind = .Peer, text = "reorder"},
	{kind = .Peer, text = "duplicate"},
	// The window of the peer goes to 0 for 1.5 s: the server probes it.
	{kind = .Peer, text = "zero window"},
	// RST: the peer resets a transfer; the server answers a segment of no
	// connection with a RST; a RST and a SYN in the window get challenge ACKs.
	{kind = .Peer, text = "reset"},
	{kind = .Wait, text = " reset by the remote: "},
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
	// segments that must not fill the admitted remotes, then a page.
	{kind = .Peer, text = "leak"},
	// 32 connections of one host that make no progress: 8 refused by
	// the limit for each remote, each other one ended by a limit, then a page.
	{kind = .Peer, text = "slow"},
	{kind = .Wait, text = ": no request in 10 s, closed", any_order = true},
	{kind = .Wait, text = " aborted: a body under 4096 bytes in one second: ", any_order = true},
	{kind = .Wait, text = " aborted: an answer under 4096 bytes in one second: "},
	// The cases that a read of the HTTP server as hostile input found: each
	// case is a client that the server must end.
	// a whole request and one byte of the next one: 408 after 10 s.
	{kind = .Peer, text = "one byte after a request"},
	// the answers fill the window of the peer, which never reads; the
	// server closed, and must still end the connection.
	{kind = .Peer, text = "answers then close to a zero window"},
	// 1 MiB of a body of 16 MiB, then nothing; a reader of 1 KiB in one second.
	{kind = .Peer, text = "body then nothing"},
	{kind = .Wait, text = " aborted: no byte of the body in 10 s: "},
	{kind = .Peer, text = "slow reader"},
	{kind = .Wait, text = " aborted: an answer under 4096 bytes in one second: "},
	// the console removes a page while answers of it are in progress.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"server\")"},
	{kind = .Wait, text = "root: connected console to the service server"},
	{kind = .Type, text = "server.put(\"changing.txt\", repeat(\"0123456789abcdef\", 200))"},
	{kind = .Wait, text = "server: the page /changing.txt is in the store: 3200 bytes"},
	{kind = .Peer_Start, text = "page changed during its answer"},
	// The mark goes before the removal: a RST after it can be the change of
	// the page, a RST before it cannot.
	{kind = .Peer_Mark, text = "page changed during its answer"},
	{kind = .Type, text = "server.remove(\"changing.txt\")"},
	{kind = .Wait, text = "server: the page /changing.txt is out of the store"},
	// Until now the peer read at three times the least pace of the
	// slow-reader rule; now it reads as fast as it can: the server writes
	// the answer in progress again, and finds the change. The case checks
	// that the RST came after the removal, inside the answers of the page.
	{kind = .Peer_Result, text = "page changed during its answer"},
	{kind = .Wait, text = " aborted: the page changed during its answer: "},
	{kind = .Front, text = "server"},
	{kind = .Shot, text = "server"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"server\")"},
	{kind = .Wait, text = "[console] server   log      held"},
	{kind = .Wait, text = "[console] server   store    held"},
	{kind = .Wait, text = "[console] server   network  held"},
	{kind = .Close, text = "server"},
	{kind = .Wait, text = "root: server stopped with code 0"},
	{kind = .Wait, text = "network: the endpoint of server ended: "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "free_pages_no_budget_holds  0"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_tcp_real := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "server"},
	{kind = .Wait, text = "server: listening on the TCP port 80"},
	{kind = .Fetch, text = "/"},
	{kind = .Wait, text = "server: GET / 200, "},
	{kind = .Fetch, text = "/large"},
	{kind = .Wait, text = "server: GET /large 200, 1048576 bytes, "},
	{kind = .Fetch, text = "/sink"},
	{kind = .Wait, text = "server: received /sink: 1048576 bytes, fnv1a64 e7867887f2822325, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"fetch\")"},
	{kind = .Wait, text = "network: an endpoint for fetch: TCP, the local ports "},
	{kind = .Wait, text = "fetch: the grant: TCP to 10.0.2.100 port 80 only, from the local ports "},
	{kind = .Wait, text = "fetch: a SYN to 10.0.2.2 port 80: refused by the network service: datagram.Send: the argument address, 10.0.2.2 port 80, is refused: the grant names 10.0.2.100 port 80 only"},
	{kind = .Wait, text = "fetch: a SYN from the local port 1234: refused: datagram.Send: the local port 1234 of the segment is not a port of this endpoint (its ports are "},
	{kind = .Wait, text = "fetch: the handshake with 10.0.2.100 port 80: established in "},
	{kind = .Wait, text = "fetch: GET /hello: status 200, \"hello from the host\" in "},
	{kind = .Wait, text = "fetch: GET /large: 1048576 bytes, fnv1a64 e7867887f2822325 as expected, "},
	{kind = .Wait, text = "fetch: POST /sink, 1 MiB: the remote got the same hash, "},
	// libslirp acknowledges the FIN of a connection of guestfwd and keeps
	// its half open: FIN-WAIT-2 (a sending of its FIN gives TIME-WAIT).
	{kind = .Wait, text = "fetch: the close from this side: the remote acknowledged the FIN, and "},
	{kind = .Wait, text = "fetch: ok, 8 cases"},
	{kind = .Shot, text = "fetch"},
	// A page in the private store of server, from the console, through its
	// exports, functions with typed parameters: then the host fetches it,
	// byte for byte.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"server\")"},
	{kind = .Wait, text = "root: connected console to the service server"},
	{kind = .Type, text = "server.put(\"hello.txt\", \"kept in the store of server\")"},
	{kind = .Wait, text = "server: the page /hello.txt is in the store: 27 bytes"},
	{kind = .Http, text = "page hello.txt", expected = "kept in the store of server"},
	{kind = .Type, text = "server.pages()"},
	{kind = .Wait, text = "hello.txt"},
	// HTTP/1.1 from the TCP of the host: keep-alive, a connection for each
	// request, pipelining, a split body, HEAD, 16 clients, each refusal.
	{kind = .Http, text = "keep-alive"},
	{kind = .Wait, text = " requests on one connection of 10.0.2.2 port ", any_order = true},
	{kind = .Http, text = "new-connections"},
	// The ends of connections have their own budget on the log.
	{kind = .Wait, text = " ends of connections in one second are not on the log (the limit is 50)", any_order = true},
	{kind = .Http, text = "pipeline"},
	{kind = .Http, text = "split"},
	{kind = .Http, text = "head"},
	{kind = .Http, text = "crowd"},
	{kind = .Http, text = "errors"},
	// The cases that a read of the HTTP server as hostile input found.
	{kind = .Http, text = "body-not-taken"},
	{kind = .Http, text = "requests-then-fin"},
	{kind = .Http, text = "headers"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "server.remove(\"hello.txt\")"},
	{kind = .Wait, text = "server: the page /hello.txt is out of the store"},
	{kind = .Http, text = "missing hello.txt"},
	// The scenario revokes the store of server: a put and a remove
	// are refused, and the page that is served does not change.
	{kind = .Type, text = "server.put(\"kept.txt\", \"the first text\")"},
	{kind = .Wait, text = "server: the page /kept.txt is in the store: 14 bytes"},
	{kind = .Type, text = "revoke(\"server\", \"store\")"},
	{kind = .Wait, text = "root: revoked the grant store of server"},
	{kind = .Type, text = "server.put(\"kept.txt\", \"a second text\")"},
	{kind = .Wait, text = "server: the store refused the page /kept.txt: the page that is served did not change"},
	{kind = .Http, text = "page kept.txt", expected = "the first text"},
	{kind = .Type, text = "server.remove(\"kept.txt\")"},
	{kind = .Wait, text = "server: the store refused the removal of /kept.txt: the page is still served"},
	{kind = .Http, text = "page kept.txt", expected = "the first text"},
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
