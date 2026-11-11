// The call from the host: what the kernel tool on the host and the remote
// service in the machine agree on (docs/MODULE_CONTRACT.md, section 4, "A
// call from the host").
//
// The host encodes an isolated call of an export of a service with the
// description of the export (isolated.encode), and sends it as one call
// request: a Request header, then the first bytes of the call region. The
// remote service copies these bytes at offset 0 of the call region of its
// connection to the service, makes the isolated call, and sends the call
// answer: one or more datagrams, each an Answer header and a part of the
// bytes of the result.
//
// The remote service trusts nothing in a datagram: request_check checks each
// count and each place against the size of the datagram and of the call
// region. It does not read the description: the service checks the argument
// record, as for each caller.
//
// The host trusts nothing in an answer: answer_check checks each part.
//
// All numbers are little-endian. A header has no text but fixed names of 32
// bytes, and no field whose size depends on a language or a machine.
//
// This package allocates no memory and calls no kernel operation.
package remote

import "base:intrinsics"
import "contract:datagram"
import "contract:errors"
import "contract:isolated"

// The UDP port of the host, at the address of the gateway (10.0.2.2): the
// grant of the endpoint of the remote service names it.
HOST_PORT :: 7100

DATAGRAM_LIMIT :: datagram.DATA_LIMIT // The bytes of one datagram.
REGION_SIZE :: isolated.REGION_PAGES * 4096 // The call region of a connection.
REQUEST_SIZE :: size_of(Request)
ANSWER_SIZE :: size_of(Answer)
ARGUMENT_LIMIT :: DATAGRAM_LIMIT - REQUEST_SIZE // The bytes of the call region in one call request.
PART_LIMIT :: DATAGRAM_LIMIT - ANSWER_SIZE // The bytes of the result in one datagram of an answer.
PART_CAPACITY :: (REGION_SIZE + PART_LIMIT - 1) / PART_LIMIT // The datagrams of the largest answer.

// The numbers that the peer of the test gives to the malformed requests
// that it sends: the top bit. The tool numbers its requests from 1.
PEER_NUMBERS :: u64(1) << 63

Request_Kind :: enum u32 {
	None = 0,
	Call = 1, // An isolated call of one export of one service.
}

// The header of a call request. The bytes of the call region follow it.
Request :: struct {
	kind:         Request_Kind,
	export:       u32, // The index of the export in the module of the service: the kind of the command record.
	number:       u64, // The request number. 0: no request.
	service:      [32]u8, // The name of the service, as the root service names it: zero bytes after the name.
	hash:         [32]u8, // The BLAKE3 hash of the module file of the service that the host read.
	arguments:    u32, // The bytes of the call region after this header. They go at offset 0.
	record_size:  u32, // The size of the argument record, at offset 0: values[1] of the command record.
	result_start: u32, // The place of the result in the call region. 0 and 0: none.
	result_count: u32, // The bytes of that place.
	result_unit:  u32, // The bytes that one unit of the integer result counts there: 1 for a Text, the size of a record for a Table, 0 for a Record (the whole place).
	error_start:  u32, // The place of the error record (56 bytes). 0: the export has none.
}
#assert(size_of(Request) == 104)

// The names of the fields of a Request, for the sentence of a refusal: the
// argument of the error record is the index, from 1.
@(rodata)
REQUEST_FIELD_NAMES := [?]string{"kind", "export", "number", "service", "hash", "arguments", "record_size", "result_start", "result_count", "result_unit", "error_start"}

Status :: enum u32 {
	// The call ran. call_status is the isolated.Status of the completion;
	// value is the integer result. When value is negative and the export
	// has an error record, error is the record that the service wrote.
	Ok       = 0,
	// The remote service refused the request, and no call ran: error says
	// why. Its argument is the field of the Request (REQUEST_FIELD_NAMES).
	Refused  = 1,
	// The remote service started. number is 0. The host learns the local
	// port of the endpoint of the remote service from it.
	Started  = 2,
}

