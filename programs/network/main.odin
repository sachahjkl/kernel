// The network service: the one client of the frame service of the network
// device, and the service that gives each program with the grant one
// endpoint of datagrams (contract/datagram).
//
// It speaks Ethernet, ARP, IPv4, ICMP echo (request and answer) and UDP,
// with the protocol library support/network: this program does the input
// and output, the library reads and writes the frames. It has one static
// address (10.0.2.15/24, the gateway 10.0.2.2: the network of QEMU).
//
// The root service names the grant of each endpoint: one remote address and
// one remote port. A request to another remote is refused with the detail
// of the grant; a datagram from another remote does not reach the program.
// The program does not choose its local port (property 20).
//
// One thread. It waits on the completions of the frame ring, on the
// control ring of the root service, and on the command queue of each
// endpoint, with the deadline of the oldest request that waits for an
// answer. The data of a datagram is copied one time, between the datagram
// region of the program and the frame region; the kernel is not on the path
// of the data (property 5).
package network_service

import "contract:datagram"
import "contract:frame"
import "contract:ring"
import "support:network"
import "support:system"

LOCAL_ADDRESS :: 0x0A00020F // 10.0.2.15
GATEWAY_ADDRESS :: 0x0A000202 // 10.0.2.2
PREFIX :: 24
NETWORK_MASK :: 0xFFFF_FF00 // The prefix of 24 bits.

PLACE_COUNT :: 256 // The places of the frame region, frame.PLACE_SIZE bytes each.
RECEIVE_PLACES :: 128 // Places 0 to 127: frames that arrive. 128 to 255: frames to send.
REGION_PAGES :: PLACE_COUNT * frame.PLACE_SIZE / system.PAGE_SIZE

ENDPOINT_CAPACITY :: 8
RECEIVE_CAPACITY :: 128 // The Receive requests of one endpoint that wait at the same time.
PORT_FIRST :: 49152 // The local port of endpoint n is PORT_FIRST + n.
ECHO_IDENTIFIER :: 0x6E00 // The identifier of an echo request of endpoint n is ECHO_IDENTIFIER + n.
ANSWER_TIME :: 1000 // Milliseconds for an answer of ARP or of an echo.
PENDING_CAPACITY :: 64
ARP_CAPACITY :: 16

// The tags of the frame ring: a place for Receive and Send.
TAG_ATTACH :: 1000
TAG_INFO :: 1001
TAG_STATISTICS :: 1002

// A request that the program sent and that waits for the wire.
Pending_Kind :: enum u8 {
	None,
	Send, // The frame is in a send place; it waits for the hardware address.
	Resolve,
	Echo, // Before the echo request: it waits for the hardware address.
	Echo_Sent, // It waits for the echo reply.
	Statistics, // It waits for the statistics of the frame service.
}

Pending :: struct {
	kind:     Pending_Kind,
	endpoint: int,
	tag:      u32,
	address:  u32, // The address that must answer: the next hop for Send and Echo.
	target:   u32, // The address of the request.
	deadline: u64,
	start:    u64,
	place:    int, // Send: the send place.
	bytes:    int, // Echo: the bytes of data.
	length:   int, // Send: the bytes of the frame.
	sequence: u16, // Echo.
	port:     u16, // Send: the remote port.
}

Posted :: struct {
	tag:   u32,
	place: u64,
	room:  u64,
}

Endpoint :: struct {
	ring_memory:     system.Handle, // 0: the place is free.
	datagram_ring:   ring.Ring,
	region_memory:   system.Handle,
	region:          []u8,
	remote_address:  u32, // The grant. 0 and 0: no grant.
	remote_port:     u16,
	local_port:      u16,
	name:            system.Name,
	posted:          [RECEIVE_CAPACITY]Posted,
	posted_first:    int,
	posted_count:    int,
	in_flight:       u32, // Commands taken that have no completion yet.
	held:            ring.Record, // A Send that waits for a free send place.
	has_held:        bool,
	changed:         bool, // A completion was written: wake the program.
	sent:            u64,
	received:        u64,
	dropped:         u64,
}

