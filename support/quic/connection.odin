package quic

// One QUIC connection (RFC 9000, RFC 9002): the transport over the packet
// protection of `packets.odin` and the TLS handshake of `tls_handshake.odin`.
//
// The whole state is one `Connection` record in memory of the caller, with no
// allocation and no kernel call. The library never waits and never sends: the
// caller owns the endpoint and the clock. So the same code runs in a program
// of the system, in the peer of the tool on the host, and in a host test with
// a fake clock.
//
// **How a caller drives a connection:**
//
// 1. Start it: `connection_start_client`, or `connection_start_server`.
// 2. Give each datagram that came to `connection_datagram_receive`.
// 3. Take each datagram to send from `connection_datagram_send`, until it
//   gives 0.
// 4. Wait for a datagram, at most until the time that `connection_deadline`
//   gives. Then call `connection_time_passes`, and go to 3.
// 5. Use the streams (`stream_open`, `stream_write`, `stream_read` in
//   `streams.odin`), and end with `connection_close`. The record can serve again
//   when its `state` is `.Closed`.
//
// Time is a count of microseconds that the caller gives in each call. The
// library only compares and adds these counts, so any clock that never goes
// back serves.
//
// **What this layer does** (docs/QUIC.md, section 5):
//
// - the three packet number spaces, ACK frames, loss detection by the packet
//   threshold and the time threshold, and the probe timeout (RFC 9002);
// - a fixed congestion window (no NewReno yet);
// - bidirectional streams that the client opens, in a table of records of the
//   caller, with flow control for each stream and for the connection
//   (`streams.odin`);
// - the idle timeout, the handshake deadline, the anti-amplification limit of
//   a server, and the closing and draining states;
// - the handshake, driven by the TLS state machine.
//
// Each frame of the peer is hostile input (`connection_receive.odin`). What
// this layer does not do is a list of the guide (docs/QUIC.md, "What the
// transport does not do yet"): no key update, no migration, no stateless
// reset, no unidirectional stream.

import "contract:errors"
import "support:random"

CLOSE_REASON_KEPT :: 48 // The bytes of the reason phrase of a CONNECTION_CLOSE of the peer that a connection keeps, in `Connection.close_reason_of_peer`. A longer phrase is cut: a program logs these bytes to tell why a foreign stack closed.
MAX_DATAGRAM_SIZE :: 1200 // The bytes of the largest datagram that this side sends: 1200, the size that every path of QUIC carries (RFC 9000, section 14). `connection_datagram_send` never writes more. A datagram with an Initial packet of a client, or with an ack-eliciting Initial packet of a server, has exactly this size.
CONNECTION_ID_SIZE :: 8 // The bytes of each connection identifier that this side chooses: 8 random bytes. A short header carries no length, so `header_read` takes this size to read the identifier of a 1-RTT packet.
CRYPTO_BUFFER_SIZE :: 4096 // The handshake bytes of one encryption level in each direction that a `Crypto_Stream` holds. A CRYPTO frame of the peer that ends past it closes the connection with CRYPTO_BUFFER_EXCEEDED (RFC 9000, section 7.5); more bytes from TLS of this side close it with INTERNAL_ERROR.
SENT_PACKET_LIMIT :: 64 // The ack-eliciting packets of one packet number space that wait for an acknowledgement at one time: the places of `Packet_Number_Space.sent`. When all are taken, the space sends no ack-eliciting packet until the peer acknowledges one or loss detection frees one.
// The congestion window, in bytes: the most bytes of ack-eliciting packets
// that wait for an acknowledgement (`Connection.bytes_in_flight`) before this
// side stops sending new data.
//
// It is the initial window of RFC 9002, section 7.2: min(10 * 1200, max(14720,
// 2 * 1200)) = 12 000. This layer keeps it fixed: it does not grow after an
// acknowledgement and does not shrink after a loss (NewReno comes after).
// `connection_datagram_send` sends new data only when one more datagram of
// `MAX_DATAGRAM_SIZE` fits in it. A probe and an ACK frame go past it.
CONGESTION_WINDOW :: 12000
PACKET_THRESHOLD :: 3 // The packet threshold of loss detection: a packet is lost when the peer acknowledged a packet whose number is larger by this count or more (RFC 9002, section 6.1.1). `loss_detect` uses it.
TIME_THRESHOLD_NUMERATOR :: 9 // The time threshold of loss detection is 9/8 of the round-trip time: a packet older than that, below the largest acknowledged number, is lost (RFC 9002, section 6.1.2). This is the 9.
TIME_THRESHOLD_DENOMINATOR :: 8 // The 8 of the time threshold of 9/8: see `TIME_THRESHOLD_NUMERATOR`.
GRANULARITY :: 1000 // The least time, in microseconds, that a timer of loss detection waits: 1 ms, the timer granularity of RFC 9002, section 6.1.2. It bounds the time threshold and the variation part of the probe timeout from below.
INITIAL_ROUND_TRIP_TIME :: 333_000 // The round-trip time, in microseconds, that a connection assumes before its first sample: 333 ms (RFC 9002, section 6.2.2). With it the first probe timeout is about 1 s.
ACK_DELAY_EXPONENT_OF_THIS_SIDE :: 3 // The exponent of the ACK Delay field of the ACK frames of this side: the field counts units of 2^3 = 8 microseconds. It is the default of RFC 9000, section 18.2, so the transport parameter is not sent.
MAX_ACK_DELAY_OF_THIS_SIDE :: 25_000 // The longest time, in microseconds, that this side holds an ACK frame of the 1-RTT space: 25 ms, the default of RFC 9000, section 18.2, so the transport parameter is not sent. The peer adds it to its probe timeout.
ACK_RANGES_SEND_LIMIT :: 16 // The ranges of one ACK frame that this side sends, from the largest number down. The older ranges are not sent again: the peer got them in earlier frames, or declares those packets lost.
ACK_RANGES_READ_LIMIT :: 64 // The ranges of one ACK frame of the peer that this side acts on, from the largest number down. The other ranges are read for their form and skipped, so a frame of many ranges costs a bounded work.
PROBE_PACKETS :: 2 // The probe packets that a probe timeout asks for: 2 (RFC 9002, section 6.2.4 allows one or two). Two probes survive the loss of one.
NO_DEADLINE :: max(u64) // The deadline that means that no timer runs: the largest time. `connection_deadline` and `server_deadline` give it; the saturating sums of times end at it too, so a deadline never wraps into the past.
// The handshake deadline: the microseconds (10 s) from the start of a client,
// or from the first authentic Initial packet at a server, to the end of the
// handshake.
//
// Anyone can make an authentic Initial packet (its keys come from a public
// value), so a record that waits for a handshake that never ends is freed at
// this deadline, whatever the idle timeout. `connection_time_passes` then ends
// the connection with no packet, and sets
// `Connection.closed_by_handshake_timeout`.
HANDSHAKE_TIME_LIMIT :: 10_000_000

// The state of a connection: where it is between its start and the time when
// its record can serve again.
//
// It goes from `Idle` to `Handshake`, `Connected`, then `Closing` or
// `Draining`, then `Closed`. A failure at the start, the idle timeout and the
// handshake deadline go to `Closed` directly, with no packet. A program reads
// `Connection.state` after each call: `Connected` means that the streams carry
// data, and `Closed` means that the record is free.
Connection_State :: enum u8 {
	Idle, // Not started: the zero value of a record. Only a start acts on it: a receive is refused, a send gives 0.
	Handshake, // The handshake of TLS runs. A server record is in this state from `connection_start_server`, also while it waits for the first Initial packet of its client.
	Connected, // The handshake of TLS is complete: the 1-RTT keys are installed and the streams carry data.
	Closing, // This side closed (`connection_close`, or `connection_fail` for an error): it sends its CONNECTION_CLOSE, then sends it again at the 1st, 2nd, 4th, 8th... datagram of the peer and opens none, for three probe timeouts with no backoff.
	Draining, // The peer sent CONNECTION_CLOSE: this side sends nothing and takes nothing, for three probe timeouts with no backoff.
	Closed, // The connection ended and its keys are erased: the record can serve again with a new start.
}

