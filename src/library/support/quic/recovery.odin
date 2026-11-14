package quic

// Acknowledgements and loss detection (RFC 9002): the round-trip time, the
// packet threshold and the time threshold, and the probe timeout.
//
// QUIC sends over UDP, which loses, repeats and reorders datagrams. This file
// decides which packets of this side the peer got, which ones are lost, and
// when to try again:
//
// - An ACK frame of the peer names the packets that it got
//   (`acknowledgement_receive`). The newest one gives a sample of the round-trip
//   time (`round_trip_update`).
// - A packet below an acknowledged one is lost when it is 3 packets older, or
//   older than 9/8 of the round-trip time (`loss_detect`). What it carried goes
//   again in a new packet (`sent_packet_lost`).
// - When nothing is acknowledged for a probe timeout, this side sends probes
//   to make the peer answer (`loss_detection_timeout`). The probe timeout
//   doubles each time.
//
// The procedures follow the pseudocode of RFC 9002, appendix A, with the names
// of this library. This file also holds the anti-amplification limit
// (`amplification_budget`) and the sums of times that cannot wrap.

// An acknowledged range of packet numbers, read from an ACK frame: [smallest,
// largest], both included.
//
// Both ends are in the range, unlike a range of a `Range_Set`: the ACK frame
// of RFC 9000, section 19.3.1, counts this way, and a range of one packet has
// `smallest` equal to `largest`.
Acknowledged_Range :: struct {
	smallest: u64, // The smallest packet number of the range.
	largest:  u64, // The largest packet number of the range.
}

// acknowledgement_receive acts on the ranges of an ACK frame of the peer in
// one packet number space (RFC 9002, appendix A.7).
//
// **Parameters**
//
// - `level`: the space of the packet that carried the frame: an ACK frame
//   acknowledges packets of its own space only.
// - `ranges`: the acknowledged ranges, `ACK_RANGES_READ_LIMIT` at most.
// - `largest`: the Largest Acknowledged field. The frame reader already
//   refused a number that this side never sent.
// - `encoded_ack_delay`: the ACK Delay field, as it is on the wire.
// - `now`: the time, in microseconds.
//
// **What it does**
//
// 1. Each packet in flight that a range names is acknowledged: its data is
//   noted, and its place is free (`sent_packet_acknowledged`).
// 2. When the largest acknowledged packet is one of them, the time since it
//   went is a sample of the round-trip time (RFC 9002, section 5.1). In the
//   1-RTT space the delay of the peer is subtracted: the field times 2 to the
//   `ack_delay_exponent` of the peer, and at most its `max_ack_delay`, in every
//   state, so that a large value of the peer cannot move the round-trip time.
// 3. Loss detection runs on the space: an acknowledgement is what shows that
//   older packets are lost.
// 4. The count of probe timeouts goes back to 0, unless this side is a client
//   that does not know yet that the server validated its address.
//
// A frame that acknowledges no packet in flight (a frame that came again) only
// moves the largest acknowledged number.
acknowledgement_receive :: proc "contextless" (connection: ^Connection, level: Encryption_Level, ranges: []Acknowledged_Range, largest: u64, encoded_ack_delay: u64, now: u64) {
	space := &connection.spaces[level]
	newly_acknowledged := false
	largest_newly_acknowledged := false
	largest_time_sent: u64
	for &packet in space.sent {
		if !packet.in_use || !ranges_contain(ranges, packet.packet_number) {
			continue
		}
		if packet.packet_number == largest {
			largest_newly_acknowledged = true
			largest_time_sent = packet.time_sent
		}
		newly_acknowledged = true
		sent_packet_acknowledged(connection, level, &packet)
	}
	if !space.has_acknowledged || largest > space.largest_acknowledged {
		space.largest_acknowledged = largest
		space.has_acknowledged = true
	}
	if !newly_acknowledged {
		return
	}
	// Only ack-eliciting packets are kept, so the largest one, when it is
	// newly acknowledged, gives a sample (RFC 9002, section 5.1).
	if largest_newly_acknowledged && now >= largest_time_sent {
		ack_delay: u64
		if level == .Application {
			// The delay of the peer, in microseconds, at most its
			// max_ack_delay (RFC 9002, section 5.3). The Initial and
			// Handshake spaces have no delay.
			// It is at most the max_ack_delay of the peer in every state:
			// before the handshake is confirmed too, so that a large value
			// cannot move the round-trip time.
			exponent := uint(connection.peer_ack_delay_exponent)
			ack_delay = encoded_ack_delay > (max(u64) >> exponent) ? max(u64) : encoded_ack_delay << exponent
			ack_delay = min(ack_delay, connection.peer_max_ack_delay)
		}
		round_trip_update(connection, now - largest_time_sent, ack_delay)
	}
	if level == .Handshake && connection.configuration.tls.role == .Client {
		connection.client_received_handshake_ack = true
	}
	loss_detect(connection, level, now)
	if peer_completed_address_validation(connection) {
		connection.probe_timeout_count = 0
	}
}