Neighbor :: struct {
	address:  u32,
	hardware: network.Hardware,
	known:    bool,
}

frames: ring.Ring
frames_memory: system.Handle
frames_changed: bool // A command was written in the frame ring: wake the frame service.
region: []u8
free_sends: [PLACE_COUNT - RECEIVE_PLACES]int
free_send_count: int
hardware: network.Hardware
link_up: bool
control: ring.Ring
control_memory: system.Handle
endpoints: [ENDPOINT_CAPACITY]Endpoint
pending: [PENDING_CAPACITY]Pending
neighbors: [ARP_CAPACITY]Neighbor
identification: u16

// The counts of the service.
refused: u64
answered: u64
problems: [datagram.Problem_Kind][datagram.Layer]datagram.Problem_Row

fail :: proc "contextless" (text: string) -> ! {
	system.log_in("network", .Error, "network: ", text)
	system.stop(1)
}

place_bytes :: proc "contextless" (place: int) -> []u8 {
	return region[place * frame.PLACE_SIZE:][:frame.PLACE_SIZE]
}

frame_command :: proc "contextless" (command: frame.Command, tag: u32, values: [7]u64 = {}) {
	if !ring.push(&frames.commands, ring.Record{kind = u32(command), tag = tag, values = values}) {
		// The accounting of the places keeps room: this does not happen.
		system.log_in("network", .Error, "network: the frame ring is full")
	}
	frames_changed = true
}

frame_receive :: proc "contextless" (place: int) {
	frame_command(.Receive, u32(place), {0 = u64(place * frame.PLACE_SIZE), 1 = frame.PLACE_SIZE})
}

send_place_take :: proc "contextless" () -> (place: int, ok: bool) {
	if free_send_count == 0 {
		return 0, false
	}
	free_send_count -= 1
	return free_sends[free_send_count], true
}

send_place_free :: proc "contextless" (place: int) {
	free_sends[free_send_count] = place
	free_send_count += 1
}

// frame_send gives a frame of a send place to the frame service.
frame_send :: proc "contextless" (place: int, length: int) {
	frame_command(.Send, u32(place), {0 = u64(place * frame.PLACE_SIZE), 1 = u64(length)})
}

next_identification :: proc "contextless" () -> u16 {
	identification += 1
	return identification
}

// next_hop gives the address whose hardware address a frame to address needs.
next_hop :: proc "contextless" (address: u32) -> u32 {
	return address & NETWORK_MASK == LOCAL_ADDRESS & NETWORK_MASK ? address : GATEWAY_ADDRESS
}

neighbor_of :: proc "contextless" (address: u32) -> (hardware: network.Hardware, ok: bool) {
	for item in neighbors {
		if item.known && item.address == address {
			return item.hardware, true
		}
	}
	return {}, false
}

neighbor_learn :: proc "contextless" (address: u32, hardware: network.Hardware) {
	free := -1
	for &item, index in neighbors {
		if item.known && item.address == address {
			item.hardware = hardware
			return
		}
		if !item.known && free < 0 {
			free = index
		}
	}
	neighbors[max(free, 0)] = {address = address, hardware = hardware, known = true}
}

// arp_request sends a request for the hardware address of address.
arp_request :: proc "contextless" (address: u32) {
	place, ok := send_place_take()
	if !ok {
		return // The request that waits ends without an answer.
	}
	length := network.arp_frame(place_bytes(place), network.ARP_REQUEST, hardware, LOCAL_ADDRESS, {}, address)
	frame_send(place, length)
}

complete :: proc "contextless" (endpoint: ^Endpoint, tag: u32, status: datagram.Status, values: [7]u64 = {}) {
	ring.push(&endpoint.datagram_ring.completions, ring.Record{kind = u32(status), tag = tag, values = values})
	endpoint.changed = true
}