// The frames of the connection that are not data, which a packet carries and
// which go again when the packet is lost.
//
// Each one is a bit, not a queue: `Connection.pending_controls` holds the
// frames that wait to be sent, and `Sent_Packet.controls` the frames that one
// packet carried. A frame is written with the value of the time when it goes
// (`control_frames_write`), so a frame that goes again carries the newest
// limit, not the one of the lost packet. The frames of one stream are apart,
// in `Stream_Control`.
Control_Frame :: enum u8 {
	Handshake_Done, // HANDSHAKE_DONE: a server tells its client that the handshake is confirmed (RFC 9001, section 4.1.2). Set when the handshake of a server completes.
	Max_Data, // MAX_DATA: the flow control limit of the connection that this side gives the peer, `Connection.receive_max_data`. Set when the application read half of the limit.
	Max_Streams, // MAX_STREAMS: the limit of streams that this side gives the peer, `Connection.streams_limit_given`. A server sets it each time a stream of the client ended and freed its record.
	Streams_Blocked, // STREAMS_BLOCKED: a client says that the limit of streams of the server refused a `stream_open`.
	Path_Response, // PATH_RESPONSE: the answer to a PATH_CHALLENGE of the peer, with the 8 bytes of `Connection.path_response`. It is the one control frame that does not go again when its packet is lost (RFC 9000, section 13.3).
}

// One ack-eliciting packet that waits for an acknowledgement: what it carried,
// to send it again when it is lost.
//
// The record does not hold the bytes of the packet. It names what the packet
// carried: a range of the handshake bytes, a range of one stream, and control
// frames. When the peer acknowledges the packet, `sent_packet_acknowledged`
// notes these ranges as acknowledged. When loss detection declares it lost,
// `sent_packet_lost` puts the ranges and the frames back to be sent, in a new
// packet with a new number: a packet number is never used two times.
//
// A packet with only ACK, PADDING or CONNECTION_CLOSE frames has no record: no
// one acknowledges it. A packet carries one STREAM frame and the control
// frames of one stream at most, so one record names one stream for each.
Sent_Packet :: struct {
	in_use:        bool, // The place holds a packet that waits. false: the place is free for the next packet.
	packet_number: u64, // Its packet number in its packet number space.
	time_sent:     u64, // When it went, in microseconds: the round-trip sample and the time threshold start there.
	size:          u64, // Its bytes on the wire, with its header and its tag: they count in `Connection.bytes_in_flight` until the packet is acknowledged or lost.
	crypto_offset: u64, // The first offset of the handshake bytes that its CRYPTO frame carried, in `Crypto_Stream.send`.
	crypto_length: u64, // The count of those handshake bytes. 0: the packet carried no CRYPTO frame.
	// One STREAM frame at most: its stream, its range, its end.
	stream_identifier: u64, // The stream identifier of its STREAM frame. It has a meaning only when `stream_length` is above 0 or `stream_finish` is true.
	stream_offset:     u64, // The first offset of the stream bytes that it carried.
	stream_length:     u64, // The count of those stream bytes. 0 with no STREAM frame, or with a frame that carried only the end of the stream.
	stream_finish:     bool, // Its STREAM frame carried the end of the stream (the FIN bit).
	controls:          bit_set[Control_Frame], // The control frames of the connection that it carried: they go back to `Connection.pending_controls` when it is lost.
	// The control frames of one stream at most.
	stream_controls:            bit_set[Stream_Control], // The control frames of one stream that it carried. Empty: none.
	stream_controls_identifier: u64, // The stream identifier of those control frames: it can differ from `stream_identifier`.
}

// The handshake bytes of one encryption level, in both directions: what the
// CRYPTO frames of the level carry (RFC 9000, section 7.5).
//
// To send: the bytes that TLS gave (`connection_tls_progress` copies them
// here), kept until the end of the space because they are small. Three marks
// follow them: the first byte never sent, the ranges of lost packets to send
// again, and the ranges that the peer acknowledged. To receive: the bytes of
// the peer by offset, in any order, and the offset up to which they went to
// TLS. TLS only gets bytes in order, with no gap.
//
// Each direction holds `CRYPTO_BUFFER_SIZE` bytes for the life of the level.
// The 1-RTT level therefore holds every message after the handshake (a
// NewSessionTicket of a foreign server) in the same 4096 bytes.
Crypto_Stream :: struct {
	send:              [CRYPTO_BUFFER_SIZE]u8, // The bytes that TLS gave to send, from offset 0. They stay until the space is discarded: a lost range is read here again.
	send_length:       u64, // Their count: the end of the bytes that TLS gave so far.
	send_next:         u64, // The first offset that was never sent. Below it, each byte went at least once.
	send_again:        Range_Set, // The ranges of offsets of lost packets, and of the packets that a probe chose: `crypto_frame_write` sends them before any new byte.
	send_acknowledged: Range_Set, // The ranges of offsets that the peer acknowledged.
	receive:           [CRYPTO_BUFFER_SIZE]u8, // The bytes of the peer, each at its offset: a frame that came early waits here for the bytes before it.
	received:          Range_Set, // The ranges of offsets of the peer that came. Its range from 0 is what TLS can read.
	delivered:         u64, // The bytes before this offset went to TLS: a frame that repeats them is not copied again.
}

// One packet number space (RFC 9000, section 12.3): the Initial, the Handshake
// or the application (1-RTT) packets, with their keys, their numbers and their
// acknowledgements.
//
// QUIC keeps the three apart so that a packet of one encryption level never
// acknowledges, or is confused with, a packet of another: each space counts
// its packet numbers from 0, has its own ACK frames, and runs its own loss
// detection. A `Connection` holds one for each `Encryption_Level`.
//
// The life of a space: its keys are installed (`keys_installed`), it sends and
// receives, then it is discarded (`discarded`) and its keys are erased. The
// Initial space ends when a client first sends a Handshake packet and when a
// server first opens one; the Handshake space ends when the handshake is
// confirmed (RFC 9001, section 4.9). The application space lasts until the
// connection ends.
Packet_Number_Space :: struct {
	keys_installed:                bool, // The keys of the level are known: the space can send and open packets.
	discarded:                     bool, // The keys were dropped and erased (`connection_space_discard`): the space sends nothing and takes nothing more, and its packets in flight no longer count.
	send_keys:                     Packet_Keys, // The keys that protect the packets of this side.
	receive_keys:                  Packet_Keys, // The keys that open the packets of the peer.
	next_packet_number:            u64, // The number of the next packet of this side: it grows by 1 at each packet, and an ACK frame of the peer that names this number or a larger one is a PROTOCOL_VIOLATION.
	// The packets of the peer.
	received:                      Range_Set, // The numbers of the packets of the peer that were processed and recorded: the ranges of the ACK frames of this side, and the test that refuses a packet that comes two times.
	has_received:                  bool, // A packet of the peer was recorded: `largest_received` has a meaning.
	largest_received:              u64, // The largest number of the peer that was recorded: the base from which the short number on the wire of the next packet is read whole.
	largest_received_time:         u64, // When that packet came, in microseconds: the ACK Delay field of the next ACK frame counts from it.
	ack_needed:                    bool, // An ack-eliciting packet of the peer came since the last ACK frame: an ACK frame waits to be sent.
	ack_eliciting_unacknowledged:  int, // The ack-eliciting packets of the peer since the last ACK frame: at 2, the ACK frame of the 1-RTT space goes at once.
	ack_deadline:                  u64, // When the ACK frame must go at the latest, in microseconds: `MAX_ACK_DELAY_OF_THIS_SIDE` after the first packet that asked for it. Only the 1-RTT space waits for it.
	// The packets of this side.
	sent:                          [SENT_PACKET_LIMIT]Sent_Packet, // The ack-eliciting packets of this side that wait for an acknowledgement, in no order: a place is free when its `in_use` is false.
	ack_eliciting_in_flight:       int, // The count of the places of `sent` that are in use.
	has_acknowledged:              bool, // The peer acknowledged a packet of this space: `largest_acknowledged` has a meaning.
	largest_acknowledged:          u64, // The largest number that an ACK frame of the peer named: loss detection declares lost only packets below it.
	loss_time:                     u64, // The time, in microseconds, at which the oldest packet that waits passes the time threshold: `loss_detect` sets it. 0: no packet waits for the time threshold.
	last_ack_eliciting_sent_time:  u64, // When the last ack-eliciting packet of this space went, in microseconds: the probe timeout of the space counts from it.
	probes:                        int, // The probe packets that the space must still send after a probe timeout. A probe goes past the congestion window.
	// The packet number floor: each packet of the peer with a number below it is
	// refused before it is opened. The set `received` holds `RANGE_SET_LIMIT`
	// ranges; when a new number has no place, the set forgets its lowest range,
	// and the floor moves to the end of that range. A packet below the floor can
	// have been processed already, and the set can no longer tell (RFC 9000,
	// section 12.3).
	packet_number_floor:           u64,
	crypto:                        Crypto_Stream, // The handshake bytes of the level, in both directions.
}

