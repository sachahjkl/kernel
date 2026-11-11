#+build !freestanding
package remote

import "contract:errors"
import "core:math/rand"
import "core:testing"

@(private = "file")
request_make :: proc() -> (request: Request) {
	request.kind = .Call
	request.export = 3
	request.number = 41
	name_set(&request.service, "monitor")
	request.hash = {0 = 0xAB, 31 = 0xCD}
	request.record_size = 24
	request.result_start = 64
	request.result_count = REGION_SIZE - 64
	request.result_unit = 200
	request.error_start = 8
	return request
}

// What request_write writes, request_check reads: the same header and the
// same bytes of the call region.
@(test)
request_round_trip :: proc(t: ^testing.T) {
	out: [DATAGRAM_LIMIT]u8
	arguments: [40]u8
	for &byte, index in arguments {
		byte = u8(index * 7)
	}
	bytes, written := request_write(out[:], request_make(), arguments[:])
	testing.expect(t, written)
	testing.expect_value(t, len(bytes), REQUEST_SIZE + 40)
	request, read_arguments, error, ok := request_check(bytes, REGION_SIZE)
	testing.expect(t, ok)
	testing.expect_value(t, error.kind, 0)
	testing.expect_value(t, request.number, 41)
	testing.expect_value(t, request.arguments, 40)
	testing.expect_value(t, name_text(&request.service), "monitor")
	testing.expect_value(t, request.hash[31], 0xCD)
	testing.expect_value(t, string(read_arguments), string(arguments[:]))
	_, too_large := request_write(out[:], request_make(), make([]u8, ARGUMENT_LIMIT + 1, context.temp_allocator))
	testing.expect(t, !too_large, "the arguments do not fit in one datagram")
}

// Each field that request_check refuses gives the field and the kind of the
// error record.
@(test)
request_refusals :: proc(t: ^testing.T) {
	Case :: struct {
		change: proc(request: ^Request),
		field:  i64,
		kind:   errors.Kind,
	}
	cases := [?]Case {
		{proc(request: ^Request) {request.kind = .None}, FIELD_KIND, .Bad_Value},
		{proc(request: ^Request) {request.kind = Request_Kind(9)}, FIELD_KIND, .Bad_Value},
		{proc(request: ^Request) {request.number = 0}, FIELD_NUMBER, .Bad_Value},
		{proc(request: ^Request) {request.service = {}}, FIELD_SERVICE, .Empty},
		{proc(request: ^Request) {for &byte in request.service {byte = 'a'}}, FIELD_SERVICE, .Too_Long},
		{proc(request: ^Request) {request.record_size = 41}, FIELD_RECORD_SIZE, .Too_Long},
		{proc(request: ^Request) {request.result_start = REGION_SIZE + 8; request.result_count = 0; request.result_unit = 0}, FIELD_RESULT_START, .Bad_Value},
		{proc(request: ^Request) {request.result_count = REGION_SIZE}, FIELD_RESULT_COUNT, .Too_Long},
		{proc(request: ^Request) {request.result_count = 100; request.result_unit = 101}, FIELD_RESULT_UNIT, .Too_Long},
		{proc(request: ^Request) {request.error_start = 12}, FIELD_ERROR_START, .Bad_Value},
		{proc(request: ^Request) {request.error_start = REGION_SIZE - 48}, FIELD_ERROR_START, .Bad_Value},
	}
	out: [DATAGRAM_LIMIT]u8
	arguments: [40]u8
	for item, index in cases {
		request := request_make()
		item.change(&request)
		bytes, _ := request_write(out[:], request, arguments[:])
		_, _, error, ok := request_check(bytes, REGION_SIZE)
		testing.expectf(t, !ok, "case %d is refused", index)
		testing.expectf(t, error.argument == item.field && error.kind == i64(item.kind), "case %d: the field %d and the kind %v, not %d and %d", index, item.field, item.kind, error.argument, error.kind)
	}
	// The count of the bytes of the arguments against the datagram.
	bytes, _ := request_write(out[:], request_make(), arguments[:])
	_, _, error, ok := request_check(bytes[:len(bytes) - 1], REGION_SIZE)
	testing.expect(t, !ok && error.argument == FIELD_ARGUMENTS && error.kind == i64(errors.Kind.Too_Long) && error.value == 40 && error.limit == 39)
	_, _, error, ok = request_check(out[:len(bytes) + 1], REGION_SIZE)
	testing.expect(t, !ok && error.argument == FIELD_ARGUMENTS && error.kind == i64(errors.Kind.Too_Small))
	// A datagram shorter than the header.
	_, _, error, ok = request_check(out[:REQUEST_SIZE - 1], REGION_SIZE)
	testing.expect(t, !ok && error.argument == 0 && error.kind == i64(errors.Kind.Too_Small) && error.value == REQUEST_SIZE - 1 && error.limit == REQUEST_SIZE)
	// The arguments must fit in a smaller call region too.
	_, _, error, ok = request_check(bytes, 32)
	testing.expect(t, !ok && error.argument == FIELD_ARGUMENTS && error.limit == 32)
}