// complete_taken completes a command that was in flight.
complete_taken :: proc "contextless" (endpoint: ^Endpoint, tag: u32, status: datagram.Status, values: [7]u64 = {}) {
	endpoint.in_flight -= 1
	complete(endpoint, tag, status, values)
}

pending_add :: proc "contextless" (item: Pending) -> bool {
	for &slot in pending {
		if slot.kind == .None {
			slot = item
			return true
		}
	}
	return false
}

// problem counts a refused frame.
problem :: proc "contextless" (found: datagram.Problem) {
	refused += 1
	row := &problems[found.kind][found.layer]
	row.last = found
	row.count += 1
}

// udp_send builds the frame of a datagram whose data is in the send place,
// for a next hop with a known hardware address, and sends it.
udp_send :: proc "contextless" (endpoint: ^Endpoint, place: int, destination: network.Hardware, address: u32, port: u16, length: int) {
	bytes := place_bytes(place)
	total := network.udp_frame(bytes, destination, hardware, LOCAL_ADDRESS, address, endpoint.local_port, port, length, next_identification())
	frame_send(place, total)
	endpoint.sent += 1
}

echo_send :: proc "contextless" (endpoint_index: int, destination: network.Hardware, address: u32, sequence: u16, bytes: int) -> bool {
	place := send_place_take() or_return
	frame_bytes := place_bytes(place)
	for index in 0 ..< bytes {
		frame_bytes[network.ICMP_DATA + index] = u8(index)
	}
	length := network.echo_frame(frame_bytes, destination, hardware, LOCAL_ADDRESS, address, network.ICMP_ECHO_REQUEST, u16(ECHO_IDENTIFIER + endpoint_index), sequence, bytes, next_identification())
	frame_send(place, length)
	return true
}

// region_range checks that count bytes at place are in the region of an endpoint.
region_range :: proc "contextless" (endpoint: ^Endpoint, place, count: u64) -> bool {
	size := u64(len(endpoint.region))
	return place <= size && count <= size - place
}

// granted checks a remote against the grant of an endpoint, and completes
// the command with the detail of a refusal.
granted :: proc "contextless" (endpoint: ^Endpoint, tag: u32, address: u64, port: u64, check_port: bool) -> bool {
	if endpoint.remote_address != 0 && address == u64(endpoint.remote_address) && (!check_port || port == u64(endpoint.remote_port)) {
		return true
	}
	complete(endpoint, tag, .Not_Granted, {0 = address, 1 = port, 2 = u64(endpoint.remote_address), 3 = u64(endpoint.remote_port)})
	return false
}

