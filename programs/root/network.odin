package root

import "contract:datagram"
import "contract:errors"
import "contract:remote"
import "contract:ring"
import "support:system"

// The network. The network service is the one client of the frame service of
// the network device; it starts when a program with the grant Network starts
// (on demand, as the storage service). This service gives each such program
// one endpoint (contract/datagram): a datagram ring that it gives to the two
// programs, and a grant that it names on the control ring of the network
// service. The program cannot choose its remote or its local port
// (property 20, lines 3 and 11).

// The right Inspect of the grant of an endpoint (the facts of the network
// of the machine: the frames that no endpoint owns, the kernel entries of
// the two services) goes only to a program that holds the machine with the
// right Inspect: it reads the facts of all programs already (property 20).

QUIC_ECHO_PORT :: 4433 // The UDP port of quic_echo: the port of the examples of RFC 9000 implementations.

// endpoint_of gives the grant of the endpoint of a program (docs/NETWORK.md):
//   net     a datagram endpoint: the echo server of the test, 10.0.2.2 port 7.
//   remote  a datagram endpoint with a listen grant: the UDP port
//           remote.LISTEN_PORT, and only the remotes of the address of the
//           host (10.0.2.2) that send a datagram of 1200 bytes to it: QUIC
//           in the program (docs/QUIC.md, section 7).
//   server  a segment endpoint with a listen grant: the TCP port 80, and the
//           remotes that send a segment to it.
//   fetch   a segment endpoint with a client grant: 10.0.2.100 port 80, the
//           web server of the test (the tool behind QEMU user networking).
//   quic_echo  a datagram endpoint with a listen grant: the UDP port 4433,
//           and the remotes that send a datagram of 1200 bytes to it.
endpoint_of :: proc "contextless" (name: string) -> datagram.Grant {
	switch name {
	case "net":
		return {address = 0x0A000202, port = 7}
	case "remote":
		return {address = remote.HOST_ADDRESS, port = remote.LISTEN_PORT, listen = true}
	case "server":
		return {port = 80, tcp = true, listen = true}
	case "fetch":
		return {address = 0x0A000264, port = 80, tcp = true}
	case "quic_echo":
		return {port = QUIC_ECHO_PORT, listen = true}
	}
	return {}
}

// network_service gives the network service that runs, or starts it.
network_service :: proc "contextless" () -> (service: ^Started, status: system.Status) {
	for &item in started {
		if item.program != 0 && item.network.head != nil {
			return &item, .Ok
		}
	}
	start("network") or_return
	for &item in started {
		if item.program != 0 && item.network.head != nil {
			return &item, .Ok
		}
	}
	return nil, .Bad_State
}

// endpoint_open makes the endpoint of a program that starts: the datagram
// ring and the datagram region, given to the network service with the
// grant. This service makes the region, not the program: a region of the
// program would let the program revoke the mapping of the network service,
// which would stop on a page fault for all programs. It gives the two
// handles: give them to the program, then close them.
endpoint_open :: proc "contextless" (slot: ^Started, name: string) -> (ring_memory, region_memory: system.Handle, status: system.Status) {
	service := network_service() or_return
	ring_memory = system.memory_create(ring.pages(datagram.RING_CAPACITY)) or_return
	region_memory, status = system.memory_create(datagram.REGION_PAGES)
	given: [2]system.Handle
	if status == .Ok {
		given[0], status = system.give(service.network_memory, ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		given[1], status = system.give(service.network_memory, region_memory, {.Read, .Write})
	}
	grant := endpoint_of(name)
	grant.inspect = .Inspect in grants_of(name)
	packed := system.name_pack(name)
	if status == .Ok && !system.send(&service.network.commands, ring.Record{kind = u32(datagram.Control.Endpoint_Add), values = {0 = u64(given[0]), 1 = u64(given[1]), 2 = datagram.grant_pack(grant), 3 = packed[0], 4 = packed[1], 5 = packed[2], 6 = packed[3]}}) {
		status = .No_Slot
	}
	if status != .Ok {
		// A handle that the network service received and never uses stays in
		// its table until it stops; the case needs a full control ring.
		system.close(ring_memory)
		if region_memory != 0 {
			system.close(region_memory)
		}
		return 0, 0, status
	}
	slot.endpoint, slot.network_service = given[0], service
	return ring_memory, region_memory, .Ok
}

// endpoint_close ends the endpoint of a program that stopped.
endpoint_close :: proc "contextless" (item: ^Started) {
	if item.endpoint != 0 && item.network_service != nil && item.network_service.program != 0 {
		system.send(&item.network_service.network.commands, ring.Record{kind = u32(datagram.Control.Endpoint_Remove), values = {0 = u64(item.endpoint)}})
	}
	item.endpoint, item.network_service = 0, nil
}

// endpoint_revoke ends the grant of an endpoint: the network service refuses
// each request that names a remote, and no datagram reaches the program.
endpoint_revoke :: proc "contextless" (item: ^Started) -> (count: u64) {
	if item.endpoint != 0 && item.network_service != nil && item.network_service.program != 0 {
		if system.send(&item.network_service.network.commands, ring.Record{kind = u32(datagram.Control.Endpoint_Grant), values = {0 = u64(item.endpoint), 1 = 0}}) {
			return 1
		}
	}
	return 0
}

// network_answers reads the completions of the control ring of each network
// service: a refused endpoint goes on the log.
network_answers :: proc "contextless" (wait: ^system.Wait) {
	for &item in started {
		if item.program == 0 || item.network.head == nil {
			continue
		}
		for record in system.receive(&item.network.completions) {
			if datagram.Status(record.kind) != .Ok {
				error := errors.completion_record(record.values)
				text: [240]u8
				writer := system.Writer{buffer = text[:]}
				system.ring_error_text(&writer, &error, "datagram", datagram.control_name(error.operation), datagram.control_argument_name(error.operation, error.argument))
				system.log_in("programs", .Warning, "root: the network service refused a command of its control ring: ", system.written(&writer))
			}
		}
		if wait != nil {
			system.wait_records(wait, &item.network.completions)
		}
	}
}

// network_end forgets a network service that stopped.
network_end :: proc "contextless" (item: ^Started) {
	for &other in started {
		if other.network_service == item {
			other.network_service, other.endpoint = nil, 0
		}
	}
	system.ring_close(&item.network)
	system.close(item.network_memory)
}