// ranges_contain says if a packet number is in one of the acknowledged ranges
// of an ACK frame.
@(private)
ranges_contain :: proc "contextless" (ranges: []Acknowledged_Range, value: u64) -> bool {
	for acknowledged in ranges {
		if value >= acknowledged.smallest && value <= acknowledged.largest {
			return true
		}
	}
	return false
}

// sent_packet_acknowledged notes the data of a packet as acknowledged and
// removes the packet from the packets in flight.
//
// - The range of handshake bytes and the range of stream bytes go into the
//   sets of acknowledged bytes. The acknowledged bytes of a stream leave room in
//   its send ring.
// - A FIN bit and a RESET_STREAM that the packet carried are noted on their
//   stream.
// - A stream whose two directions ended by this acknowledgement frees its
//   record (`stream_release_when_ended`).
//
// When a range set has no place for its data, the packet stays in flight: loss
// detection then sends its data again, and a later acknowledgement notes it. A
// stream that ended since the packet went has nothing to note.
@(private)
sent_packet_acknowledged :: proc "contextless" (connection: ^Connection, level: Encryption_Level, packet: ^Sent_Packet) {
	space := &connection.spaces[level]
	noted := true
	if packet.crypto_length > 0 && !range_set_insert(&space.crypto.send_acknowledged, packet.crypto_offset, packet.crypto_offset + packet.crypto_length) {
		noted = false
	}
	stream: ^Stream
	if packet.stream_length > 0 || packet.stream_finish {
		stream = stream_of(connection, packet.stream_identifier)
	}
	if stream != nil && packet.stream_length > 0 && !range_set_insert(&stream.send_acknowledged, packet.stream_offset, packet.stream_offset + packet.stream_length) {
		noted = false
	}
	if !noted {
		return
	}
	if stream != nil && packet.stream_finish {
		stream.finish_acknowledged = true
	}
	controlled: ^Stream
	if packet.stream_controls != {} {
		controlled = stream_of(connection, packet.stream_controls_identifier)
	}
	if controlled != nil && .Reset_Stream in packet.stream_controls {
		controlled.reset_acknowledged = true
	}
	sent_packet_remove(connection, space, packet)
	if stream != nil {
		stream_release_when_ended(connection, stream)
	}
	if controlled != nil {
		stream_release_when_ended(connection, controlled)
	}
}

// sent_packet_remove frees the place of a packet that was acknowledged,
// declared lost or forgotten: its bytes leave `Connection.bytes_in_flight`,
// and the space counts one packet fewer in flight.
@(private)
sent_packet_remove :: proc "contextless" (connection: ^Connection, space: ^Packet_Number_Space, packet: ^Sent_Packet) {
	connection.bytes_in_flight -= min(packet.size, connection.bytes_in_flight)
	space.ack_eliciting_in_flight -= 1
	packet.in_use = false
}

// sent_packet_lost puts what a lost packet carried back to be sent, and
// removes the packet from the packets in flight (RFC 9000, section 13.3).
//
// QUIC never sends a packet again: it sends the information again, in a new
// packet with a new number.
//
// - **Data**: the ranges of handshake bytes and of stream bytes go to the sets
//   `send_again` (`sent_packet_send_again`).
// - **The end of a stream**: the FIN bit goes again, unless another packet
//   that carried it was acknowledged.
// - **Control frames**: they wait again, and go with their values of that
//   time. A PATH_RESPONSE is not sent again. A RESET_STREAM that another packet
//   got acknowledged is not sent again.
//
// When a range set has no place for its data, the packet stays in flight: the
// next loss detection or probe tries again.
@(private)
sent_packet_lost :: proc "contextless" (connection: ^Connection, level: Encryption_Level, packet: ^Sent_Packet) {
	space := &connection.spaces[level]
	if !sent_packet_send_again(connection, level, packet) {
		return
	}
	if packet.stream_finish {
		if stream := stream_of(connection, packet.stream_identifier); stream != nil && !stream.finish_acknowledged {
			stream.finish_sent = false
		}
	}
	connection.pending_controls += packet.controls - {.Path_Response}
	if packet.stream_controls != {} {
		if controlled := stream_of(connection, packet.stream_controls_identifier); controlled != nil {
			// Each frame goes again with the current value; a reset that
			// was acknowledged by another packet does not.
			again := packet.stream_controls
			if controlled.reset_acknowledged {
				again -= {.Reset_Stream}
			}
			controlled.pending_controls += again
		}
	}
	sent_packet_remove(connection, space, packet)
}

