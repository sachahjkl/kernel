#+build !freestanding
package remote

import "contract:errors"
import "contract:isolated"
import "core:math/rand"
import "core:testing"

@(private = "file")
request_make :: proc() -> (request: Request) {
	request.kind = .Call
	request.export = 3
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
	out: [REQUEST_SIZE + 64]u8
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
	testing.expect_value(t, request.arguments, 40)
	testing.expect_value(t, name_text(&request.service), "monitor")
	testing.expect_value(t, request.hash[31], 0xCD)
	testing.expect_value(t, string(read_arguments), string(arguments[:]))
	_, too_large := request_write(make([]u8, REQUEST_LIMIT + 1, context.temp_allocator), request_make(), make([]u8, REGION_SIZE + 1, context.temp_allocator))
	testing.expect(t, !too_large, "arguments larger than a call region")
	_, too_small := request_write(out[:REQUEST_SIZE + 39], request_make(), arguments[:])
	testing.expect(t, !too_small, "an out that does not hold the request")
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
		{proc(request: ^Request) {request.service = {}}, FIELD_SERVICE, .Empty},
		{proc(request: ^Request) {for &byte in request.service {byte = 'a'}}, FIELD_SERVICE, .Too_Long},
		{proc(request: ^Request) {request.record_size = 41}, FIELD_RECORD_SIZE, .Too_Long},
		{proc(request: ^Request) {request.result_start = REGION_SIZE + 8; request.result_count = 0; request.result_unit = 0}, FIELD_RESULT_START, .Bad_Value},
		{proc(request: ^Request) {request.result_count = REGION_SIZE}, FIELD_RESULT_COUNT, .Too_Long},
		{proc(request: ^Request) {request.result_count = 100; request.result_unit = 101}, FIELD_RESULT_UNIT, .Too_Long},
		{proc(request: ^Request) {request.error_start = 12}, FIELD_ERROR_START, .Bad_Value},
		{proc(request: ^Request) {request.error_start = REGION_SIZE - 48}, FIELD_ERROR_START, .Bad_Value},
		{proc(request: ^Request) {request.details_end = 20}, FIELD_DETAILS_END, .Bad_Value},
		{proc(request: ^Request) {request.details_end = 16}, FIELD_DETAILS_END, .Bad_Value},
		{proc(request: ^Request) {request.details_end = 32}, FIELD_DETAILS_END, .Bad_Value}, // Past the argument record of 24 bytes.
	}
	out: [REQUEST_SIZE + 64]u8
	arguments: [40]u8
	for item, index in cases {
		request := request_make()
		item.change(&request)
		bytes, _ := request_write(out[:], request, arguments[:])
		_, _, error, ok := request_check(bytes, REGION_SIZE)
		testing.expectf(t, !ok, "case %d is refused", index)
		testing.expectf(t, error.argument == item.field && error.kind == i64(item.kind), "case %d: the field %d and the kind %v, not %d and %d", index, item.field, item.kind, error.argument, error.kind)
	}
	// The count of the bytes of the arguments against the stream.
	bytes, _ := request_write(out[:], request_make(), arguments[:])
	_, _, error, ok := request_check(bytes[:len(bytes) - 1], REGION_SIZE)
	testing.expect(t, !ok && error.argument == FIELD_ARGUMENTS && error.kind == i64(errors.Kind.Too_Long) && error.value == 40 && error.limit == 39)
	_, _, error, ok = request_check(out[:len(bytes) + 1], REGION_SIZE)
	testing.expect(t, !ok && error.argument == FIELD_ARGUMENTS && error.kind == i64(errors.Kind.Too_Small))
	// A stream shorter than the header.
	_, _, error, ok = request_check(out[:REQUEST_SIZE - 1], REGION_SIZE)
	testing.expect(t, !ok && error.argument == 0 && error.kind == i64(errors.Kind.Too_Small) && error.value == REQUEST_SIZE - 1 && error.limit == REQUEST_SIZE)
	// The arguments must fit in a smaller call region too.
	_, _, error, ok = request_check(bytes, 32)
	testing.expect(t, !ok && error.argument == FIELD_ARGUMENTS && error.limit == 32)
}