// command does one command of an endpoint. false: the command waits for a
// send place (it is held).
command :: proc "contextless" (endpoint: ^Endpoint, index: int, record: ring.Record, now: u64) -> bool {
	values := record.values
	tag := record.tag
	#partial switch datagram.Command(record.kind) {
	case .Info:
		hardware_value: u64
		for byte, place in hardware {
			hardware_value |= u64(byte) << (8 * uint(place))
		}
		complete(endpoint, tag, .Ok, {LOCAL_ADDRESS, u64(endpoint.local_port), GATEWAY_ADDRESS, PREFIX, hardware_value, u64(link_up), datagram.grant_pack(endpoint.remote_address, endpoint.remote_port)})
	case .Send:
		place, count := values[0], values[1]
		if endpoint.region == nil {
			complete(endpoint, tag, .No_Region)
			return true
		}
		if !region_range(endpoint, place, count) {
			complete(endpoint, tag, .Out_Of_Range, {0 = place, 1 = count, 2 = u64(len(endpoint.region))})
			return true
		}
		if count > datagram.DATA_LIMIT {
			complete(endpoint, tag, .Too_Large, {0 = count, 1 = datagram.DATA_LIMIT})
			return true
		}
		if !granted(endpoint, tag, values[2], values[3], true) {
			return true
		}
		if !link_up {
			complete(endpoint, tag, .Link_Down)
			return true
		}
		send_place, ok := send_place_take()
		if !ok {
			return false
		}
		// The one copy: from the region of the program to the frame.
		copy(place_bytes(send_place)[network.UDP_DATA:], endpoint.region[place:][:count])
		hop := next_hop(u32(values[2]))
		if destination, known := neighbor_of(hop); known {
			udp_send(endpoint, send_place, destination, u32(values[2]), u16(values[3]), int(count))
			complete(endpoint, tag, .Ok)
			return true
		}
		if !pending_add({kind = .Send, endpoint = index, tag = tag, address = hop, target = u32(values[2]), deadline = now + ANSWER_TIME, start = now, place = send_place, length = int(count), port = u16(values[3])}) {
			send_place_free(send_place)
			complete(endpoint, tag, .Busy, {0 = PENDING_CAPACITY})
			return true
		}
		endpoint.in_flight += 1
		arp_request(hop)
	case .Receive:
		if endpoint.region == nil {
			complete(endpoint, tag, .No_Region)
			return true
		}
		if !region_range(endpoint, values[0], values[1]) {
			complete(endpoint, tag, .Out_Of_Range, {0 = values[0], 1 = values[1], 2 = u64(len(endpoint.region))})
			return true
		}
		if endpoint.posted_count == RECEIVE_CAPACITY {
			complete(endpoint, tag, .Busy, {0 = RECEIVE_CAPACITY})
			return true
		}
		endpoint.posted[(endpoint.posted_first + endpoint.posted_count) % RECEIVE_CAPACITY] = {tag = tag, place = values[0], room = values[1]}
		endpoint.posted_count += 1
		endpoint.in_flight += 1
	case .Resolve, .Echo:
		if !granted(endpoint, tag, values[0], 0, false) {
			return true
		}
		if datagram.Command(record.kind) == .Echo && values[2] > network.ICMP_DATA_LIMIT {
			complete(endpoint, tag, .Too_Large, {0 = values[2], 1 = network.ICMP_DATA_LIMIT})
			return true
		}
		if !link_up {
			complete(endpoint, tag, .Link_Down)
			return true
		}
		address := u32(values[0])
		hop := next_hop(address)
		item := Pending{kind = .Resolve, endpoint = index, tag = tag, address = hop, target = address, deadline = now + ANSWER_TIME, start = now, bytes = int(values[2]), sequence = u16(values[1])}
		destination, known := neighbor_of(hop)
		if datagram.Command(record.kind) == .Echo {
			item.kind = known ? .Echo_Sent : .Echo
		}
		if !pending_add(item) {
			complete(endpoint, tag, .Busy, {0 = PENDING_CAPACITY})
			return true
		}
		endpoint.in_flight += 1
		if item.kind == .Echo_Sent {
			echo_send(index, destination, address, item.sequence, item.bytes)
		} else {
			arp_request(hop) // Resolve asks again, also when the address is known.
		}
	case .Statistics:
		if !pending_add({kind = .Statistics, endpoint = index, tag = tag, deadline = now + ANSWER_TIME}) {
			complete(endpoint, tag, .Busy, {0 = PENDING_CAPACITY})
			return true
		}
		endpoint.in_flight += 1
		frame_command(.Statistics, TAG_STATISTICS)
	case .Problems:
		room := values[1]
		if room > u64(len(endpoint.region)) / size_of(datagram.Problem_Row) || !region_range(endpoint, values[0], room * size_of(datagram.Problem_Row)) {
			complete(endpoint, tag, .Out_Of_Range, {0 = values[0], 1 = room, 2 = u64(len(endpoint.region))})
			return true
		}
		rows := ([^]datagram.Problem_Row)(raw_data(endpoint.region[values[0]:]))
		count: u64
		for &by_layer in problems {
			for &row in by_layer {
				if row.count == 0 {
					continue
				}
				if count < room {
					rows[count] = row
				}
				count += 1
			}
		}
		complete(endpoint, tag, .Ok, {0 = count})
	case:
		complete(endpoint, tag, .Bad_Command)
	}
	return true
}

