// The datagram contract: what a program and the network service agree on.
// The network service is the one client of the frame service of the network
// device; it gives each program that has the grant one endpoint.
//
// An endpoint is UDP or TCP over IPv4 for one program, with a grant. The
// root service names the grant; the program cannot choose another one
// (no ambient network and no global port names: docs/PROPERTIES.md, "No
// ambient access").
//
//   a datagram endpoint  UDP: a client grant names the one remote address
//                        and remote UDP port that the program reaches; the
//                        network service gives the local port and writes the
//                        UDP header. A listen grant names one local UDP
//                        port, and may name one remote address: then a
//                        datagram of another address is dropped. It answers
//                        only the admitted remotes: each
//                        remote that sent a datagram of LISTEN_FIRST_LEAST
//                        bytes at least to that port, ADMITTED_CAPACITY at
//                        most, until the program releases it (a QUIC
//                        server: docs/QUIC.md, section 6). To a remote that
//                        the program did not validate, it sends at most 3
//                        times the bytes that came from that remote.
//   a segment endpoint   TCP: the program writes and reads whole segments
//                        (support/tcp); the network service writes the IPv4
//                        header and keeps no state of a connection. A client
//                        grant names one remote, and the network service
//                        gives a block of PORT_BLOCK local TCP ports. A
//                        listen grant names one local TCP port, and answers
//                        only the admitted remotes: each remote that sent a
//                        segment to that port, ADMITTED_CAPACITY at most,
//                        until the program releases it (docs/NETWORK.md).
//
// A datagram or a segment from a remote that the grant does not name does
// not reach the endpoint.
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
// page fault, for all programs: a thread that uses memory that its program
// lost stops its program on a page fault.
// The network service copies the data of a datagram one time: from the
// region to its frame, or from its frame to the region. A header or a
// checksum is never computed over bytes that the program can still change.
//
// Many requests are in flight. A Receive stays in flight until a datagram
// arrives: the program gives the places before (the caller supplies the
// memory: the service allocates none for it), and the
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
SEGMENT_LIMIT :: 1480 // The bytes of one segment, with its TCP header: one frame of Ethernet, no fragment.
SEGMENT_LEAST :: 20 // A TCP header with no option.
PORT_BLOCK :: 64 // The local TCP ports of a client grant.
ADMITTED_CAPACITY :: 64 // The admitted remotes of a listen grant.
// The least bytes of a datagram that admits a new remote to a UDP listen
// port. The protocol that listens over UDP, QUIC, starts each connection
// with a datagram of 1200 bytes at least (RFC 9000, section 14.1): a
// shorter datagram of an unknown remote takes no place of the table.
LISTEN_FIRST_LEAST :: 1200

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
	// port (a client grant of TCP: the first of PORT_BLOCK ports), values[2]
	// the address of the gateway, values[3] the length of
	// the prefix of the network, values[4] the hardware address of the
	// device (the first byte in the low bits), values[5] 1 if the link is
	// up, values[6] the grant (grant_pack), with the right Inspect if it has it.
	Info       = 1,
	// values[0]: the place of the data in the region. values[1]: its count of
	// bytes, DATA_LIMIT at most. values[2], values[3]: the remote address and
	// port. The completion comes when the network service has copied the
	// data: the place is free again. A segment endpoint: the place holds a
	// whole segment, SEGMENT_LEAST to SEGMENT_LIMIT bytes, with its checksum;
	// the ports are the ones of its header, and values[3] is not read.
	Send       = 2,
	// values[0]: the place in the region. values[1]: the room there. The
	// completion comes when a datagram arrives: values[0] the place,
	// values[1] its count of bytes (the data that did not fit is lost),
	// values[2], values[3] the remote address and port. A segment endpoint:
	// a whole segment, whose TCP checksum the network service checked.
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
	// tell of the traffic of other programs, and a program without the right
	// learns nothing of another program.
	Statistics = 6,
	// values[0]: a place in the region. values[1]: the room there, in
	// Problem_Row records. The network service writes one row for each kind
	// of frame that it refused for this endpoint (scope Endpoint), then, with
	// the right Inspect of the grant only, one row for each kind of frame
	// that no endpoint owns (scope Machine). It never gives a row of another
	// endpoint. The completion has the count of the full table in values[0].
	Problems   = 7,
	// A listen grant: values[0], values[1]: the address and the port of an
	// admitted remote, whose connection ended or that the program refused.
	// The network service forgets it: a segment or a datagram to it is
	// refused until it is admitted again. The completion: values[0] 1 if the
	// remote was admitted, else 0.
	Release    = 8,
	// A UDP listen grant: values[0], values[1]: the address and the port of
	// an admitted remote that proved its address to the program (a QUIC
	// server: a token of its Retry). Until then, the network service sends
	// to that remote at most 3 times the bytes that came from it (status
	// Amplification). A program that validates each remote removes that
	// limit for the remotes that sent to it; it still reaches no address
	// that did not send it a datagram, and a remote with no datagram for
	// 120 s loses its place. The completion: values[0] 1 if the remote was
	// admitted, else 0.
	Validate   = 9,
}