// The bytes of a result come from the integer result, which the remote
// service does not trust.
@(test)
result_bytes_counts :: proc(t: ^testing.T) {
	request := request_make() // A Table of records of 200 bytes, in 65472 bytes.
	testing.expect_value(t, result_bytes(request, 3), 600)
	testing.expect_value(t, result_bytes(request, -2), 0)
	testing.expect_value(t, result_bytes(request, max(i64)), u64((REGION_SIZE - 64) / 200 * 200))
	request.result_unit = 1 // A Text.
	testing.expect_value(t, result_bytes(request, 10), 10)
	testing.expect_value(t, result_bytes(request, 1 << 40), u64(REGION_SIZE - 64))
	request.result_unit = 0 // A Record: the whole place.
	request.result_count = 48
	testing.expect_value(t, result_bytes(request, -1), 48)
	request.result_count = 0
	testing.expect_value(t, result_bytes(request, 5), 0)
}

// An answer in parts: answer_check reads each part at its place, and the
// parts give the result again.
@(test)
answer_parts :: proc(t: ^testing.T) {
	result := make([]u8, REGION_SIZE, context.temp_allocator)
	for &byte, index in result {
		byte = u8(index * 13 + index / 256)
	}
	for total in ([]int{0, 1, PART_LIMIT, PART_LIMIT + 1, 5000, REGION_SIZE}) {
		again := make([]u8, total, context.temp_allocator)
		parts := part_count(u64(total))
		testing.expect(t, parts >= 1 && parts <= PART_CAPACITY)
		received: u64
		for part in 0 ..< parts {
			out: [DATAGRAM_LIMIT]u8
			bytes, written := answer_write(out[:], {status = .Ok, number = 7, value = i64(total)}, result[:total], part)
			testing.expect(t, written)
			header, data, ok := answer_check(bytes)
			testing.expect(t, ok)
			testing.expect_value(t, header.number, 7)
			testing.expect_value(t, int(header.total), total)
			copy(again[header.offset:], data)
			received += u64(len(data))
		}
		testing.expect_value(t, received, u64(total))
		testing.expect(t, string(again) == string(result[:total]))
		out: [DATAGRAM_LIMIT]u8
		_, past := answer_write(out[:], {}, result[:total], parts)
		testing.expect(t, !past, "no part after the last one")
	}
}

// answer_check refuses each part that names bytes out of the datagram or of
// a call region.
@(test)
answer_refusals :: proc(t: ^testing.T) {
	out: [DATAGRAM_LIMIT]u8
	data: [3000]u8
	bytes, _ := answer_write(out[:], {}, data[:], 1)
	_, _, ok := answer_check(bytes)
	testing.expect(t, ok)
	_, _, ok = answer_check(bytes[:len(bytes) - 1])
	testing.expect(t, !ok, "a part shorter than its count")
	_, _, ok = answer_check(bytes[:ANSWER_SIZE - 1])
	testing.expect(t, !ok, "shorter than the header")
	header := (^Answer)(&out[0])
	header.total = REGION_SIZE + 1
	_, _, ok = answer_check(bytes)
	testing.expect(t, !ok, "a total larger than a call region")
	header.total = 3000
	header.offset = 2000
	_, _, ok = answer_check(bytes)
	testing.expect(t, !ok, "a part out of the total")
	header.offset = 7
	_, _, ok = answer_check(bytes)
	testing.expect(t, !ok, "a part at another place than its number")
}

// Random datagrams: request_check never reads out of the datagram, and each
// request that it accepts names places inside the call region.
@(test)
request_random :: proc(t: ^testing.T) {
	out: [DATAGRAM_LIMIT]u8
	accepted := 0
	for _ in 0 ..< 200_000 {
		count := rand.int_max(DATAGRAM_LIMIT + 1)
		for &byte in out[:count] {
			byte = u8(rand.uint32())
		}
		if count >= REQUEST_SIZE && rand.int_max(2) == 0 {
			// Near a valid header, so that the checks after the first ones run.
			request := request_make()
			request.result_start = u32(rand.int_max(REGION_SIZE + 100))
			request.result_count = u32(rand.int_max(REGION_SIZE + 100))
			request.result_unit = u32(rand.int_max(300))
			request.error_start = u32(rand.int_max(REGION_SIZE + 100))
			request.record_size = u32(rand.int_max(count - REQUEST_SIZE + 10))
			request.arguments = u32(count - REQUEST_SIZE)
			(^Request)(&out[0])^ = request
		}
		request, arguments, _, ok := request_check(out[:count], REGION_SIZE)
		if !ok {
			continue
		}
		accepted += 1
		testing.expect(t, len(arguments) == int(request.arguments) && REQUEST_SIZE + len(arguments) == count)
		testing.expect(t, u64(request.result_start) + u64(request.result_count) <= REGION_SIZE)
		testing.expect(t, request.error_start == 0 || (request.error_start % 8 == 0 && u64(request.error_start) + 56 <= REGION_SIZE))
		testing.expect(t, result_bytes(request, i64(rand.uint64())) <= u64(request.result_count))
	}
	testing.expect(t, accepted > 1000, "the random requests reach the end of the checks")
}