// The header of each datagram of a call answer. A part of the result
// follows it: count bytes, at offset of the result.
Answer :: struct {
	status:      Status,
	call_status: u32, // isolated.Status.
	number:      u64, // The request number. 0: a request that was too short to have one.
	value:       i64, // The integer result of the export.
	total:       u32, // The bytes of the whole result.
	offset:      u32, // The place of this part in the result.
	count:       u32, // The bytes of this part.
	reserved:    u32,
	hash:        [32]u8, // The hash of the module of the service that runs, when the remote service knows it.
	error:       errors.Error_Record,
}
#assert(size_of(Answer) == 128)
#assert(ANSWER_SIZE + PART_LIMIT == DATAGRAM_LIMIT)

@(private)
read :: proc "contextless" (bytes: []u8, $T: typeid) -> (value: T) {
	intrinsics.mem_copy_non_overlapping(&value, raw_data(bytes), size_of(T))
	return value
}

@(private)
write :: proc "contextless" (bytes: []u8, value: $T) {
	value := value
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), &value, size_of(T))
}

@(private)
refuse :: proc "contextless" (kind: errors.Kind, unit: errors.Unit, field: int, value: i64, limit: i64 = 0) -> errors.Error_Record {
	return errors.error_make(kind, unit, i64(field), value, limit)
}

// The numbers of the fields, from 1: the argument of a refusal.
FIELD_KIND :: 1
FIELD_EXPORT :: 2
FIELD_NUMBER :: 3
FIELD_SERVICE :: 4
FIELD_HASH :: 5
FIELD_ARGUMENTS :: 6
FIELD_RECORD_SIZE :: 7
FIELD_RESULT_START :: 8
FIELD_RESULT_COUNT :: 9
FIELD_RESULT_UNIT :: 10
FIELD_ERROR_START :: 11

// request_check reads the header of a call request in the bytes of one
// datagram, and checks it against those bytes and a call region of
// region_size bytes. When ok is false, error says which field is wrong:
// the remote service sends it in an answer with the status Refused. The
// header is a copy: the datagram region can change after the check.
// arguments: the bytes of the call region, after the header.
request_check :: proc "contextless" (bytes: []u8, region_size: u64) -> (request: Request, arguments: []u8, error: errors.Error_Record, ok: bool) {
	if len(bytes) < REQUEST_SIZE {
		return {}, nil, refuse(.Too_Small, .Bytes, 0, i64(len(bytes)), REQUEST_SIZE), false
	}
	request = read(bytes, Request)
	rest := u64(len(bytes) - REQUEST_SIZE)
	switch {
	case request.kind != .Call:
		return request, nil, refuse(.Bad_Value, .None, FIELD_KIND, i64(request.kind), i64(Request_Kind.Call)), false
	case request.number == 0:
		return request, nil, refuse(.Bad_Value, .None, FIELD_NUMBER, 0), false
	case request.service[0] == 0:
		return request, nil, refuse(.Empty, .Bytes, FIELD_SERVICE, 0, i64(len(request.service) - 1)), false
	case request.service[len(request.service) - 1] != 0:
		return request, nil, refuse(.Too_Long, .Bytes, FIELD_SERVICE, i64(len(request.service)), i64(len(request.service) - 1)), false
	case u64(request.arguments) > rest:
		return request, nil, refuse(.Too_Long, .Bytes, FIELD_ARGUMENTS, i64(request.arguments), i64(rest)), false
	case u64(request.arguments) < rest:
		return request, nil, refuse(.Too_Small, .Bytes, FIELD_ARGUMENTS, i64(request.arguments), i64(rest)), false
	case u64(request.arguments) > region_size:
		return request, nil, refuse(.Too_Long, .Bytes, FIELD_ARGUMENTS, i64(request.arguments), i64(region_size)), false
	case request.record_size > request.arguments:
		return request, nil, refuse(.Too_Long, .Bytes, FIELD_RECORD_SIZE, i64(request.record_size), i64(request.arguments)), false
	case u64(request.result_start) > region_size:
		return request, nil, refuse(.Bad_Value, .Bytes, FIELD_RESULT_START, i64(request.result_start), i64(region_size)), false
	case u64(request.result_count) > region_size - u64(request.result_start):
		return request, nil, refuse(.Too_Long, .Bytes, FIELD_RESULT_COUNT, i64(request.result_count), i64(region_size - u64(request.result_start))), false
	case request.result_unit > request.result_count:
		return request, nil, refuse(.Too_Long, .Bytes, FIELD_RESULT_UNIT, i64(request.result_unit), i64(request.result_count)), false
	case request.error_start != 0 && (request.error_start % 8 != 0 || u64(request.error_start) > region_size - isolated.ERROR_RECORD_SIZE):
		return request, nil, refuse(.Bad_Value, .Bytes, FIELD_ERROR_START, i64(request.error_start), i64(region_size - isolated.ERROR_RECORD_SIZE)), false
	}
	return request, bytes[REQUEST_SIZE:][:request.arguments], {}, true
}