// What the caller chooses for a connection, before its start.
//
// A start copies it into the record (`Connection.configuration`), so the
// caller can free or reuse its own copy. The connection sets `tls.role` itself
// and writes the transport parameters itself: the caller leaves them.
//
// ```odin
// configuration: quic.Connection_Configuration
// configuration.tls.least_seed_strength = .Processor
// configuration.tls.server_public_key = pinned_key
// configuration.idle_timeout_milliseconds = 30_000
// ```
Connection_Configuration :: struct {
	// What TLS needs (`Tls_Configuration`): the application protocol, the Ed25519
	// private key of a server or the pinned public key of a client, and the least
	// seed strength that the caller accepts. A least seed strength under
	// `.Processor` is refused at the start: the zero value of the field would
	// accept a weak seed for the keys.
	tls:                       Tls_Configuration,
	idle_timeout_milliseconds: u64, // The idle timeout that this side asks for, in milliseconds: it goes to the peer as `max_idle_timeout`. 0: none from this side, and the connection takes the one of the peer, if it gives one. `server_init` refuses 0.
}

// One QUIC connection: the connection record, the whole state of one
// connection in memory of the caller.
//
// It holds the state of TLS, the three packet number spaces with their keys
// and their packets in flight, the round-trip time, the timers, the limits of
// flow control, and two private buffers. It holds no stream: the stream
// records are a table of the caller (`streams`). The record has about 88 KiB,
// so it never goes on a stack: put it in the global memory of the program or
// in a mapping (docs/QUIC.md, section 5).
//
// One thread uses a record at a time: no call locks. A caller reads the fields
// (the `state`, the round-trip time, why the connection ended) and changes
// none: only the procedures of this library write them.
//
// ```odin
// connection_start_client(&connection, streams[:], &configuration, &cryptography, &generator, now, &error) or_return
// for connection.state != .Closed {
// 	for {
// 		length := connection_datagram_send(&connection, buffer[:], now)
// 		if length == 0 {
// 			break
// 		}
// 		// ... send buffer[:length] ...
// 	}
// 	// ... wait for a datagram, or for connection_deadline(&connection) ...
// }
// ```
Connection :: struct {
	configuration:                     Connection_Configuration, // A copy of the configuration of the caller. The private key of a server is erased from it when TLS starts: the handshake has its own copy.
	cryptography:                      ^Cryptography, // The cryptography module of the program: each seal, open and key derivation is a call of it. The caller keeps it loaded for the life of the record.
	generator:                         ^random.Generator, // The random generator of the thread: the connection identifiers and the key share of TLS come from it.
	state:                             Connection_State, // Where the connection is: a program reads it after each call.
	tls:                               Tls_Handshake, // The state of the TLS handshake. Its secrets are erased when the handshake completes, and when the connection closes.
	tls_started:                       bool, // The handshake of TLS started. A client: at its start. A server: at the first authentic Initial packet of its client; before it, the record has no timer and no key.
	spaces:                            [Encryption_Level]Packet_Number_Space, // One packet number space for each encryption level: Initial, Handshake, application.
	local_connection_id:               [CONNECTION_ID_SIZE]u8, // The connection identifier that this side chose, of `CONNECTION_ID_SIZE` random bytes: the peer writes it as the Destination Connection ID of its packets. This side has only this one.
	peer_connection_id:                [CONNECTION_ID_LIMIT]u8, // The connection identifier of the peer: the Destination Connection ID of each packet of this side. A client first sends to an identifier that it chose itself.
	peer_connection_id_length:         int, // The bytes of the identifier of the peer: 0 to 20.
	peer_connection_id_known:          bool, // The peer chose its identifier: a client took it from the first Initial packet of the server, a server from the first Initial packet of the client. From then on a long header with another Source Connection ID is dropped.
	// The Destination Connection ID of the first Initial packet of the client: the
	// Initial keys of both sides come from it (RFC 9001, section 5.2). After a
	// Retry it is the Source Connection ID of the Retry, because the client then
	// derives new Initial keys from that one. A server also finds a record by it,
	// for the Initial packets of a client that does not know the identifier of the
	// server yet.
	original_destination_connection_id: [CONNECTION_ID_LIMIT]u8,
	original_destination_connection_id_length: int, // The bytes of that identifier: 8 to 20.
	// A Retry took place (`retry.odin`). A client: it took the one Retry that it
	// accepts, and a second one is dropped. A server: the record is of a client
	// that came back with a valid Retry token; the server of several connections
	// sets it. It decides which identifiers the transport parameters must name
	// (RFC 9000, section 7.3).
	retried:                           bool,
	retry_first_destination_connection_id: [CONNECTION_ID_LIMIT]u8, // The identifier that the client chose first, before the Retry: the server names it in the transport parameter `original_destination_connection_id`, and the client checks it.
	retry_first_destination_connection_id_length: int, // The bytes of that first identifier.
	retry_source_connection_id:        [CONNECTION_ID_LIMIT]u8, // The Source Connection ID of the Retry packet: the server names it in the transport parameter `retry_source_connection_id`, and the client checks it.
	retry_source_connection_id_length: int, // The bytes of that identifier.
	retry_token:                       [RETRY_TOKEN_LIMIT]u8, // A client: the Retry token, which each Initial packet after the Retry carries. A server does not use it.
	retry_token_length:                int, // The bytes of the token. 0: no Retry, and the Initial packets carry an empty token.
	local_parameters:                  Transport_Parameters, // The transport parameters that this side sends: `connection_tls_start` writes them from the configuration and the table of streams.
	peer_parameters:                   Transport_Parameters, // The transport parameters of the peer, read and checked. They have a meaning when `peer_parameters_applied` is true.
	peer_parameters_applied:           bool, // The transport parameters of the peer were checked and took effect: its limits of flow control and of streams, its ack delay, its idle timeout.
	handshake_confirmed:               bool, // The handshake is confirmed (RFC 9001, section 4.1.2): a server when its handshake completes, a client when HANDSHAKE_DONE comes. The Handshake space is then discarded, and the probe timeout of the 1-RTT space can run.
	address_validated:                 bool, // The peer proved that it receives at its address: the anti-amplification limit no longer applies. A server: a Handshake packet of the client came, or its Retry token opened. A client: always true.
	client_received_handshake_ack:     bool, // A client: the server acknowledged a Handshake packet, so the server validated the address of the client and the client stops its probes with nothing in flight (RFC 9002, section 6.2.2.1).
	bytes_received:                    u64, // The bytes of the datagrams of the peer of which a packet was processed: a server that did not validate the address sends at most 3 times this count.
	bytes_sent:                        u64, // The bytes of the datagrams that this side wrote: the other side of the anti-amplification limit.
	bytes_in_flight:                   u64, // The bytes of the ack-eliciting packets that wait for an acknowledgement, in all spaces: new data goes only while one more datagram fits under `CONGESTION_WINDOW`.
	// The round-trip time (RFC 9002, section 5), in microseconds.
	has_round_trip_sample:             bool, // A round trip was measured: the three values below have a meaning. false: the timers use `INITIAL_ROUND_TRIP_TIME`.
	latest_round_trip:                 u64, // The last sample, in microseconds: the time from the sending of the largest acknowledged packet to its ACK frame (latest_rtt in RFC 9002).
	smoothed_round_trip:               u64, // The moving average of the samples, each one less the ack delay of the peer, in microseconds (smoothed_rtt). A program shows it as the round-trip time of the connection.
	round_trip_variation:              u64, // The moving average of the distance of the samples from `smoothed_round_trip`, in microseconds (rttvar): 4 times it is the margin of the probe timeout.
	min_round_trip:                    u64, // The smallest sample, in microseconds (min_rtt): an ack delay that would bring a sample below it is not subtracted.
	probe_timeout_count:               u32, // The probe timeouts in a row with no acknowledgement (pto_count): the probe timeout doubles for each one, up to 2^16. An acknowledgement sets it to 0.
	last_sent_time:                    u64, // When this side last wrote a datagram, in microseconds: the probe of a client with nothing in flight counts from it.
	// The idle timeout, in microseconds.
	idle_timeout:                      u64, // The idle timeout of the connection, in microseconds: the smaller of the two values that the sides gave and that are not 0 (RFC 9000, section 10.1). 0: none. Before the transport parameters of the peer came, it is the value of this side.
	last_activity:                     u64, // The time from which the idle timeout counts, in microseconds: the last packet of the peer that was processed and recorded, or the first ack-eliciting packet of this side after it. A later probe does not move it.
	ack_eliciting_sent_since_receive:  bool, // This side sent an ack-eliciting packet since the last recorded packet of the peer: the next ones do not move `last_activity`.
	// The streams (streams.odin): the table of the caller, and the counts
	// of the streams that each side opened.
	streams:                           []Stream, // The stream records, a table of the caller: its count is the most streams that are open at one time. A caller walks it to find the streams that the peer opened (`in_use`, `identifier`).
	streams_opened_by_peer:            u64, // The count of streams that the peer opened so far, in order: the stream with the index n of the peer is open, or ended, when n is below it.
	streams_opened_by_this_side:       u64, // The count of streams that this side opened so far: the index of its next stream.
	streams_limit_given:               u64, // The limit of streams that this side gave the peer: the count of streams that the peer can open in all, over the life of the connection. A server: its stream records at the start, plus one for each stream of the client that ended. A client: 0.
	peer_max_streams_bidirectional:    u64, // The limit of streams that the peer gave: the count of streams that this side can open in all. It only grows (MAX_STREAMS).
	stream_send_turn:                  int, // The index of the stream record whose stream sends first in the next packet: after a stream sent, the turn goes to the record after it, so each stream gets its turn.
	// Flow control of the connection: the data of all streams.
	peer_max_data:                     u64, // The flow control limit of the connection that the peer gave (MAX_DATA): the most new bytes that this side sends on all streams together. It only grows.
	data_sent_total:                   u64, // The new stream bytes that this side sent so far, on all streams: bytes that go again do not count again.
	receive_window:                    u64, // The bytes that this side lets the peer send ahead of what the application read, on all streams together: the buffers of every stream record, so the limit of each stream is the one that binds.
	receive_max_data:                  u64, // The flow control limit of the connection that this side gave the peer (MAX_DATA): data past it is a FLOW_CONTROL_ERROR.
	data_received_total:               u64, // The bytes of the peer that count against `receive_max_data`: the sum, over its streams, of the largest offset that each one reached (RFC 9000, section 4.1).
	data_consumed_total:               u64, // The bytes of the peer that no longer take room: those that the application read, and those that a RESET_STREAM of the peer dropped. `receive_max_data` moves forward from it.
	peer_max_ack_delay:                u64, // The longest time that the peer holds an ACK frame, in microseconds, from its transport parameters: 25 ms before they come. It is part of the probe timeout of the 1-RTT space, and the most that an ACK Delay field can subtract from a sample.
	peer_ack_delay_exponent:           u64, // The `ack_delay_exponent` of the peer: the ACK Delay field of its ACK frames counts units of 2 to this power, in microseconds. 3 before its transport parameters come.
	pending_controls:                  bit_set[Control_Frame], // The control frames of the connection that wait to be sent in the next 1-RTT packet.
	path_response:                     [PATH_DATA_SIZE]u8, // The 8 bytes of the last PATH_CHALLENGE of the peer, to send back in a PATH_RESPONSE. A second challenge before the answer went replaces the first.
	// The close.
	close_error_code:                  u64, // The error code of the CONNECTION_CLOSE: of this side in the closing state, of the peer when `closed_by_peer` is true. A transport code is a `Transport_Error`, or 0x100 plus an alert of TLS; an application code is of the application.
	close_frame_type:                  u64, // The type of the frame that caused a transport close, or 0 when no frame did.
	close_is_application:              bool, // The close is of the application (a CONNECTION_CLOSE of type 0x1d): `close_error_code` is a code of the application, not a `Transport_Error`.
	// The first bytes of the reason phrase of the CONNECTION_CLOSE of the peer,
	// `CLOSE_REASON_KEPT` at most: a program logs them, to tell why a foreign
	// stack closed. They are bytes of the peer: a program shows them as text only
	// after it checked them. This side sends no reason phrase.
	close_reason_of_peer:              [CLOSE_REASON_KEPT]u8,
	close_reason_of_peer_length:       int, // The bytes of the reason phrase that were kept.
	closed_by_peer:                    bool, // The peer sent CONNECTION_CLOSE: the close fields hold its code, its frame type and its kind.
	closed_by_idle_timeout:            bool, // The idle timeout ended the connection, with no packet.
	closed_by_handshake_timeout:       bool, // The handshake did not complete before the handshake deadline (`HANDSHAKE_TIME_LIMIT`): the connection ended, with no packet.
	ended_at:                          u64, // The time at which the connection became `Closed`, in microseconds. With `last_activity`, a program shows how long an idle end took, and compares it with `connection_idle_bound`.
	handshake_deadline:                u64, // The handshake deadline of this connection, in microseconds: its start, or the first authentic Initial packet at a server, plus `HANDSHAKE_TIME_LIMIT`.
	// Set while the frames of one packet are read: data of the packet (a CRYPTO or
	// a STREAM frame) had no place in a range set. The packet is then not recorded
	// and not acknowledged, so the peer declares it lost and sends its data again.
	packet_data_dropped:               bool,
	close_to_send:                     bool, // A CONNECTION_CLOSE waits to be sent: the next call of `connection_datagram_send` writes it.
	// The datagrams of the peer that came in the closing state. The closing state
	// answers the 1st, 2nd, 4th, 8th... of them, not each one: a third party that
	// knows the connection identifier and forges the address of the client makes
	// few answers (RFC 9000, section 10.2.1).
	close_datagrams_received:          u64,
	close_next_answer:                 u64, // The value of `close_datagrams_received` at which the next CONNECTION_CLOSE goes: it doubles at each answer.
	close_deadline:                    u64, // The end of the closing or draining state, in microseconds: three probe timeouts with no backoff after its start. The connection is then `Closed`.
	// Private memory: the copy of the datagram that `connection_datagram_receive`
	// works on. The library removes the header protection and opens each packet in
	// place in this copy, so the bytes of the caller never change, and a caller
	// that changes its bytes during the call changes nothing here.
	datagram_copy:                     [DATAGRAM_LIMIT]u8,
	payloads:                          [Encryption_Level][MAX_DATAGRAM_SIZE]u8, // Private memory: the frames of the packet of each level of the datagram that `connection_datagram_send` builds, before each packet is sealed into the buffer of the caller.
}

