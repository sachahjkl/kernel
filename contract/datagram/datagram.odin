// The datagram contract: what a program and the network service agree on.
// The network service is the one client of the frame service of the network
// device; it gives each program that has the grant one endpoint.
//
// An endpoint is UDP over IPv4 for one program, with a grant: the one
// remote address and remote port that the program can reach. The root
// service names the grant; the program cannot choose another one, and it
// cannot choose its local port: the network service gives it (property 20,
// lines 3 and 11: no ambient network, no global port names). A datagram from
// another remote does not reach the endpoint.
//
// The program and the network service share two memory objects:
//
//   the datagram ring    a ring (package ring). One command record is one
//                        request: send a datagram, give a place for a
//                        datagram that arrives, and the requests below.
//   the datagram region  REGION_PAGES pages. The program writes the data of
//                        a datagram there; the network service writes the
//                        data of a datagram that arrives there. A request
//                        names a place in the region, never an address.
//
// The root service makes the two memory objects and gives them to the two
// programs, as it makes the call region of a connection. A program does not
// give a region of its own: it would hold the origin of the mapping of the
// network service, and its revocation would stop the network service on a
// page fault, for all programs (choice 108 of docs/FIRST_MILESTONE.md).
// The network service copies the data of a datagram one time: from the
// region to its frame, or from its frame to the region. A header or a
// checksum is never computed over bytes that the program can still change.
//
// Many requests are in flight. A Receive stays in flight until a datagram
// arrives: the program gives the places before (property 14), and the
// network service drops a datagram when no place waits (Statistics counts
// it). A completion record has the tag of its command, and a Status as its
// kind. A refused request has the detail of the refusal in the values of its
// completion: the request, and the limit or the grant that refused it. No
// global error state exists.
//
// This package allocates no memory and calls no kernel operation.
package datagram

RING_CAPACITY :: 256 // The capacity of the datagram ring.
DATA_LIMIT :: 1472 // The bytes of one datagram: one frame of Ethernet, no fragment.

REGION_PAGES :: 128 // The datagram region: 512 KiB.

// The roles of the endpoint in the context of a program.
GRANT_RING :: 11
GRANT_REGION :: 13
// The roles in the context of the network service: the frame ring is the
// role frame.GRANT_RING; the control ring from the root service is this one.
SERVICE_CONTROL :: 12

Command :: enum u32 {
	None       = 0,
	// The completion: values[0] the local address, values[1] the local
	// port, values[2] the address of the gateway, values[3] the length of
	// the prefix of the network, values[4] the hardware address of the
	// device (the first byte in the low bits), values[5] 1 if the link is
	// up, values[6] the grant (grant_pack), with the right Inspect if it has it.
	Info       = 1,
	// values[0]: the place of the data in the region. values[1]: its count of
	// bytes, DATA_LIMIT at most. values[2], values[3]: the remote address and
	// port. The completion comes when the network service has copied the
	// data: the place is free again.
	Send       = 2,
	// values[0]: the place in the region. values[1]: the room there. The
	// completion comes when a datagram arrives: values[0] the place,
	// values[1] its count of bytes (the data that did not fit is lost),
	// values[2], values[3] the remote address and port.
	Receive    = 3,
	// values[0]: an address. The network service asks its hardware address
	// on the link (ARP) again, also when it knows it. The completion:
	// values[0] the hardware address, values[1] the address that answered.
	Resolve    = 4,
	// values[0]: an address. values[1]: a sequence number. values[2]: the
	// bytes of data. The network service sends an echo request (ICMP). The
	// completion comes with the echo reply: values[0] the sequence, values[1]
	// the bytes of data, values[2] the time to live of the reply.
	Echo       = 5,
	// The completion: values[0] the datagrams that this endpoint sent,
	// values[1] the datagrams that it received, values[4] the datagrams that
	// reached its local port from a remote that its grant does not name,
	// values[6] the datagrams for this endpoint that the network service
	// dropped with no place. With the right Inspect of the grant only, the
	// facts of the machine: values[2] the kernel entries of the network
	// service, values[3] those of the frame service, values[5] the echo
	// requests that the network service answered, and values[4] also counts
	// the frames that no endpoint owns. Without the right they are 0: they
	// tell of the traffic of other programs (property 20).
	Statistics = 6,
	// values[0]: a place in the region. values[1]: the room there, in
	// Problem_Row records. The network service writes one row for each kind
	// of frame that it refused for this endpoint (scope Endpoint), then, with
	// the right Inspect of the grant only, one row for each kind of frame
	// that no endpoint owns (scope Machine). It never gives a row of another
	// endpoint. The completion has the count of the full table in values[0].
	Problems   = 7,
}