// result_bytes gives the bytes of the result that a call answer carries,
// from the integer result of the export: the remote service does not trust
// it as a count. A failure (a negative result) carries no bytes.
result_bytes :: proc "contextless" (request: Request, value: i64) -> u64 {
	switch {
	case request.result_count == 0:
		return 0
	case request.result_unit == 0:
		return u64(request.result_count)
	case value <= 0:
		return 0
	}
	return min(u64(value), u64(request.result_count / request.result_unit)) * u64(request.result_unit)
}

// part_count gives the datagrams of a call answer with a result of total
// bytes: one at least.
part_count :: proc "contextless" (total: u64) -> u64 {
	return max((total + PART_LIMIT - 1) / PART_LIMIT, 1)
}

// answer_write writes datagram `part` of a call answer in out, and gives
// its bytes. header has the fields of the whole answer; this procedure sets
// total, offset and count. ok is false when out is too small or part is
// past the end.
answer_write :: proc "contextless" (out: []u8, header: Answer, result: []u8, part: u64) -> (bytes: []u8, ok: bool) {
	total := u64(len(result))
	if part >= part_count(total) || total > REGION_SIZE {
		return nil, false
	}
	offset := part * PART_LIMIT
	count := min(total - min(offset, total), PART_LIMIT)
	if u64(len(out)) < ANSWER_SIZE + count {
		return nil, false
	}
	header := header
	header.total, header.offset, header.count = u32(total), u32(offset), u32(count)
	write(out, header)
	intrinsics.mem_copy_non_overlapping(raw_data(out[ANSWER_SIZE:]), raw_data(result[offset:]), int(count))
	return out[:ANSWER_SIZE + count], true
}

// answer_check reads one datagram of a call answer. part is the bytes of
// the result that it carries, at header.offset. ok is false when a count or
// a place is not inside the datagram or inside a call region.
answer_check :: proc "contextless" (bytes: []u8) -> (header: Answer, part: []u8, ok: bool) {
	if len(bytes) < ANSWER_SIZE {
		return {}, nil, false
	}
	header = read(bytes, Answer)
	rest := u64(len(bytes) - ANSWER_SIZE)
	if u64(header.count) != rest || u64(header.total) > REGION_SIZE || u64(header.offset) > u64(header.total) || u64(header.count) > u64(header.total) - u64(header.offset) {
		return header, nil, false
	}
	if header.offset % PART_LIMIT != 0 || (header.count != PART_LIMIT && u64(header.offset) + u64(header.count) != u64(header.total)) {
		return header, nil, false
	}
	return header, bytes[ANSWER_SIZE:], true
}

// request_write writes a call request in out: the header, then the bytes
// of the call region. ok is false when they do not fit in one datagram.
request_write :: proc "contextless" (out: []u8, header: Request, arguments: []u8) -> (bytes: []u8, ok: bool) {
	if len(arguments) > ARGUMENT_LIMIT || len(out) < REQUEST_SIZE + len(arguments) {
		return nil, false
	}
	header := header
	header.arguments = u32(len(arguments))
	write(out, header)
	intrinsics.mem_copy_non_overlapping(raw_data(out[REQUEST_SIZE:]), raw_data(arguments), len(arguments))
	return out[:REQUEST_SIZE + len(arguments)], true
}

// name_set writes a name of 32 bytes: zero bytes after it. ok is false when
// the name is empty or has 32 bytes or more.
name_set :: proc "contextless" (name: ^[32]u8, text: string) -> bool {
	if len(text) == 0 || len(text) >= len(name) {
		return false
	}
	name^ = {}
	intrinsics.mem_copy_non_overlapping(&name[0], raw_data(text), len(text))
	return true
}

// name_text gives the text of a name of 32 bytes: the bytes before the
// first zero byte.
name_text :: proc "contextless" (name: ^[32]u8) -> string {
	count := 0
	for count < len(name) && name[count] != 0 {
		count += 1
	}
	return string(name[:count])
}