// connection_start_client starts a client: it chooses its connection
// identifier and the Destination Connection ID of its first Initial packet,
// and makes the ClientHello.
//
// After it, the first datagram is ready: the caller takes it with
// `connection_datagram_send`. The handshake deadline starts at `now`. The
// record is cleared first, so a record that served before can serve again; the
// stream records of the table are cleared too, and the bytes that an earlier
// connection left in them are erased.
//
// **Parameters**
//
// - `connection`: the record. Memory of the caller, never a stack.
// - `streams`: the table of stream records, memory of the caller, never a
//   stack. Its count is the most streams that the client has open at one time.
//   The connection keeps the slice: the table lives as long as the record.
// - `configuration`: copied. `tls.server_public_key` is the pinned key of the
//   server; `tls.least_seed_strength` is `.Processor` at least.
// - `cryptography`, `generator`: the cryptography module of the program and
//   the random generator of the thread. The connection keeps both pointers.
// - `now`: the time, in microseconds.
// - `error`: the error record that a failure writes.
//
// **Result**: true when the connection is in the state `Handshake`. false:
// `error` says why, and the state is `Closed`.
//
// **Errors**
//
// - `Bad_Value`, argument 1: the least seed strength of the configuration is
//   under `.Processor`.
// - The error of `random.fill_for_a_key`: the seed of the generator is weaker
//   than the least seed strength.
// - The error of `initial_keys` or of `tls_start`: an export of the
//   cryptography module failed, or the transport parameters do not fit
//   (`Too_Long`).
connection_start_client :: proc "contextless" (connection: ^Connection, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, now: u64, error: ^errors.Error_Record) -> bool {
	connection_reset(connection, streams, configuration, cryptography, generator, now)
	connection.configuration.tls.role = .Client
	connection.address_validated = true
	connection.handshake_deadline = saturating_add(now, HANDSHAKE_TIME_LIMIT)
	if !connection_seed_strength_check(configuration, error) {
		connection.state = .Closed
		return false
	}
	least := configuration.tls.least_seed_strength
	if !random.fill_for_a_key(generator, connection.local_connection_id[:], least, error) || !random.fill_for_a_key(generator, connection.original_destination_connection_id[:CONNECTION_ID_SIZE], least, error) {
		connection.state = .Closed
		return false
	}
	connection.original_destination_connection_id_length = CONNECTION_ID_SIZE
	connection.peer_connection_id_length = copy(connection.peer_connection_id[:], connection.original_destination_connection_id[:CONNECTION_ID_SIZE])
	if !connection_initial_keys_install(connection, error) || !connection_tls_start(connection, error) {
		connection.state = .Closed
		return false
	}
	connection_tls_progress(connection, now)
	return connection.state == .Handshake
}