// arrived reads one frame that the frame service received, in a receive place.
arrived :: proc "contextless" (place: int, length: int, now: u64) {
	bytes := place_bytes(place)[:min(length, frame.PLACE_SIZE)]
	packet, found := network.parse(bytes)
	if found.kind != .None {
		problem(found)
		return
	}
	switch packet.kind {
	case .None:
	case .Arp:
		if packet.target_address != LOCAL_ADDRESS {
			return // For another machine of the link.
		}
		neighbor_learn(packet.sender_address, packet.sender_hardware)
		if packet.operation == network.ARP_REQUEST {
			if send_place, ok := send_place_take(); ok {
				total := network.arp_frame(place_bytes(send_place), network.ARP_REPLY, hardware, LOCAL_ADDRESS, packet.sender_hardware, packet.sender_address)
				frame_send(send_place, total)
			}
		}
		resolved(packet.sender_address, packet.sender_hardware, now)
	case .Icmp:
		if packet.destination_address != LOCAL_ADDRESS {
			return
		}
		if packet.icmp_kind == network.ICMP_ECHO_REQUEST {
			// The answer goes to the hardware address that sent the request.
			send_place, ok := send_place_take()
			if !ok {
				return
			}
			reply := place_bytes(send_place)
			copy(reply[network.ICMP_DATA:], packet.data)
			total := network.echo_frame(reply, packet.source, hardware, LOCAL_ADDRESS, packet.source_address, network.ICMP_ECHO_REPLY, packet.identifier, packet.sequence, min(len(packet.data), network.ICMP_DATA_LIMIT), next_identification())
			frame_send(send_place, total)
			answered += 1
			return
		}
		for &item in pending {
			if item.kind == .Echo_Sent && item.target == packet.source_address && u16(ECHO_IDENTIFIER + item.endpoint) == packet.identifier && item.sequence == packet.sequence {
				complete_taken(&endpoints[item.endpoint], item.tag, .Ok, {0 = u64(packet.sequence), 1 = u64(len(packet.data)), 2 = u64(packet.ttl)})
				item = {}
				return
			}
		}
	case .Udp:
		if packet.destination_address != LOCAL_ADDRESS {
			return
		}
		port := int(packet.destination_port) - PORT_FIRST
		if port < 0 || port >= ENDPOINT_CAPACITY || endpoints[port].ring_memory == 0 {
			problem({kind = .No_Endpoint, layer = .Udp, offset = network.ETHERNET_HEADER + network.IPV4_HEADER + 2, value = u32(packet.destination_port)})
			return
		}
		endpoint := &endpoints[port]
		if endpoint.remote_address == 0 || packet.source_address != endpoint.remote_address || packet.source_port != endpoint.remote_port {
			problem({kind = .Not_Granted, layer = .Udp, offset = network.ETHERNET_HEADER + network.IPV4_HEADER, value = u32(packet.source_port), limit = u32(endpoint.remote_port)})
			return
		}
		if endpoint.posted_count == 0 {
			endpoint.dropped += 1
			return
		}
		posted := endpoint.posted[endpoint.posted_first]
		endpoint.posted_first = (endpoint.posted_first + 1) % RECEIVE_CAPACITY
		endpoint.posted_count -= 1
		// The one copy: from the frame to the region of the program. The
		// place was checked when it was posted.
		count := min(u64(len(packet.data)), posted.room)
		if region_range(endpoint, posted.place, count) {
			copy(endpoint.region[posted.place:][:count], packet.data[:count])
		}
		endpoint.received += 1
		complete_taken(endpoint, posted.tag, .Ok, {0 = posted.place, 1 = count, 2 = u64(packet.source_address), 3 = u64(packet.source_port)})
	}
}