// sent_packet_send_again puts the data of a packet back to be sent: when it is
// lost, and for a probe.
//
// A probe uses it on a packet that stays in flight: if the first copy arrives
// after all, the peer gets the bytes two times, which is harmless. The bytes
// of a stream that ended, or that this side reset, are not sent again.
//
// It gives false when a range set had no place for the data.
@(private)
sent_packet_send_again :: proc "contextless" (connection: ^Connection, level: Encryption_Level, packet: ^Sent_Packet) -> bool {
	space := &connection.spaces[level]
	placed := true
	if packet.crypto_length > 0 && !range_set_insert(&space.crypto.send_again, packet.crypto_offset, packet.crypto_offset + packet.crypto_length) {
		placed = false
	}
	if packet.stream_length > 0 {
		stream := stream_of(connection, packet.stream_identifier)
		if stream != nil && !stream.reset_sent && !range_set_insert(&stream.send_again, packet.stream_offset, packet.stream_offset + packet.stream_length) {
			placed = false
		}
	}
	return placed
}

// round_trip_update takes one sample of the round-trip time (RFC 9002, section
// 5.3).
//
// - `latest`: the time from the sending of the largest acknowledged packet to
//   its ACK frame, in microseconds.
// - `ack_delay`: the time that the peer held its ACK frame, in microseconds,
//   already bounded by its `max_ack_delay`.
//
// The first sample sets the smoothed round-trip time to itself and the
// variation to half of it. Each later sample moves the smoothed value by 1/8
// and the variation by 1/4. The delay of the peer is subtracted from a sample
// only when the result stays at or above the smallest sample: a peer that
// reports too large a delay cannot push the estimate below a time that was
// really measured. The sums saturate, so no value of the peer wraps them.
@(private)
round_trip_update :: proc "contextless" (connection: ^Connection, latest: u64, ack_delay: u64) {
	connection.latest_round_trip = latest
	if !connection.has_round_trip_sample {
		connection.has_round_trip_sample = true
		connection.min_round_trip = latest
		connection.smoothed_round_trip = latest
		connection.round_trip_variation = latest / 2
		return
	}
	connection.min_round_trip = min(connection.min_round_trip, latest)
	adjusted := latest
	// min_round_trip <= latest: the subtraction cannot wrap, where the sum
	// min_round_trip + ack_delay could.
	if latest - connection.min_round_trip >= ack_delay {
		adjusted = latest - ack_delay
	}
	difference := connection.smoothed_round_trip > adjusted ? connection.smoothed_round_trip - adjusted : adjusted - connection.smoothed_round_trip
	connection.round_trip_variation = saturating_add(saturating_multiply(3, connection.round_trip_variation), difference) / 4
	connection.smoothed_round_trip = saturating_add(saturating_multiply(7, connection.smoothed_round_trip), adjusted) / 8
}

// loss_detect declares lost the packets of a space that the peer most likely
// did not get, and sets the time of the next check for the others (RFC 9002,
// section 6.1 and appendix A.10).
//
// Only a packet below the largest acknowledged number can be lost: the peer
// got a later packet, so the earlier one had its chance. Such a packet is lost
// when:
//
// - **the packet threshold**: the largest acknowledged number is
//   `PACKET_THRESHOLD` (3) or more above its number;
// - **the time threshold**: it went more than 9/8 of the round-trip time ago,
//   where the round-trip time is the larger of the latest sample and the
//   smoothed value, and the threshold is `GRANULARITY` at least.
//
// A packet below the largest acknowledged number that passed neither threshold
// may only be late. `Packet_Number_Space.loss_time` then holds the time at
// which the oldest of them passes the time threshold, and the loss detection
// timer calls this again.
@(private)
loss_detect :: proc "contextless" (connection: ^Connection, level: Encryption_Level, now: u64) {
	space := &connection.spaces[level]
	space.loss_time = 0
	if !space.has_acknowledged {
		return
	}
	round_trip := max(connection.latest_round_trip, connection.has_round_trip_sample ? connection.smoothed_round_trip : INITIAL_ROUND_TRIP_TIME)
	loss_delay := max(saturating_multiply(round_trip, TIME_THRESHOLD_NUMERATOR) / TIME_THRESHOLD_DENOMINATOR, GRANULARITY)
	for &packet in space.sent {
		if !packet.in_use || packet.packet_number > space.largest_acknowledged {
			continue
		}
		when_lost := saturating_add(packet.time_sent, loss_delay)
		if now >= when_lost || space.largest_acknowledged >= packet.packet_number + PACKET_THRESHOLD {
			sent_packet_lost(connection, level, &packet)
			continue
		}
		if space.loss_time == 0 || when_lost < space.loss_time {
			space.loss_time = when_lost
		}
	}
}