// connection_start_server prepares a server record for one client: the
// handshake starts at the first Initial packet of the client, whose
// Destination Connection ID gives the Initial keys.
//
// After it the record waits in the state `Handshake`, with no key, no timer
// and nothing to send: `connection_deadline` gives `NO_DEADLINE` until the
// first authentic Initial packet comes. The caller gives that datagram to
// `connection_datagram_receive`. A program that serves several clients does
// not call this: `Server` chooses a record for each client and calls it.
//
// **Parameters**
//
// - `connection`: the record. Memory of the caller, never a stack.
// - `streams`: the table of stream records, memory of the caller, never a
//   stack. Its count is the limit of streams that the server gives the client:
//   the client can open as many streams at one time.
// - `configuration`: copied. `tls.server_private_key` is the Ed25519 key of
//   the server; `tls.least_seed_strength` is `.Processor` at least.
// - `cryptography`, `generator`: the cryptography module of the program and
//   the random generator of the thread. The connection keeps both pointers.
// - `now`: the time, in microseconds.
// - `error`: the error record that a failure writes.
//
// **Result**: true when the record is ready. false: `error` says why, and the
// state is `Closed`.
//
// **Errors**
//
// - `Bad_Value`, argument 1: the least seed strength of the configuration is
//   under `.Processor`.
// - The error of `random.fill_for_a_key`: the seed of the generator is weaker
//   than the least seed strength, so the server makes no connection identifier.
connection_start_server :: proc "contextless" (connection: ^Connection, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, now: u64, error: ^errors.Error_Record) -> bool {
	connection_reset(connection, streams, configuration, cryptography, generator, now)
	connection.configuration.tls.role = .Server
	connection.streams_limit_given = u64(len(streams))
	if !connection_seed_strength_check(configuration, error) {
		connection.state = .Closed
		return false
	}
	if !random.fill_for_a_key(generator, connection.local_connection_id[:], configuration.tls.least_seed_strength, error) {
		connection.state = .Closed
		return false
	}
	return true
}

// connection_seed_strength_check refuses a configuration whose least seed
// strength is under `.Processor`.
//
// A field left at its zero value would accept a weak seed for the keys.
// `tls_start` refuses it too, but a server starts TLS only at the first
// Initial packet: this check makes the start of a server, and `server_init`,
// fail at once. It gives false and writes `Bad_Value`, argument 1, with the
// strength found and the least strength allowed.
@(private)
connection_seed_strength_check :: proc "contextless" (configuration: ^Connection_Configuration, error: ^errors.Error_Record) -> bool {
	if configuration.tls.least_seed_strength < .Processor {
		errors.fail(error, -1, .Bad_Value, .None, 1, i64(configuration.tls.least_seed_strength), i64(random.Seed_Strength.Processor), 0)
		return false
	}
	return true
}

// connection_reset makes a record a new connection: all zero, then the
// streams, the configuration, the cryptography module and the generator of the
// caller.
//
// Both starts call it first, so no field of an earlier connection of the
// record survives. What it sets apart from zero:
//
// - the state `Handshake`, and `last_activity` at `now`;
// - the idle timeout of this side, in microseconds;
// - each stream record cleared, and the bytes that an earlier connection left
//   in a record in use erased;
// - the flow control limit of the connection: the buffers of every stream
//   record;
// - the ack delay values of the peer at their defaults (25 ms, exponent 3),
//   until its transport parameters come.
@(private)
connection_reset :: proc "contextless" (connection: ^Connection, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, now: u64) {
	connection^ = {}
	connection.configuration = configuration^
	connection.cryptography = cryptography
	connection.generator = generator
	connection.state = .Handshake
	connection.last_activity = now
	connection.idle_timeout = saturating_multiply(configuration.idle_timeout_milliseconds, 1000)
	connection.streams = streams
	for &stream in streams {
		// A connection that ended with streams still open left their bytes:
		// the next connection of the table never holds them.
		if stream.in_use {
			stream_buffers_erase(&stream)
		}
		stream.state = {}
	}
	// The window of the connection: the buffers of every stream, so the
	// limit of each stream is the one that binds.
	connection.receive_window = u64(max(len(streams), 1)) * STREAM_BUFFER_SIZE
	connection.receive_max_data = connection.receive_window
	connection.peer_max_ack_delay = 25_000
	connection.peer_ack_delay_exponent = 3
}

// connection_initial_keys_install derives the Initial keys from the
// Destination Connection ID of the first Initial packet of the client (RFC
// 9001, section 5.2), and installs them in the Initial space.
//
// A client calls it at its start, and again after a Retry, with the identifier
// of the Retry. The two sides derive the same pair: the client sends with the
// client keys and opens with the server keys, a server the reverse. The local
// copies of the keys are erased. It gives false when an export of the
// cryptography module failed, with its error.
@(private)
connection_initial_keys_install :: proc "contextless" (connection: ^Connection, error: ^errors.Error_Record) -> bool {
	space := &connection.spaces[.Initial]
	client, server: Packet_Keys
	if !initial_keys(connection.cryptography, connection.original_destination_connection_id[:connection.original_destination_connection_id_length], &client, &server, error) {
		return false
	}
	if connection.configuration.tls.role == .Client {
		space.send_keys, space.receive_keys = client, server
	} else {
		space.send_keys, space.receive_keys = server, client
	}
	secret_erase(&client, size_of(client))
	secret_erase(&server, size_of(server))
	space.keys_installed = true
	return true
}