// resolved continues each request that waited for the hardware address of
// address.
resolved :: proc "contextless" (address: u32, found: network.Hardware, now: u64) {
	for &item in pending {
		if item.address != address {
			continue
		}
		endpoint := &endpoints[item.endpoint]
		#partial switch item.kind {
		case .Send:
			udp_send(endpoint, item.place, found, item.target, item.port, item.length)
			complete_taken(endpoint, item.tag, .Ok)
			item = {}
		case .Resolve:
			value: u64
			for byte, place in found {
				value |= u64(byte) << (8 * uint(place))
			}
			complete_taken(endpoint, item.tag, .Ok, {0 = value, 1 = u64(address)})
			item = {}
		case .Echo:
			if echo_send(item.endpoint, found, item.target, item.sequence, item.bytes) {
				item.kind = .Echo_Sent
				item.deadline = now + ANSWER_TIME
			}
		}
	}
}

// expire ends each request whose answer did not come in time.
expire :: proc "contextless" (now: u64) -> (deadline: u64) {
	deadline = system.WAIT_FOREVER
	for &item in pending {
		if item.kind == .None {
			continue
		}
		if item.deadline > now {
			deadline = min(deadline, item.deadline)
			continue
		}
		endpoint := &endpoints[item.endpoint]
		switch item.kind {
		case .None:
		case .Send:
			send_place_free(item.place)
			complete_taken(endpoint, item.tag, .No_Answer, {0 = u64(item.address), 1 = now - item.start, 2 = 1})
		case .Resolve, .Echo:
			complete_taken(endpoint, item.tag, .No_Answer, {0 = u64(item.address), 1 = now - item.start, 2 = 1})
		case .Echo_Sent:
			complete_taken(endpoint, item.tag, .No_Answer, {0 = u64(item.target), 1 = now - item.start, 2 = 2})
		case .Statistics:
			complete_taken(endpoint, item.tag, .No_Answer, {0 = 0, 1 = now - item.start, 2 = 3})
		}
		item = {}
	}
	return deadline
}