Status :: enum u32 {
	Ok           = 0,
	Bad_Command  = 1, // The command is not known, or a value is wrong.
	Out_Of_Range = 2, // A byte is not in the region. values[0] the place, values[1] the count, values[2] the size of the region.
	No_Region    = 3, // The endpoint has no datagram region.
	// The remote is not the remote of the grant. values[0], values[1]: the
	// address and the port that the request named; values[2], values[3]: the
	// address and the port of the grant (0 and 0: the grant was revoked).
	Not_Granted  = 4,
	Too_Large    = 5, // values[0]: the count of bytes; values[1]: the limit.
	// No answer before the time limit. values[0]: the address; values[1]:
	// the milliseconds waited; values[2]: what did not answer, 1 the hardware
	// address (ARP), 2 the echo.
	No_Answer    = 6,
	Link_Down    = 7,
	Busy         = 8, // Too many requests of this kind in flight. values[0]: the limit.
}

// The command of the control ring, from the root service to the network
// service. The completion has the tag of the command and a Status.
Control :: enum u32 {
	None            = 0,
	// values[0], values[1]: the datagram ring and the datagram region, as
	// the network service names them (the root service gives them through
	// the memory of the control ring). values[2]: the grant (grant_pack),
	// with or without the right Inspect.
	// values[3..6]: the name of the program, 32 bytes. The completion:
	// values[0] the local port of the endpoint.
	Endpoint_Add    = 1,
	// values[0]: the datagram ring. values[1]: the new grant (grant_pack);
	// 0 ends the grant (a revocation): each request that names a remote
	// gives Not_Granted, and no datagram arrives.
	Endpoint_Grant  = 2,
	// values[0]: the datagram ring. The network service ends the endpoint,
	// and closes the ring and the region.
	Endpoint_Remove = 3,
}

// The layer of a frame where a rule broke.
Layer :: enum u8 {
	None     = 0,
	Ethernet = 1,
	Arp      = 2,
	Ipv4     = 3,
	Icmp     = 4,
	Udp      = 5,
}

Problem_Kind :: enum u8 {
	None         = 0,
	Too_Short    = 1, // value: the bytes of the layer; limit: the bytes that its header needs.
	Bad_Header   = 2, // A field that the layer refuses. value: the field; limit: the value that the layer needs, or its least value.
	Bad_Length   = 3, // A length field. value: the field; limit: the bytes that the frame has, or the least length.
	Bad_Checksum = 4, // value: the checksum in the frame; limit: the checksum of the bytes.
	Unsupported  = 5, // A field that names something that the network service does not do. value: the field.
	No_Endpoint  = 6, // A datagram to a local port of no endpoint. value: the port.
	Not_Granted  = 7, // A datagram from a remote that the grant of the endpoint does not name. value: the remote port; limit: the port of the grant.
}

// The error of one frame: a record, not a number. Zero is no problem.
Problem :: struct {
	kind:     Problem_Kind,
	layer:    Layer,
	offset:   u16, // The byte of the frame where the field starts.
	value:    u32,
	limit:    u32,
	reserved: u32,
}
#assert(size_of(Problem) == 16)

// Whose fact a row of Problems is.
Problem_Scope :: enum u64 {
	Endpoint = 0, // A datagram that reached the local port of this endpoint.
	Machine  = 1, // A frame that no endpoint owns: a fact of the machine.
}

// One row of the table that Problems writes: the frames refused for one
// kind and one layer, and the problem of the last one.
Problem_Row :: struct {
	last:  Problem,
	count: u64,
	scope: Problem_Scope,
}
#assert(size_of(Problem_Row) == 32)

// The right Inspect of a grant: the endpoint reads the facts of the network
// of the machine (Statistics, Problems). The root service gives it only to
// a program that holds the machine with the right Inspect, which reads the
// facts of all programs already.
GRANT_INSPECT :: u64(1) << 48

// grant_pack gives the grant of an endpoint in one value: the remote address
// << 16 | the remote port, and GRANT_INSPECT. 0 is no grant.
grant_pack :: proc "contextless" (address: u32, port: u16, inspect := false) -> u64 {
	return u64(address) << 16 | u64(port) | (inspect ? GRANT_INSPECT : 0)
}

grant_unpack :: proc "contextless" (value: u64) -> (address: u32, port: u16, inspect: bool) {
	return u32(value >> 16), u16(value), value & GRANT_INSPECT != 0
}