// connection_tls_start writes the transport parameters of this side and starts
// the handshake of TLS.
//
// The transport parameters (RFC 9000, section 18.2) state what this side
// allows the peer:
//
// - `max_idle_timeout`: the idle timeout of the configuration;
// - `max_udp_payload_size`: `DATAGRAM_LIMIT`, the largest datagram that the
//   library takes;
// - `initial_max_data`: the buffers of every stream record;
// - `initial_max_stream_data` for bidirectional streams, both kinds:
//   `STREAM_BUFFER_SIZE`;
// - `initial_max_streams_bidi`: the stream records of a server, and 0 for a
//   client, because only the client opens streams. Unidirectional streams get 0;
// - `initial_source_connection_id`: the identifier of this side;
// - a server also sends `disable_active_migration`,
//   `original_destination_connection_id`, and after a Retry
//   `retry_source_connection_id` (RFC 9000, section 7.3).
//
// It then starts TLS with them, and erases the private key of a server from
// the configuration of the connection: the handshake has its own copy. It
// gives false with `Too_Long` when the parameters do not fit
// `TRANSPORT_PARAMETERS_LIMIT`, or with the error of `tls_start`.
@(private)
connection_tls_start :: proc "contextless" (connection: ^Connection, error: ^errors.Error_Record) -> bool {
	parameters := &connection.local_parameters
	parameters^ = transport_parameters_default()
	parameters.max_idle_timeout = connection.configuration.idle_timeout_milliseconds
	parameters.max_udp_payload_size = DATAGRAM_LIMIT
	parameters.initial_max_data = connection.receive_window
	parameters.initial_max_stream_data_bidirectional_local = STREAM_BUFFER_SIZE
	parameters.initial_max_stream_data_bidirectional_remote = STREAM_BUFFER_SIZE
	// Only the client opens streams: a server allows the client one stream
	// for each of its records, a client allows the server none.
	parameters.initial_max_streams_bidirectional = connection.streams_limit_given
	parameters.initial_source_connection_id_length = copy(parameters.initial_source_connection_id[:], connection.local_connection_id[:])
	parameters.has_initial_source_connection_id = true
	if connection.configuration.tls.role == .Server {
		// A server of this library finds a connection by its identifier and
		// by the address and port of its client: the client must not move
		// to another address (RFC 9000, section 9).
		parameters.disable_active_migration = true
		// After a Retry the server names the identifier that the client
		// chose first, and the Source Connection ID of its Retry (RFC 9000,
		// section 7.3).
		if connection.retried {
			parameters.original_destination_connection_id_length = copy(parameters.original_destination_connection_id[:], connection.retry_first_destination_connection_id[:connection.retry_first_destination_connection_id_length])
			parameters.retry_source_connection_id_length = copy(parameters.retry_source_connection_id[:], connection.retry_source_connection_id[:connection.retry_source_connection_id_length])
			parameters.has_retry_source_connection_id = true
		} else {
			parameters.original_destination_connection_id_length = copy(parameters.original_destination_connection_id[:], connection.original_destination_connection_id[:connection.original_destination_connection_id_length])
		}
		parameters.has_original_destination_connection_id = true
	}
	tls_configuration := &connection.configuration.tls
	tls_configuration.transport_parameters_length = transport_parameters_write(parameters, tls_configuration.role, tls_configuration.transport_parameters[:])
	if tls_configuration.transport_parameters_length == 0 {
		return fail_at(error, .Too_Long, 1, TRANSPORT_PARAMETERS_LIMIT)
	}
	connection.tls_started = true
	started := tls_start(&connection.tls, tls_configuration, connection.cryptography, connection.generator, error)
	// The configuration of the connection keeps no copy of the private key
	// of a server: the handshake has its own.
	secret_erase(&tls_configuration.server_private_key, size_of(tls_configuration.server_private_key))
	return started
}

// connection_tls_progress carries what TLS produced into the transport: it
// moves the bytes that TLS wrote into the crypto streams, installs the keys
// that are ready, applies the transport parameters of the peer, and follows
// the state of TLS.
//
// The receive path calls it after each packet that was processed, and a client
// calls it at its start. It does nothing before TLS started and after the
// connection closed. In order:
//
// 1. The handshake bytes that TLS wrote for each level go to the end of
//   `Crypto_Stream.send` of that level. More than `CRYPTO_BUFFER_SIZE` bytes
//   close the connection with INTERNAL_ERROR.
// 2. When TLS has the Handshake or the 1-RTT keys, they are installed in their
//   space, once.
// 3. A failure of TLS closes the connection with `tls_failure_code`.
// 4. When the message of the peer that carries its transport parameters was
//   read, they are checked and applied, once.
// 5. When TLS is connected, the state becomes `Connected` and the secrets of
//   TLS are erased: each key is in its space. A server then confirms the
//   handshake: it queues HANDSHAKE_DONE and discards the Handshake space (RFC
//   9001, section 4.1.2).
@(private)
connection_tls_progress :: proc "contextless" (connection: ^Connection, now: u64) {
	if !connection.tls_started || connection.state == .Closing || connection.state == .Draining || connection.state == .Closed {
		return
	}
	tls := &connection.tls
	for level in Encryption_Level {
		bytes := tls_bytes_to_send(tls, level)
		if len(bytes) == 0 {
			continue
		}
		crypto := &connection.spaces[level].crypto
		if u64(len(bytes)) > CRYPTO_BUFFER_SIZE - crypto.send_length {
			connection_fail(connection, u64(Transport_Error.Internal_Error), FRAME_CRYPTO, now)
			return
		}
		copy(crypto.send[crypto.send_length:], bytes)
		crypto.send_length += u64(len(bytes))
		tls_bytes_sent(tls, level, len(bytes))
	}
	error: errors.Error_Record
	for level in ([]Encryption_Level{.Handshake, .Application}) {
		space := &connection.spaces[level]
		ready := level == .Handshake ? tls.handshake_keys_ready : tls.application_keys_ready
		if !ready || space.keys_installed || space.discarded {
			continue
		}
		if !tls_packet_keys(tls, level, true, &space.send_keys, &error) || !tls_packet_keys(tls, level, false, &space.receive_keys, &error) {
			connection_fail(connection, u64(Transport_Error.Internal_Error), 0, now)
			return
		}
		space.keys_installed = true
	}
	if tls.state == .Failed {
		connection_fail(connection, tls_failure_code(connection), FRAME_CRYPTO, now)
		return
	}
	if !connection.peer_parameters_applied && connection_peer_parameters_are_known(connection) {
		if !connection_peer_parameters_apply(connection, now) {
			return
		}
	}
	if tls.state == .Connected && connection.state == .Handshake {
		connection.state = .Connected
		// Each key is in its space: the secrets of TLS are no longer needed.
		tls_handshake_erase_secrets(tls)
		if connection.configuration.tls.role == .Server {
			// A server confirms the handshake when it completes, and tells
			// the client (RFC 9001, section 4.1.2).
			connection.handshake_confirmed = true
			connection.pending_controls += {.Handshake_Done}
			connection_space_discard(connection, .Handshake)
		}
	}
}

// tls_failure_code gives the error code of the CONNECTION_CLOSE for a failure
// of TLS.
//
// It is 0x100 plus the alert of TLS (`CRYPTO_ERROR_BASE`; RFC 9001, section
// 4.8): for example 0x100 + 42, bad_certificate, when the key of the server is
// not the pinned key. It is PROTOCOL_VIOLATION when handshake bytes came at a
// level whose keys were replaced (RFC 9001, section 4.1.3).
@(private)
tls_failure_code :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.tls.bytes_after_key_change {
		return u64(Transport_Error.Protocol_Violation)
	}
	return CRYPTO_ERROR_BASE + u64(connection.tls.alert)
}