// controlled does one command of the root service.
controlled :: proc "contextless" (record: ring.Record) {
	result := datagram.Status.Ok
	values: [7]u64
	handle := system.Handle(record.values[0])
	#partial switch datagram.Control(record.kind) {
	case .Endpoint_Add:
		region_handle := system.Handle(record.values[1])
		kind, _, through := system.handle_state(handle, control_memory)
		region_kind, region_rights, region_through := system.handle_state(region_handle, control_memory)
		free := -1
		for &item, index in endpoints {
			if item.ring_memory == 0 {
				free = index
				break
			}
		}
		region_address: rawptr
		region_status := system.Status.Bad_Handle
		needed := system.Rights{.Read, .Write}
		if region_kind == .Memory && region_through && needed <= region_rights && system.memory_size(region_handle) == datagram.REGION_PAGES {
			region_address, region_status = system.memory_map(region_handle, {.Write})
		}
		opened: ring.Ring
		ring_status := system.Status.Bad_Handle
		if kind == .Memory && through && free >= 0 && region_status == .Ok {
			opened, ring_status = system.ring_open(handle)
		}
		if free < 0 {
			result = .Busy
			values[0] = ENDPOINT_CAPACITY
		} else if region_status != .Ok || ring_status != .Ok {
			result = .No_Region
		}
		if result != .Ok {
			if region_status == .Ok {
				system.memory_unmap(region_address)
			}
			system.close(handle)
			system.close(region_handle)
		} else {
			endpoint := &endpoints[free]
			name := system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
			remote_address, remote_port := datagram.grant_unpack(record.values[2])
			endpoint^ = {ring_memory = handle, datagram_ring = opened, region_memory = region_handle, region = ([^]u8)(region_address)[:datagram.REGION_PAGES * system.PAGE_SIZE], remote_address = remote_address, remote_port = remote_port, local_port = u16(PORT_FIRST + free), name = name}
			values[0] = u64(endpoint.local_port)
			text: [32]u8
			writer := system.Writer{buffer = text[:]}
			network.address_write(&writer, endpoint.remote_address)
			system.log("network: an endpoint for ", system.name_of(name[:]), ": the local port ", u64(endpoint.local_port), ", the grant ", system.written(&writer), " port ", u64(endpoint.remote_port))
		}
	case .Endpoint_Grant:
		result = .Bad_Command
		for &item in endpoints {
			if item.ring_memory != 0 && item.ring_memory == handle {
				item.remote_address, item.remote_port = datagram.grant_unpack(record.values[1])
				system.log("network: the grant of the endpoint of ", system.name_of(item.name[:]), " changed: ", item.remote_address == 0 ? "none" : "a new remote")
				result = .Ok
			}
		}
	case .Endpoint_Remove:
		result = .Bad_Command
		for &item, index in endpoints {
			if item.ring_memory == 0 || item.ring_memory != handle {
				continue
			}
			for &waiting in pending {
				if waiting.kind != .None && waiting.endpoint == index {
					if waiting.kind == .Send {
						send_place_free(waiting.place)
					}
					waiting = {}
				}
			}
			system.ring_close(&item.datagram_ring)
			system.close(item.ring_memory)
			if item.region_memory != 0 {
				system.memory_unmap(raw_data(item.region))
				system.close(item.region_memory)
			}
			system.log("network: the endpoint of ", system.name_of(item.name[:]), " ended: ", item.sent, " datagrams sent, ", item.received, " received")
			item = {}
			result = .Ok
		}
	case:
		result = .Bad_Command
	}
	system.send(&control.completions, ring.Record{kind = u32(result), tag = record.tag, values = values})
}