// peer_completed_address_validation says if this side knows that the peer
// validated its address (RFC 9002, appendix A.8).
//
// A server always gives true: a client validates the address of a server by
// the handshake itself. A client knows it when the server acknowledged a
// Handshake packet or confirmed the handshake. Until then the server can be
// stopped by its anti-amplification limit, so the client keeps a timer and
// probes, even with nothing in flight (RFC 9002, section 6.2.2.1).
@(private)
peer_completed_address_validation :: proc "contextless" (connection: ^Connection) -> bool {
	if connection.configuration.tls.role == .Server {
		return true
	}
	return connection.client_received_handshake_ack || connection.handshake_confirmed
}

// probe_timeout_base gives the probe timeout of a space from the round-trip
// time alone, with no backoff, in microseconds (RFC 9002, section 6.2.1).
//
// It is the smoothed round-trip time, plus the larger of 4 times its variation
// and `GRANULARITY`, plus, in the 1-RTT space, the `max_ack_delay` of the
// peer, because the peer can hold its ACK frame that long. Before the first
// sample it uses `INITIAL_ROUND_TRIP_TIME`, which gives about 1 s.
//
// The idle timeout and the closing and draining states use this one: the
// backoff doubles at each probe that nothing answers, so a bound made with it
// grows as fast as the probes come, and a peer that went silent would never
// meet it.
probe_timeout_base :: proc "contextless" (connection: ^Connection, level: Encryption_Level) -> u64 {
	smoothed := connection.has_round_trip_sample ? connection.smoothed_round_trip : INITIAL_ROUND_TRIP_TIME
	variation := connection.has_round_trip_sample ? connection.round_trip_variation : INITIAL_ROUND_TRIP_TIME / 2
	duration := saturating_add(smoothed, max(saturating_multiply(4, variation), GRANULARITY))
	if level == .Application {
		duration = saturating_add(duration, connection.peer_max_ack_delay)
	}
	return duration
}

// probe_timeout_duration gives the probe timeout of a space with its backoff,
// in microseconds (RFC 9002, section 6.2.1): the time from the last
// ack-eliciting packet to the next probe.
//
// It is `probe_timeout_base` times 2 to the count of probe timeouts in a row
// (`Connection.probe_timeout_count`), with the exponent held at 16. The result
// saturates at the largest time.
probe_timeout_duration :: proc "contextless" (connection: ^Connection, level: Encryption_Level) -> u64 {
	duration := probe_timeout_base(connection, level)
	backoff := uint(min(connection.probe_timeout_count, 16))
	if duration > max(u64) >> backoff {
		return max(u64)
	}
	return duration << backoff
}

// saturating_add gives the sum of two times, or the largest value when the sum
// does not fit.
//
// The sums and products of times saturate at the largest value, which is
// `NO_DEADLINE`: a value that the peer chose (an idle timeout, an ack delay)
// cannot wrap a deadline into the past.
saturating_add :: proc "contextless" (left, right: u64) -> u64 {
	return left > max(u64) - right ? max(u64) : left + right
}

// saturating_multiply gives the product of two counts, or the largest value
// when the product does not fit: see `saturating_add`.
saturating_multiply :: proc "contextless" (left, right: u64) -> u64 {
	if left != 0 && right > max(u64) / left {
		return max(u64)
	}
	return left * right
}

// amplification_budget gives the bytes that a server may still send to an
// address that it did not validate: 3 times the bytes that came, less the
// bytes that went (RFC 9000, section 8.1).
//
// A client address in a datagram can be forged. Without this limit, a small
// datagram with the address of a victim would make a server send its much
// larger handshake to the victim. The limit ends when the address is
// validated: the largest value then says that no limit applies, as it always
// does for a client.
//
// The bytes that came are those of the datagrams of which a packet was
// processed: fewer than the RFC allows, and safe. `connection_datagram_send`
// writes no datagram larger than this budget, and the loss detection timer
// stops while it is under one datagram.
amplification_budget :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.address_validated {
		return max(u64)
	}
	limit := 3 * connection.bytes_received
	return limit > connection.bytes_sent ? limit - connection.bytes_sent : 0
}