// The table of error details: its field is inside the argument record; the
// remote service reads the details from the call region after the call,
// and trusts no number of the field; the host reads whole records only, and
// at most the count that the answer names.
@(test)
error_details_of_an_answer :: proc(t: ^testing.T) {
	out: [REQUEST_SIZE + 64]u8
	arguments: [40]u8
	request := request_make()
	request.record_size = 40
	request.details_end = 40 // The field is the bytes 8 ..< 40 of the argument record.
	bytes, _ := request_write(out[:], request, arguments[:])
	_, _, _, ok := request_check(bytes, REGION_SIZE)
	testing.expect(t, ok, "a field of the table of error details inside the argument record")

	region := make([]u8, REGION_SIZE, context.temp_allocator)
	write(region[8:], isolated.Table_Field{start = 64, count = 3, capacity = 16})
	for number in 0 ..< 3 {
		write(region[64 + number * isolated.ERROR_RECORD_SIZE:], errors.error_make(.Absent, .None, 1, 0, 0, i64(number + 1)))
	}
	details, count := details_bytes(request, region)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, len(details), 3 * isolated.ERROR_RECORD_SIZE)
	testing.expect_value(t, read(details[2 * isolated.ERROR_RECORD_SIZE:], errors.Error_Record).found, 3)

	// A count over the capacity: the capacity of records, and the count of
	// the full answer.
	write(region[8:], isolated.Table_Field{start = 64, count = 40, capacity = 16})
	details, count = details_bytes(request, region)
	testing.expect_value(t, count, 40)
	testing.expect_value(t, len(details), 16 * isolated.ERROR_RECORD_SIZE)

	// A field that the service changed to name bytes past the call region:
	// cut to the region.
	write(region[8:], isolated.Table_Field{start = REGION_SIZE - 100, count = 1 << 40, capacity = 1 << 40})
	details, count = details_bytes(request, region)
	testing.expect_value(t, len(details), isolated.ERROR_RECORD_SIZE)
	write(region[8:], isolated.Table_Field{start = REGION_SIZE + 8, count = 2, capacity = 2})
	details, count = details_bytes(request, region)
	testing.expect_value(t, len(details), 0)
	testing.expect_value(t, count, 2)
	request.details_end = 0
	details, count = details_bytes(request, region)
	testing.expect(t, details == nil && count == 0, "no table of error details")

	// The host: a count that lies.
	answer := Answer{details = 3}
	shown, sound := details_shown(answer, 3 * isolated.ERROR_RECORD_SIZE)
	testing.expect(t, shown == 3 && sound, "three records and a count of 3")
	answer.details = 1000
	shown, sound = details_shown(answer, 2 * isolated.ERROR_RECORD_SIZE)
	testing.expect(t, shown == 2 && sound, "a count larger than the records: the Append rule, the rest did not fit")
	answer.details = 1
	shown, sound = details_shown(answer, 5 * isolated.ERROR_RECORD_SIZE)
	testing.expect(t, shown == 1 && !sound, "more records than the count: the host reads the count, and says that the answer lies")
	answer.details = 4
	shown, sound = details_shown(answer, 2 * isolated.ERROR_RECORD_SIZE + 10)
	testing.expect(t, shown == 2 && !sound, "bytes that are not whole records")
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

// A whole answer: answer_check reads what answer_write wrote, for each size
// of a result from none to a whole call region.
@(test)
answer_round_trip :: proc(t: ^testing.T) {
	result := make([]u8, REGION_SIZE, context.temp_allocator)
	for &byte, index in result {
		byte = u8(index * 13 + index / 256)
	}
	out := make([]u8, ANSWER_LIMIT, context.temp_allocator)
	for total in ([]int{0, 1, 1200, 5000, REGION_SIZE}) {
		bytes, written := answer_write(out, {status = .Ok, value = i64(total)}, result[:total])
		testing.expect(t, written)
		testing.expect_value(t, len(bytes), ANSWER_SIZE + total)
		header, data, ok := answer_check(bytes)
		testing.expect(t, ok)
		testing.expect_value(t, int(header.total), total)
		testing.expect_value(t, header.value, i64(total))
		testing.expect(t, string(data) == string(result[:total]))
	}
	_, too_large := answer_write(make([]u8, ANSWER_LIMIT + 1, context.temp_allocator), {}, make([]u8, REGION_SIZE + 1, context.temp_allocator))
	testing.expect(t, !too_large, "a result larger than a call region")
	_, too_small := answer_write(out[:ANSWER_SIZE + 9], {}, result[:10])
	testing.expect(t, !too_small, "an out that does not hold the answer")
}