// call sends one command to the frame service and waits for its completion.
// Only at the start: no other request is in flight.
call :: proc "contextless" (command: frame.Command, tag: u32, values: [7]u64 = {}) -> ring.Record {
	frame_command(command, tag, values)
	system.wake_reader(&frames.commands)
	for {
		if record, ok := system.receive(&frames.completions); ok && record.tag == tag {
			return record
		}
		wait: system.Wait
		system.wait_records(&wait, &frames.completions)
		system.wait_end(&wait)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	frames_memory = ctx.handles[frame.GRANT_RING]
	control_memory = ctx.handles[datagram.SERVICE_CONTROL]
	status: system.Status
	if frames, status = system.ring_open(frames_memory); status != .Ok {
		fail("no frame ring")
	}
	if control, status = system.ring_open(control_memory); status != .Ok {
		fail("no control ring")
	}
	// The frame region: the device reads and writes it, so it is contiguous.
	memory, memory_status := system.memory_create(REGION_PAGES, 0, {.Contiguous})
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		fail("no frame region")
	}
	region = ([^]u8)(address)[:REGION_PAGES * system.PAGE_SIZE]
	// The frame service maps the ring when it starts: until then, the
	// kernel does not know the other side.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for attempt := 0; attempt < 2000 && give_status != .Ok; attempt += 1 {
		if given, give_status = system.give(frames_memory, memory, {.Read, .Write}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok {
		fail("the frame service does not map the frame ring")
	}
	if attached := call(.Attach, TAG_ATTACH, {0 = u64(given)}); frame.Status(attached.kind) != .Ok {
		fail("the frame service refused the frame region")
	}
	info := call(.Info, TAG_INFO)
	hardware = frame.hardware(info.values[0])
	link_up = info.values[1] != 0
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		send_place_free(place)
	}
	for place in 0 ..< min(RECEIVE_PLACES, int(info.values[3])) {
		frame_receive(place)
	}
	text: [64]u8
	writer := system.Writer{buffer = text[:]}
	network.address_write(&writer, LOCAL_ADDRESS)
	system.write_bytes(&writer, {'/', '2', '4', ' '})
	network.hardware_write(&writer, hardware)
	system.log("network: ok, the address ", system.written(&writer), ", the gateway 10.0.2.2, the link is ", link_up ? "up" : "down", ", ", u64(min(RECEIVE_PLACES, int(info.values[3]))), " places for frames that arrive")
	// The cost of the checksums in this program (no offload to the device):
	// the headers and the checksum of the largest datagram, many times.
	{
		ROUNDS :: 20_000
		place, _ := send_place_take()
		start := system.time()
		for round in 0 ..< ROUNDS {
			network.udp_frame(place_bytes(place), hardware, hardware, LOCAL_ADDRESS, GATEWAY_ADDRESS, PORT_FIRST, 7, network.UDP_DATA_LIMIT, u16(round))
		}
		took := system.time() - start
		send_place_free(place)
		system.log("network: the headers and the checksum of a datagram of 1472 bytes: ", took * 1_000_000 / ROUNDS, " ns, in this program (no offload)")
	}

	for {
		wait := system.wait_begin()
		now := system.time()
		// The frame service: frames that arrived, frames sent, statistics.
		for record in system.receive(&frames.completions) {
			tag := int(record.tag)
			switch {
			case tag < RECEIVE_PLACES:
				if frame.Status(record.kind) == .Ok {
					arrived(tag, int(record.values[0]), now)
				}
				frame_receive(tag)
			case tag < PLACE_COUNT:
				send_place_free(tag)
			case tag == TAG_STATISTICS:
				for &item in pending {
					if item.kind == .Statistics {
						endpoint := &endpoints[item.endpoint]
						complete_taken(endpoint, item.tag, .Ok, {0 = endpoint.sent, 1 = endpoint.received, 2 = system.kernel_entries(), 3 = record.values[2], 4 = refused, 5 = answered, 6 = endpoint.dropped})
						item = {}
					}
				}
			}
		}
		for record in system.receive(&control.commands) {
			controlled(record)
		}
		for &endpoint, index in endpoints {
			if endpoint.ring_memory == 0 {
				continue
			}
			for ring.count(&endpoint.datagram_ring.completions) + endpoint.in_flight + 1 < ring.capacity(&endpoint.datagram_ring.completions) {
				record: ring.Record
				if endpoint.has_held {
					record, endpoint.has_held = endpoint.held, false
				} else {
					ok: bool
					if record, ok = system.receive(&endpoint.datagram_ring.commands); !ok {
						break
					}
				}
				if !command(&endpoint, index, record, now) {
					endpoint.held, endpoint.has_held = record, true
					break
				}
			}
		}
		deadline := expire(now)
		if frames_changed {
			frames_changed = false
			system.wake_reader(&frames.commands)
		}
		for &endpoint in endpoints {
			if endpoint.changed {
				endpoint.changed = false
				system.wake_reader(&endpoint.datagram_ring.completions)
			}
		}
		if !ring.empty(&frames.completions) {
			continue
		}
		system.wait_records(&wait, &frames.completions)
		system.wait_records(&wait, &control.commands)
		for &endpoint in endpoints {
			if endpoint.ring_memory != 0 && !endpoint.has_held && ring.count(&endpoint.datagram_ring.completions) + endpoint.in_flight + 1 < ring.capacity(&endpoint.datagram_ring.completions) {
				system.wait_records(&wait, &endpoint.datagram_ring.commands)
			}
		}
		system.wait_end(&wait, deadline)
	}
}

#assert(REGION_PAGES * system.PAGE_SIZE == PLACE_COUNT * frame.PLACE_SIZE)
#assert(PLACE_COUNT <= frame.RING_CAPACITY)
#assert(TAG_ATTACH >= PLACE_COUNT)