// connection_peer_parameters_are_known says if TLS read the message that
// carries the transport parameters of the peer.
//
// They come in the ClientHello, which a server has read once it waits for the
// Finished of the client, or in the EncryptedExtensions of a server, which a
// client has read once it waits for the certificate. Before that state the
// bytes in `Tls_Handshake.peer_transport_parameters` are not there yet.
@(private)
connection_peer_parameters_are_known :: proc "contextless" (connection: ^Connection) -> bool {
	#partial switch connection.tls.state {
	case .Client_Waits_For_Certificate, .Client_Waits_For_Certificate_Verify, .Client_Waits_For_Finished, .Server_Waits_For_Finished, .Connected:
		return true
	}
	return false
}

// connection_peer_parameters_apply reads the transport parameters of the peer,
// checks them against what the packets carried, and puts them in effect.
//
// The handshake authenticates the transport parameters, and the packets
// carried connection identifiers that nothing authenticated. So the two must
// agree (RFC 9000, section 7.3):
//
// - `initial_source_connection_id` is the Source Connection ID of the packets
//   of the peer;
// - a client checks that `original_destination_connection_id` is the
//   identifier that it chose first;
// - a client checks that `retry_source_connection_id` is there if and only if
//   it took a Retry, and that it is the Source Connection ID of that Retry.
//
// A parameter that does not read, or an identifier that differs, closes the
// connection with the error code of `transport_parameters_read` or with
// TRANSPORT_PARAMETER_ERROR, and the result is false. Otherwise the limits of
// the peer take effect: its MAX_DATA, its limit of streams, its ack delay and
// exponent, and its idle timeout, of which the connection keeps the smaller of
// the two that are not 0 (RFC 9000, section 10.1). The limit of each stream is
// read from these parameters when the stream opens (`stream_record_take`).
@(private)
connection_peer_parameters_apply :: proc "contextless" (connection: ^Connection, now: u64) -> bool {
	peer_role := connection.configuration.tls.role == .Client ? Tls_Role.Server : Tls_Role.Client
	parameters := &connection.peer_parameters
	result := transport_parameters_read(connection.tls.peer_transport_parameters[:connection.tls.peer_transport_parameters_length], peer_role, parameters)
	if result != .No_Error {
		return connection_fail(connection, u64(result), 0, now)
	}
	// The identifiers that the packets carried must be the ones that the
	// handshake authenticated (RFC 9000, section 7.3).
	if !bytes_equal(parameters.initial_source_connection_id[:parameters.initial_source_connection_id_length], connection.peer_connection_id[:connection.peer_connection_id_length]) {
		return connection_fail(connection, u64(Transport_Error.Transport_Parameter_Error), 0, now)
	}
	if peer_role == .Server {
		// The server names the identifier that this client chose first; and,
		// when this client took a Retry, the Source Connection ID of that
		// Retry, and only then (RFC 9000, section 7.3).
		original := connection.original_destination_connection_id[:connection.original_destination_connection_id_length]
		if connection.retried {
			original = connection.retry_first_destination_connection_id[:connection.retry_first_destination_connection_id_length]
		}
		if !bytes_equal(parameters.original_destination_connection_id[:parameters.original_destination_connection_id_length], original) {
			return connection_fail(connection, u64(Transport_Error.Transport_Parameter_Error), 0, now)
		}
		retry_source := connection.retry_source_connection_id[:connection.retry_source_connection_id_length]
		if parameters.has_retry_source_connection_id != connection.retried || (connection.retried && !bytes_equal(parameters.retry_source_connection_id[:parameters.retry_source_connection_id_length], retry_source)) {
			return connection_fail(connection, u64(Transport_Error.Transport_Parameter_Error), 0, now)
		}
	}
	// The limit of each stream comes from these parameters when the stream
	// opens (stream_record_take).
	connection.peer_max_data = parameters.initial_max_data
	connection.peer_max_streams_bidirectional = parameters.initial_max_streams_bidirectional
	connection.peer_max_ack_delay = parameters.max_ack_delay * 1000
	connection.peer_ack_delay_exponent = parameters.ack_delay_exponent
	// The idle timeout is the smaller of the two that are not 0 (RFC 9000,
	// section 10.1).
	peer_idle := saturating_multiply(parameters.max_idle_timeout, 1000)
	if peer_idle != 0 && (connection.idle_timeout == 0 || peer_idle < connection.idle_timeout) {
		connection.idle_timeout = peer_idle
	}
	connection.peer_parameters_applied = true
	return true
}