// loss_detection_deadline gives the time of the loss detection timer, its
// packet number space, and whether it is a probe timeout (RFC 9002, appendix
// A.8).
//
// One timer serves the three spaces. In order:
//
// 1. **The time threshold.** When a space has a packet that waits for the time
//   threshold, the earliest `loss_time` is the deadline, and `probe` is false.
// 2. **A server under the anti-amplification limit** that cannot send one
//   datagram has no timer: a probe could not go (RFC 9002, section 6.2.2.1).
// 3. **Nothing in flight.** No timer, unless this side is a client that does
//   not know that the server validated its address. That client probes in the
//   Handshake space when it has its keys, else in the Initial space, one probe
//   timeout after its last datagram: the probe gives the server bytes to send
//   against.
// 4. **A probe timeout.** The earliest, over the spaces with packets in
//   flight, of the last ack-eliciting packet plus `probe_timeout_duration`. The
//   1-RTT space waits until the handshake is confirmed.
//
// **Results**: `deadline`, or `NO_DEADLINE` when no timer runs; `level`, the
// space to act on; `probe`, true for a probe timeout.
loss_detection_deadline :: proc "contextless" (connection: ^Connection) -> (deadline: u64, level: Encryption_Level, probe: bool) {
	deadline = NO_DEADLINE
	for &space, space_level in connection.spaces {
		if space.loss_time != 0 && space.loss_time < deadline {
			deadline, level = space.loss_time, space_level
		}
	}
	if deadline != NO_DEADLINE {
		return deadline, level, false
	}
	// A server that cannot send stops its timer (RFC 9002, section 6.2.2.1).
	if amplification_budget(connection) < MAX_DATAGRAM_SIZE {
		return NO_DEADLINE, .Initial, false
	}
	in_flight := 0
	for &space in connection.spaces {
		in_flight += space.ack_eliciting_in_flight
	}
	if in_flight == 0 {
		if peer_completed_address_validation(connection) {
			return NO_DEADLINE, .Initial, false
		}
		// A client probes so that the server, bound by its amplification
		// limit, can send again (RFC 9002, section 6.2.2.1).
		handshake := &connection.spaces[.Handshake]
		level = handshake.keys_installed && !handshake.discarded ? Encryption_Level.Handshake : Encryption_Level.Initial
		if connection.spaces[level].discarded {
			return NO_DEADLINE, .Initial, false
		}
		return saturating_add(connection.last_sent_time, probe_timeout_duration(connection, level)), level, true
	}
	for &space, space_level in connection.spaces {
		if space.ack_eliciting_in_flight == 0 {
			continue
		}
		if space_level == .Application && !connection.handshake_confirmed {
			continue
		}
		when_probe := saturating_add(space.last_ack_eliciting_sent_time, probe_timeout_duration(connection, space_level))
		if when_probe < deadline {
			deadline, level = when_probe, space_level
		}
	}
	return deadline, level, deadline != NO_DEADLINE
}

// loss_detection_timeout acts on the loss detection timer when it passed (RFC
// 9002, appendix A.9). `connection_time_passes` calls it.
//
// - **The time threshold**: `loss_detect` runs on the space, and declares lost
//   the packets that are now too old.
// - **A probe timeout**: the space owes `PROBE_PACKETS` probes, and the count
//   of probe timeouts grows, which doubles the next probe timeout. The data of
//   the two oldest packets in flight is put back to be sent, so each probe
//   carries data that the peer may miss; with no such data a probe is a PING
//   (RFC 9002, section 6.2.4). The packets stay in flight: a probe timeout does
//   not declare a loss.
//
// It writes no datagram: the next calls of `connection_datagram_send` send the
// probes, past the congestion window. A call before the deadline does nothing.
loss_detection_timeout :: proc "contextless" (connection: ^Connection, now: u64) {
	deadline, level, probe := loss_detection_deadline(connection)
	if deadline == NO_DEADLINE || now < deadline {
		return
	}
	if !probe {
		loss_detect(connection, level, now)
		return
	}
	space := &connection.spaces[level]
	space.probes = PROBE_PACKETS
	// The packet that was chosen stays in flight: the next one chosen has a
	// larger number.
	chosen_before := false
	chosen_number: u64
	for _ in 0 ..< PROBE_PACKETS {
		oldest: ^Sent_Packet
		for &packet in space.sent {
			if !packet.in_use || (chosen_before && packet.packet_number <= chosen_number) {
				continue
			}
			if oldest == nil || packet.packet_number < oldest.packet_number {
				oldest = &packet
			}
		}
		if oldest == nil {
			break
		}
		sent_packet_send_again(connection, level, oldest)
		chosen_before, chosen_number = true, oldest.packet_number
	}
	connection.probe_timeout_count += 1
}
