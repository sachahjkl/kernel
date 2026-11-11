package quic

// Acknowledgements and loss detection (RFC 9002): the round-trip time,
// the packet threshold and the time threshold, and the probe timeout. The
// procedures follow the pseudocode of RFC 9002, appendix A, with the names
// of this library.

// An acknowledged range of packet numbers, read from an ACK frame:
// [smallest, largest], both included.
Acknowledged_Range :: struct {
	smallest: u64,
	largest:  u64,
}

// acknowledgement_receive acts on the ranges of an ACK frame of the peer in
// one space. largest is the Largest Acknowledged field; the frame reader
// already refused a number that this side never sent.
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
			exponent := uint(connection.peer_ack_delay_exponent)
			ack_delay = encoded_ack_delay > (max(u64) >> exponent) ? max(u64) : encoded_ack_delay << exponent
			if connection.handshake_confirmed {
				ack_delay = min(ack_delay, connection.peer_max_ack_delay)
			}
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

@(private)
ranges_contain :: proc "contextless" (ranges: []Acknowledged_Range, value: u64) -> bool {
	for acknowledged in ranges {
		if value >= acknowledged.smallest && value <= acknowledged.largest {
			return true
		}
	}
	return false
}

@(private)
sent_packet_acknowledged :: proc "contextless" (connection: ^Connection, level: Encryption_Level, packet: ^Sent_Packet) {
	space := &connection.spaces[level]
	if packet.crypto_length > 0 {
		range_set_insert(&space.crypto.send_acknowledged, packet.crypto_offset, packet.crypto_offset + packet.crypto_length)
	}
	if packet.stream_length > 0 {
		range_set_insert(&connection.stream.send_acknowledged, packet.stream_offset, packet.stream_offset + packet.stream_length)
	}
	if packet.stream_finish {
		connection.stream.finish_acknowledged = true
	}
	sent_packet_remove(connection, space, packet)
}

@(private)
sent_packet_remove :: proc "contextless" (connection: ^Connection, space: ^Packet_Number_Space, packet: ^Sent_Packet) {
	connection.bytes_in_flight -= min(packet.size, connection.bytes_in_flight)
	space.ack_eliciting_in_flight -= 1
	packet.in_use = false
}

// sent_packet_lost puts what a lost packet carried back to be sent: its
// data, and its control frames with their current values. A PATH_RESPONSE
// is not sent again (RFC 9000, section 13.3).
@(private)
sent_packet_lost :: proc "contextless" (connection: ^Connection, level: Encryption_Level, packet: ^Sent_Packet) {
	space := &connection.spaces[level]
	sent_packet_send_again(connection, level, packet)
	if packet.stream_finish && !connection.stream.finish_acknowledged {
		connection.stream.finish_sent = false
	}
	connection.pending_controls += packet.controls - {.Path_Response}
	sent_packet_remove(connection, space, packet)
}

// sent_packet_send_again puts the data of a packet back to be sent: when it
// is lost, and for a probe.
@(private)
sent_packet_send_again :: proc "contextless" (connection: ^Connection, level: Encryption_Level, packet: ^Sent_Packet) {
	space := &connection.spaces[level]
	if packet.crypto_length > 0 {
		range_set_insert(&space.crypto.send_again, packet.crypto_offset, packet.crypto_offset + packet.crypto_length)
	}
	if packet.stream_length > 0 {
		range_set_insert(&connection.stream.send_again, packet.stream_offset, packet.stream_offset + packet.stream_length)
	}
}

// round_trip_update takes one sample (RFC 9002, section 5.3).
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
	if latest >= connection.min_round_trip + ack_delay {
		adjusted = latest - ack_delay
	}
	difference := connection.smoothed_round_trip > adjusted ? connection.smoothed_round_trip - adjusted : adjusted - connection.smoothed_round_trip
	connection.round_trip_variation = (3 * connection.round_trip_variation + difference) / 4
	connection.smoothed_round_trip = (7 * connection.smoothed_round_trip + adjusted) / 8
}

// loss_detect declares lost each packet below the largest acknowledged one
// that is 3 packets older, or older than 9/8 of the round-trip time; for the
// others it sets the time of the next check (RFC 9002, section 6.1).
@(private)
loss_detect :: proc "contextless" (connection: ^Connection, level: Encryption_Level, now: u64) {
	space := &connection.spaces[level]
	space.loss_time = 0
	if !space.has_acknowledged {
		return
	}
	round_trip := max(connection.latest_round_trip, connection.has_round_trip_sample ? connection.smoothed_round_trip : INITIAL_ROUND_TRIP_TIME)
	loss_delay := max(round_trip * TIME_THRESHOLD_NUMERATOR / TIME_THRESHOLD_DENOMINATOR, GRANULARITY)
	for &packet in space.sent {
		if !packet.in_use || packet.packet_number > space.largest_acknowledged {
			continue
		}
		if now >= packet.time_sent + loss_delay || space.largest_acknowledged >= packet.packet_number + PACKET_THRESHOLD {
			sent_packet_lost(connection, level, &packet)
			continue
		}
		when_lost := packet.time_sent + loss_delay
		if space.loss_time == 0 || when_lost < space.loss_time {
			space.loss_time = when_lost
		}
	}
}

// peer_completed_address_validation: a client knows it when the server
// acknowledged a Handshake packet or confirmed the handshake (RFC 9002,
// appendix A.6).
@(private)
peer_completed_address_validation :: proc "contextless" (connection: ^Connection) -> bool {
	if connection.configuration.tls.role == .Server {
		return true
	}
	return connection.client_received_handshake_ack || connection.handshake_confirmed
}

// probe_timeout_duration gives the probe timeout of a space, with its
// backoff (RFC 9002, section 6.2.1).
probe_timeout_duration :: proc "contextless" (connection: ^Connection, level: Encryption_Level) -> u64 {
	smoothed := connection.has_round_trip_sample ? connection.smoothed_round_trip : INITIAL_ROUND_TRIP_TIME
	variation := connection.has_round_trip_sample ? connection.round_trip_variation : INITIAL_ROUND_TRIP_TIME / 2
	duration := smoothed + max(4 * variation, GRANULARITY)
	if level == .Application {
		duration += connection.peer_max_ack_delay
	}
	return duration << min(connection.probe_timeout_count, 16)
}

// amplification_budget gives the bytes that a server may still send to an
// address that it did not validate: 3 times the bytes that came (RFC 9000,
// section 8.1).
amplification_budget :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.address_validated {
		return max(u64)
	}
	limit := 3 * connection.bytes_received
	return limit > connection.bytes_sent ? limit - connection.bytes_sent : 0
}

// loss_detection_deadline gives the time of the loss detection timer, its
// space, and whether it is a probe timeout (RFC 9002, appendix A.8).
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
		return connection.last_sent_time + probe_timeout_duration(connection, level), level, true
	}
	for &space, space_level in connection.spaces {
		if space.ack_eliciting_in_flight == 0 {
			continue
		}
		if space_level == .Application && !connection.handshake_confirmed {
			continue
		}
		when_probe := space.last_ack_eliciting_sent_time + probe_timeout_duration(connection, space_level)
		if when_probe < deadline {
			deadline, level = when_probe, space_level
		}
	}
	return deadline, level, deadline != NO_DEADLINE
}

// loss_detection_timeout acts on the loss detection timer when it passed:
// the time threshold, or a probe timeout. A probe sends again the data of
// the two oldest packets of the space that wait, or a PING (RFC 9002,
// section 6.2.4).
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