// bytes_equal says if two byte slices have the same length and the same bytes.
//
// It compares connection identifiers, which are public values on the wire. It
// stops at the first byte that differs, so its time depends on the bytes: it
// is not for a secret.
bytes_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	for index in 0 ..< len(left) {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

// connection_fail closes the connection for an error of the transport: a frame
// of the peer that breaks a rule, a failure of TLS, or an internal error of
// this side (RFC 9000, section 10.2).
//
// The connection goes to the closing state, and the next
// `connection_datagram_send` writes a CONNECTION_CLOSE of type 0x1c with the
// code. In a state that is already closing, draining or closed it changes
// nothing: the first cause stays.
//
// - `code`: a `Transport_Error`, or `CRYPTO_ERROR_BASE` plus an alert of TLS.
// - `frame_type`: the type of the frame that caused it, or 0.
// - `now`: the time, in microseconds: the closing state lasts three probe
//   timeouts from it.
//
// **Result**: always false, so that a reader of frames writes `return
// connection_fail(...)`.
connection_fail :: proc "contextless" (connection: ^Connection, code: u64, frame_type: u64, now: u64) -> bool {
	if connection.state == .Closing || connection.state == .Draining || connection.state == .Closed {
		return false
	}
	connection.close_error_code = code
	connection.close_frame_type = frame_type
	connection.close_is_application = false
	connection_enter_closing(connection, now)
	return false
}

// connection_close closes the connection for the application, with an error
// code of the application.
//
// The connection goes to the closing state, and the next
// `connection_datagram_send` writes the CONNECTION_CLOSE. The caller goes on
// with its loop until the state is `Closed`: three probe timeouts later. In
// a 1-RTT packet the frame has the type 0x1d and carries
// `application_error_code`. In an Initial or a Handshake packet it goes as a
// transport close with APPLICATION_ERROR, so that no code of the application
// goes out before the handshake (RFC 9000, section 10.2.3;
// `close_frame_write`). It sends no reason phrase.
//
// It acts only in the states `Handshake` and `Connected`: a second call, or a
// call after the peer closed, changes nothing. The stream bytes that were not
// sent or not acknowledged are dropped: an application that wants them
// delivered ends each stream and waits for the end of the peer first.
//
// ```odin
// quic.connection_close(&connection, 0, now)
// ```
connection_close :: proc "contextless" (connection: ^Connection, application_error_code: u64, now: u64) {
	if connection.state != .Handshake && connection.state != .Connected {
		return
	}
	connection.close_error_code = application_error_code
	connection.close_frame_type = 0
	connection.close_is_application = true
	connection_enter_closing(connection, now)
}

// connection_enter_closing moves the connection to the closing state (RFC
// 9000, section 10.2.1).
//
// It asks for one CONNECTION_CLOSE now, starts the count of the datagrams of
// the peer that get an answer (the 1st, the 2nd, the 4th...), sets the end of
// the state at three probe timeouts with no backoff, and erases the secrets of
// TLS. The caller set the close code first.
@(private)
connection_enter_closing :: proc "contextless" (connection: ^Connection, now: u64) {
	connection.state = .Closing
	connection.close_to_send = true
	connection.close_datagrams_received = 0
	connection.close_next_answer = 1
	connection.close_deadline = saturating_add(now, saturating_multiply(3, probe_timeout_base(connection, .Application)))
	tls_handshake_erase_secrets(&connection.tls)
}

// connection_enter_draining moves the connection to the draining state, at a
// CONNECTION_CLOSE of the peer (RFC 9000, section 10.2.2).
//
// It keeps the code, the frame type and the kind of the close of the peer for
// the program, sends nothing more (a CONNECTION_CLOSE of this side that waited
// is dropped), sets the end of the state at three probe timeouts with no
// backoff, and erases the secrets of TLS. `application` is true for a frame of
// type 0x1d.
@(private)
connection_enter_draining :: proc "contextless" (connection: ^Connection, code: u64, frame_type: u64, application: bool, now: u64) {
	connection.closed_by_peer = true
	connection.close_error_code = code
	connection.close_frame_type = frame_type
	connection.close_is_application = application
	connection.state = .Draining
	connection.close_to_send = false
	connection.close_deadline = saturating_add(now, saturating_multiply(3, probe_timeout_base(connection, .Application)))
	tls_handshake_erase_secrets(&connection.tls)
}

// connection_end makes the connection `Closed`: it notes the time in
// `ended_at`, and erases the keys of every packet number space and the secrets
// of TLS.
//
// It sends nothing. The idle timeout, the handshake deadline and the end of
// the closing and draining states call it. The stream records keep their bytes
// until the next start of the record, which erases them.
@(private)
connection_end :: proc "contextless" (connection: ^Connection, now: u64) {
	connection.state = .Closed
	connection.ended_at = now
	for level in Encryption_Level {
		space := &connection.spaces[level]
		secret_erase(&space.send_keys, size_of(space.send_keys))
		secret_erase(&space.receive_keys, size_of(space.receive_keys))
		space.keys_installed = false
	}
	tls_handshake_erase_secrets(&connection.tls)
}

// connection_space_discard drops a packet number space: its keys are erased,
// and each packet of it that waits for an acknowledgement is forgotten (RFC
// 9001, section 4.9; RFC 9002, section 6.4).
//
// The bytes of those packets leave `Connection.bytes_in_flight`, the timers of
// the space stop, and the count of probe timeouts goes back to 0. From then on
// the space sends nothing, and a packet of the peer at its level is dropped. A
// second call for the same space does nothing.
//
// The connection calls it for the Initial space when a client first sends a
// Handshake packet and when a server first opens one, and for the Handshake
// space when the handshake is confirmed.
connection_space_discard :: proc "contextless" (connection: ^Connection, level: Encryption_Level) {
	space := &connection.spaces[level]
	if space.discarded {
		return
	}
	space.discarded = true
	for &packet in space.sent {
		if packet.in_use {
			connection.bytes_in_flight -= min(packet.size, connection.bytes_in_flight)
			packet.in_use = false
		}
	}
	space.ack_eliciting_in_flight = 0
	space.loss_time = 0
	space.probes = 0
	space.ack_needed = false
	secret_erase(&space.send_keys, size_of(space.send_keys))
	secret_erase(&space.receive_keys, size_of(space.receive_keys))
	connection.probe_timeout_count = 0
}

// connection_deadline gives the time, in microseconds, at which the caller
// calls `connection_time_passes`.
//
// It is the earliest of: the idle timeout, the handshake deadline during the
// handshake, the loss detection timer (the time threshold or the probe
// timeout), and the delay of an ACK frame of the 1-RTT space. In the closing
// and draining states it is the end of the state.
//
// **Result**: the time, or `NO_DEADLINE` when nothing waits: an idle or closed
// record, and a server record before its first Initial packet. The time can be
// in the past: the caller then calls `connection_time_passes` at once. The
// deadline changes at each receive, each send and each call of
// `connection_time_passes`: read it again before each wait.
//
// ```odin
// deadline := quic.connection_deadline(&connection)
// // ... wait for a datagram until deadline ...
// quic.connection_time_passes(&connection, now)
// ```
connection_deadline :: proc "contextless" (connection: ^Connection) -> u64 {
	switch connection.state {
	case .Idle, .Closed:
		return NO_DEADLINE
	case .Closing, .Draining:
		return connection.close_deadline
	case .Handshake, .Connected:
	}
	if !connection.tls_started {
		// A server that waits for its first Initial has no timer.
		return NO_DEADLINE
	}
	deadline := connection_idle_deadline(connection)
	loss, _, _ := loss_detection_deadline(connection)
	deadline = min(deadline, loss)
	if connection.state == .Handshake {
		deadline = min(deadline, connection.handshake_deadline)
	}
	application := &connection.spaces[.Application]
	if application.ack_needed && application.ack_deadline < deadline {
		deadline = application.ack_deadline
	}
	return deadline
}

// connection_idle_deadline gives the time at which the idle timeout ends the
// connection: the last activity plus `connection_idle_bound`. `NO_DEADLINE`
// when the connection has no idle timeout.
@(private)
connection_idle_deadline :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.idle_timeout == 0 {
		return NO_DEADLINE
	}
	// At least three probe timeouts, so that a loss does not end a
	// connection that works (RFC 9000, section 10.1: "three times the
	// current Probe Timeout"). The timeout here has no backoff: with the
	// backoff, each probe that the silent peer does not answer doubles the
	// bound, the bound moves past each next probe, and the connection lives
	// until the backoff stops (hours), holding its record. With no backoff,
	// a connection that receives nothing ends at most max(idle timeout,
	// 3 × base probe timeout) after its last activity, whatever the count
	// of probes. The activity is a packet received and processed, or the
	// first ack-eliciting packet sent after it (connection_send.odin); a
	// later probe does not move it.
	return saturating_add(connection.last_activity, connection_idle_bound(connection))
}

// connection_idle_bound gives the time after the last activity at which a
// connection that receives nothing ends, in microseconds: the larger of its
// idle timeout and three probe timeouts with no backoff (RFC 9000, section
// 10.1).
//
// The three probe timeouts keep a connection that works alive through a loss.
// They use `probe_timeout_base`, not the timeout with its backoff: the bound
// then does not grow while the peer is silent. A program compares this value
// with the time that an idle end took (`Connection.ended_at` less
// `Connection.last_activity`). The value has a meaning only when
// `Connection.idle_timeout` is not 0.
connection_idle_bound :: proc "contextless" (connection: ^Connection) -> u64 {
	return max(connection.idle_timeout, saturating_multiply(3, probe_timeout_base(connection, .Application)))
}

// connection_time_passes acts on each deadline that passed: the caller calls
// it when the time of `connection_deadline` came.
//
// - `now`: the time, in microseconds. A call before any deadline changes
//   nothing.
//
// What it does, the first case that applies:
//
// - **Closing, draining**: at the end of the state, the connection is
//   `Closed`.
// - **The handshake deadline**: the handshake did not complete in
//   `HANDSHAKE_TIME_LIMIT`. The connection is `Closed`, with no packet;
//   `closed_by_handshake_timeout` is true.
// - **The idle timeout**: the connection is `Closed`, with no packet (RFC
//   9000, section 10.1); `closed_by_idle_timeout` is true.
// - **The loss detection timer**: packets past the time threshold are declared
//   lost, or a probe timeout asks for two probes (`loss_detection_timeout`).
//
// It writes no datagram itself. After it, the caller calls
// `connection_datagram_send` until it gives 0: the probes, the data of lost
// packets and an ACK frame whose delay passed go out there.
connection_time_passes :: proc "contextless" (connection: ^Connection, now: u64) {
	switch connection.state {
	case .Idle, .Closed:
		return
	case .Closing, .Draining:
		if now >= connection.close_deadline {
			connection_end(connection, now)
		}
		return
	case .Handshake, .Connected:
	}
	if !connection.tls_started {
		return
	}
	if connection.state == .Handshake && now >= connection.handshake_deadline {
		connection.closed_by_handshake_timeout = true
		connection_end(connection, now)
		return
	}
	if now >= connection_idle_deadline(connection) {
		// The idle timeout ends the connection with no packet (RFC 9000,
		// section 10.1).
		connection.closed_by_idle_timeout = true
		connection_end(connection, now)
		return
	}
	loss_detection_timeout(connection, now)
}
