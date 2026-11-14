#+build !freestanding
// The cost of the work of new connections on the host, for the budgets of
// SERVER_LIMITS_DEFAULT: one Retry (8 random bytes, the token, the packet
// with its tag), one token check, one check of an authentic Initial. It
// prints the least time of one call over its batches, and checks no speed.
// For a measure, run it alone, optimized, on a quiet host:
//   odin test src/library/support/quic -o:speed -define:ODIN_TEST_NAMES=quic.the_cost_of_the_work_of_new_connections
package quic

import "modus:contract/errors"
import "core:fmt"
import "core:testing"
import "core:time"

SPEED_BATCHES :: 7
SPEED_CALLS :: 500

@(test)
the_cost_of_the_work_of_new_connections :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	server := &harness.server
	// No budget stops the measure.
	server.limits.retries_per_second, server.limits.retries_depth = 1 << 30, 1 << 30
	error: errors.Error_Record
	identifier: [CONNECTION_ID_SIZE]u8 = {0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61}
	remote := Remote{0x0B00_0010, 40_010}
	no_token := authentic_initial(&harness.cryptography, identifier)
	header: Packet_Header
	if !testing.expectf(t, header_read(no_token[:], 0, CONNECTION_ID_SIZE, &header, &error), "%v", error) {
		return
	}
	answer: [MAX_DATAGRAM_SIZE]u8
	// One Retry: what server_retry does for an Initial with no token.
	retry_least := max(i64)
	for _ in 0 ..< SPEED_BATCHES {
		start := time.tick_now()
		for _ in 0 ..< SPEED_CALLS {
			if server_retry(server, &header, remote, answer[:], harness.now) == 0 {
				testing.expect(t, false, "a Retry was not written")
				return
			}
		}
		retry_least = min(retry_least, time.duration_nanoseconds(time.tick_since(start)))
	}
	// One token check: the token of the last Retry, from its remote.
	retry_header: Packet_Header
	retry_length := server_retry(server, &header, remote, answer[:], harness.now)
	if !testing.expectf(t, header_read(answer[:retry_length], 0, 0, &retry_header, &error), "%v", error) {
		return
	}
	token := answer[retry_header.token_offset:][:retry_header.token_length]
	facts: Retry_Token_Facts
	token_least := max(i64)
	for _ in 0 ..< SPEED_BATCHES {
		start := time.tick_now()
		for _ in 0 ..< SPEED_CALLS {
			if !retry_token_open(server.cryptography, &server.retry_key, token, remote, harness.now, &facts, &error) {
				testing.expectf(t, false, "the token did not open: %v", error)
				return
			}
		}
		token_least = min(token_least, time.duration_nanoseconds(time.tick_since(start)))
	}
	// One check of an authentic Initial of 1200 bytes: the Initial keys of
	// its identifier, the header protection, the open, on a copy.
	initial_least := max(i64)
	for _ in 0 ..< SPEED_BATCHES {
		start := time.tick_now()
		for _ in 0 ..< SPEED_CALLS {
			if !server_initial_is_authentic(server, no_token[:], &header) {
				testing.expect(t, false, "an authentic Initial did not open")
				return
			}
		}
		initial_least = min(initial_least, time.duration_nanoseconds(time.tick_since(start)))
	}
	microseconds :: proc(least: i64) -> f64 {
		return f64(least) / SPEED_CALLS / 1000
	}
	fmt.printfln("quic: the work of new connections on the host: one Retry %.2f us, one token check %.2f us, one Initial check %.2f us; the least of %d batches of %d calls", microseconds(retry_least), microseconds(token_least), microseconds(initial_least), SPEED_BATCHES, SPEED_CALLS)
}