// The status of a request: the kind of its completion record. When it is
// not Ok, the values of the completion are an error record
// (errors.completion_record), with the kind and the values below.
Status :: enum u32 {
	Ok           = 0,
	Bad_Command  = 1, // Unsupported: the command is not known, or not for this grant; Too_Small: a segment of fewer bytes than SEGMENT_LEAST.
	Out_Of_Range = 2, // Out_Of_Range, unit Bytes: a byte is not in the region. value: the end of the place and its count; limit: the size of the region.
	No_Region    = 3, // Absent, unit Region: the endpoint has no datagram region.
	// No_Grant, unit Endpoint: the remote is not the remote of the grant.
	// value: the remote that the request named (errors.endpoint_pack);
	// limit: the remote of the grant, 0 when it names none (revoked, or a
	// listen grant with no admitted remote); found: the local port of a
	// segment, when it is not a port of the endpoint.
	Not_Granted  = 4,
	Too_Large    = 5, // Too_Long, unit Bytes. value: the count of bytes; limit: the most.
	No_Answer    = 6, // No_Answer: value the address, limit the milliseconds waited, found what did not answer.
	Link_Down    = 7, // Link_Down.
	Busy         = 8, // Busy, unit Requests: too many requests of this kind in flight. limit: the most.
	// Over_Limit, unit Bytes: a Send of a UDP listen grant to a remote that
	// is not validated would pass 3 times the bytes that came from it.
	// value: the bytes that the remote would have received; limit: 3 times
	// the bytes that came from it.
	Amplification = 9,
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
	// gives Not_Granted, and no datagram arrives. A new grant has the form
	// of the old one (UDP or TCP, client or listen, the same listen port):
	// else Bad_Command, because the local ports come from Endpoint_Add.
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
	Tcp      = 6,
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
	Full         = 8, // A segment or a datagram from a new remote when the admitted remotes of a listen grant are full. value: the remote port; limit: the capacity.
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
GRANT_TCP :: u64(1) << 49 // A segment endpoint.
GRANT_LISTEN :: u64(1) << 50 // A listen grant: the port is the local TCP or UDP port. A UDP listen grant may name one remote address; no remote port is named.

// The grant of an endpoint.
Grant :: struct {
	address: u32, // The remote address. With a UDP listen grant: the one address that it admits, or 0 for each address. 0 with a TCP listen grant.
	port:    u16, // The remote port; with a listen grant, the local TCP or UDP port.
	inspect: bool,
	tcp:     bool,
	listen:  bool,
}

// grant_pack gives the grant of an endpoint in one value: the address << 16
// | the port, and the flags above. 0 is no grant.
grant_pack :: proc "contextless" (grant: Grant) -> u64 {
	value := u64(grant.address) << 16 | u64(grant.port)
	if grant.inspect {
		value |= GRANT_INSPECT
	}
	if grant.tcp {
		value |= GRANT_TCP
	}
	if grant.listen {
		value |= GRANT_LISTEN
	}
	return value
}

grant_unpack :: proc "contextless" (value: u64) -> Grant {
	return {address = u32(value >> 16), port = u16(value), inspect = value & GRANT_INSPECT != 0, tcp = value & GRANT_TCP != 0, listen = value & GRANT_LISTEN != 0}
}

// granted says if a grant names a remote: a revoked grant is all zero.
granted :: proc "contextless" (grant: Grant) -> bool {
	return grant.address != 0 || grant.listen
}

// The names of the commands and of their values, for the sentence of the
// error record of a completion (errors.completion_record).
@(rodata)
COMMAND_NAMES := [Command]string {
	.None = "None",
	.Info = "Info",
	.Send = "Send",
	.Receive = "Receive",
	.Resolve = "Resolve",
	.Echo = "Echo",
	.Statistics = "Statistics",
	.Problems = "Problems",
	.Release = "Release",
	.Validate = "Validate",
}

command_name :: proc "contextless" (command: i64) -> string {
	return command >= 0 && command <= i64(max(Command)) ? COMMAND_NAMES[Command(command)] : "an unknown command"
}

// argument_name gives the name of a value of a command, from 1.
argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	if argument < 1 || argument > 7 {
		return ""
	}
	#partial switch Command(command) {
	case .Send:
		names := [?]string{"place", "count", "address", "port"}
		return argument <= len(names) ? names[argument - 1] : ""
	case .Receive:
		names := [?]string{"place", "room"}
		return argument <= len(names) ? names[argument - 1] : ""
	case .Resolve:
		names := [?]string{"address"}
		return argument <= len(names) ? names[argument - 1] : ""
	case .Echo:
		names := [?]string{"address", "sequence", "count"}
		return argument <= len(names) ? names[argument - 1] : ""
	case .Problems:
		names := [?]string{"place", "room"}
		return argument <= len(names) ? names[argument - 1] : ""
	case .Release, .Validate:
		names := [?]string{"address", "port"}
		return argument <= len(names) ? names[argument - 1] : ""
	}
	return ""
}

@(rodata)
CONTROL_NAMES := [Control]string {
	.None            = "None",
	.Endpoint_Add    = "Endpoint_Add",
	.Endpoint_Grant  = "Endpoint_Grant",
	.Endpoint_Remove = "Endpoint_Remove",
}

control_name :: proc "contextless" (command: i64) -> string {
	return command >= 0 && command <= i64(max(Control)) ? CONTROL_NAMES[Control(command)] : "an unknown command"
}

// control_argument_name gives the name of a value of a command of the
// control ring, from 1.
control_argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	#partial switch Control(command) {
	case .Endpoint_Add:
		names := [?]string{"ring", "region", "grant"}
		return argument >= 1 && argument <= len(names) ? names[argument - 1] : ""
	case .Endpoint_Grant:
		names := [?]string{"ring", "grant"}
		return argument >= 1 && argument <= len(names) ? names[argument - 1] : ""
	case .Endpoint_Remove:
		return argument == 1 ? "ring" : ""
	}
	return ""
}