// answer_check refuses an answer whose bytes are not exactly its header and
// the total that it names, and a total larger than a call region.
@(test)
answer_refusals :: proc(t: ^testing.T) {
	out: [ANSWER_SIZE + 3000]u8
	data: [3000]u8
	bytes, _ := answer_write(out[:], {}, data[:])
	_, _, ok := answer_check(bytes)
	testing.expect(t, ok)
	_, _, ok = answer_check(bytes[:len(bytes) - 1])
	testing.expect(t, !ok, "an answer shorter than its total")
	_, _, ok = answer_check(bytes[:ANSWER_SIZE - 1])
	testing.expect(t, !ok, "shorter than the header")
	header := (^Answer)(&out[0])
	header.total = 2999
	_, _, ok = answer_check(bytes)
	testing.expect(t, !ok, "more bytes than the total")
	header.total = REGION_SIZE + 1
	_, _, ok = answer_check(bytes)
	testing.expect(t, !ok, "a total larger than a call region")
}

// The framing of a call on a stream: a request of REQUEST_LIMIT bytes is
// whole; one byte more is Too_Large at once, before the end of the stream;
// a stream with no end yet waits.
@(test)
stream_progress_of_a_call :: proc(t: ^testing.T) {
	testing.expect_value(t, stream_progress(0, false, REQUEST_LIMIT), Stream_Progress.Waiting)
	testing.expect_value(t, stream_progress(REQUEST_LIMIT, false, REQUEST_LIMIT), Stream_Progress.Waiting)
	testing.expect_value(t, stream_progress(REQUEST_LIMIT, true, REQUEST_LIMIT), Stream_Progress.Complete)
	testing.expect_value(t, stream_progress(REQUEST_LIMIT + 1, false, REQUEST_LIMIT), Stream_Progress.Too_Large)
	testing.expect_value(t, stream_progress(REQUEST_LIMIT + 1, true, REQUEST_LIMIT), Stream_Progress.Too_Large)
	// An empty stream is a whole request: request_check refuses it with its
	// error record, as each request that is shorter than its header.
	testing.expect_value(t, stream_progress(0, true, REQUEST_LIMIT), Stream_Progress.Complete)
	_, _, error, ok := request_check(nil, REGION_SIZE)
	testing.expect(t, !ok && error.kind == i64(errors.Kind.Too_Small) && error.limit == REQUEST_SIZE)
	testing.expect_value(t, stream_progress(ANSWER_LIMIT + 1, false, ANSWER_LIMIT), Stream_Progress.Too_Large)
	// The limits are the header and one call region.
	testing.expect_value(t, REQUEST_LIMIT, 104 + 65536)
	testing.expect_value(t, ANSWER_LIMIT, 112 + 65536)
	// A whole request fits the limit, and request_check takes it.
	out := make([]u8, REQUEST_LIMIT, context.temp_allocator)
	request := request_make()
	request.record_size = 24
	bytes, written := request_write(out, request, make([]u8, REGION_SIZE, context.temp_allocator))
	testing.expect(t, written && len(bytes) == REQUEST_LIMIT)
	_, _, _, ok = request_check(bytes, REGION_SIZE)
	testing.expect(t, ok, "a request of a whole call region")
}

// Each application error code has its name, and a code that the contract
// does not name has none: the tool prints a reset by its name.
@(test)
stream_error_codes :: proc(t: ^testing.T) {
	testing.expect_value(t, stream_error_name(u64(Stream_Error.Too_Large)), "Too_Large")
	testing.expect_value(t, stream_error_name(u64(Stream_Error.Timeout)), "Timeout")
	testing.expect_value(t, stream_error_name(u64(Stream_Error.Cancelled)), "Cancelled")
	testing.expect_value(t, stream_error_name(0), "None")
	testing.expect_value(t, stream_error_name(4), "")
	testing.expect_value(t, stream_error_name(max(u64)), "")
	for code in Stream_Error {
		testing.expect(t, STREAM_ERROR_NAMES[code] != "")
	}
}

// Random requests: request_check never reads out of the bytes of the
// stream, and each request that it accepts names places inside the call
// region.
@(test)
request_random :: proc(t: ^testing.T) {
	out: [2048]u8
	accepted := 0
	for _ in 0 ..< 200_000 {
		count := rand.int_max(len(out) + 1)
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
