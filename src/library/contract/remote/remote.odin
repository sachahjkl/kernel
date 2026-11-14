// The call from the host: what the kernel tool on the host and the remote
// service in the machine agree on (docs/MODULE_CONTRACT.md, section 4, "A
// call from the host"; docs/QUIC.md, section 7).
//
// The host encodes an isolated call of an export of a service with the
// description of the export (isolated.encode). It carries each call on one
// bidirectional QUIC stream of one connection to the remote service: the
// call request (a Request header, then the first bytes of the call region),
// then the end of the stream. The remote service copies these bytes at
// offset 0 of the call region of its connection to the service, makes the
// isolated call, and writes the call answer on the same stream: one Answer
// header, then the bytes of the result, then the end of the stream. The
// stream names the call: a header has no request number.
//
// A call that fails before its answer ends its stream with RESET_STREAM and
// an application error code of Stream_Error, never a close of the
// connection: the other calls go on.
//
// The remote service trusts nothing in a request: request_check checks each
// count and each place against the bytes of the stream and the size of the
// call region. It does not read the description: the service checks the
// argument record, as for each caller.
//
// The host trusts nothing in an answer: answer_check checks the header
// against the bytes of the stream.
//
// All numbers are little-endian. A header has no text but fixed names of 32
// bytes, and no field whose size depends on a language or a machine.
//
// This package allocates no memory and calls no kernel operation.
package remote

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"

// The UDP port of the listen grant of the remote service, on the address of
// the machine.
LISTEN_PORT :: 7100

// The one remote address that the listen grant of the remote service
// admits: the host, at the gateway of the network of the machine
// (10.0.2.2). The network service drops a datagram of another address
// before the program sees it.
HOST_ADDRESS :: 0x0A000202

// The application protocol (ALPN) of a connection to the remote service: a
// client that offers another one fails the handshake.
APPLICATION_PROTOCOL :: "modus-remote-call"

REGION_SIZE :: isolated.REGION_PAGES * 4096 // The call region of a connection.
REQUEST_SIZE :: size_of(Request) // The header of a request: 104 bytes.
ANSWER_SIZE :: size_of(Answer) // The header of an answer: 112 bytes.
// The bytes of a request on a stream at most: its header and a whole call
// region. One byte more and the remote service resets the stream with
// Too_Large, before any call.
REQUEST_LIMIT :: REQUEST_SIZE + REGION_SIZE
// The bytes of an answer on a stream at most: its header and a whole call
// region.
ANSWER_LIMIT :: ANSWER_SIZE + REGION_SIZE

// The QUIC connections that the remote service holds at one time: the tool,
// and one more while a tool starts again. A third client gets no record
// until one ends.
CONNECTION_CAPACITY :: 2
// The calls of one connection at one time: its stream records. The server
// gives the client this many streams (MAX_STREAMS), and one more each time
// that a stream ends: a client that opens one more waits for MAX_STREAMS
// (it sends STREAMS_BLOCKED), it is not refused.
CALLS_AT_ONCE :: 8

// The application error code of a RESET_STREAM or a STOP_SENDING of a call
// stream, and of a CONNECTION_CLOSE of the application.
Stream_Error :: enum u64 {
	None      = 0, // No error: a CONNECTION_CLOSE of a normal end.
	// The request has more than REQUEST_LIMIT bytes: the remote service
	// sends STOP_SENDING and RESET_STREAM before any call.
	Too_Large = 1,
	// A bound of time of the remote service passed: a request that was not
	// complete, or an answer that the host did not take, in its bound. The
	// remote service logs which one.
	Timeout   = 2,
	// The host gave up the call: a reset of the host. A call that ran keeps
	// its effects.
	Cancelled = 3,
}

// The name of each code, for the log of the two sides.
@(rodata)
STREAM_ERROR_NAMES := [Stream_Error]string {
	.None      = "None",
	.Too_Large = "Too_Large",
	.Timeout   = "Timeout",
	.Cancelled = "Cancelled",
}

// stream_error_name gives the name of an application error code, or "" for
// a code that this contract does not name.
stream_error_name :: proc "contextless" (code: u64) -> string {
	if code >= u64(len(STREAM_ERROR_NAMES)) {
		return ""
	}
	return STREAM_ERROR_NAMES[Stream_Error(code)]
}

// What a request asks.
Request_Kind :: enum u32 {
	None = 0, // Not a request: refused.
	Call = 1, // An isolated call of one export of one service.
}

// The header of a call request. The bytes of the call region follow it.
//
// The host writes it; the remote service reads it as hostile input and
// refuses a field that it cannot use (`Status.Refused`, with the field in the
// error record).
Request :: struct {
	kind:         Request_Kind, // Call.
	export:       u32, // The index of the export in the module of the service: the kind of the command record.
	service:      [32]u8, // The name of the service, as the root service names it: zero bytes after the name.
	hash:         [32]u8, // The BLAKE3 hash of the module file of the service that the host read.
	arguments:    u32, // The bytes of the call region after this header. They go at offset 0.
	record_size:  u32, // The size of the argument record, at offset 0: values[1] of the command record.
	result_start: u32, // The place of the result in the call region. 0 and 0: none.
	result_count: u32, // The bytes of that place.
	result_unit:  u32, // The bytes that one unit of the integer result counts there: 1 for a Text, the size of a record for a Table, 0 for a Record (the whole place).
	error_start:  u32, // The place of the error record (56 bytes). 0: the export has none.
	// The table of error details: the offset of the end of its field
	// (isolated.Table_Field, 32 bytes) in the argument record. 0: the export
	// has none. The end and not the start, because a field at offset 0 is
	// valid.
	details_end:  u32,
	_:            u32,
}
#assert(size_of(Request) == 104)

// The names of the fields of a Request, for the sentence of a refusal: the
// argument of the error record is the index, from 1.
@(rodata)
REQUEST_FIELD_NAMES := [?]string{"kind", "export", "service", "hash", "arguments", "record_size", "result_start", "result_count", "result_unit", "error_start", "details_end"}

// The status of an answer.
Status :: enum u32 {
	// The call ran. call_status is the isolated.Status of the completion;
	// value is the integer result. When value is negative and the export
	// has an error record, error is the record that the service wrote, and
	// the bytes of the answer are its error details (details_bytes).
	Ok      = 0,
	// The remote service refused the request, and no call ran: error says
	// why. Its argument is the field of the Request (REQUEST_FIELD_NAMES).
	Refused = 1,
}

// The header of a call answer. The bytes of the result follow it: total
// bytes, then the end of the stream.
Answer :: struct {
	status:      Status, // Ok or Refused.
	call_status: u32, // isolated.Status.
	value:       i64, // The integer result of the export.
	total:       u32, // The bytes of the result after this header.
	details:     u32, // A call that failed: the count of its error details, of the full answer, at most the largest u32. The bytes of the answer are the details that fit.
	hash:        [32]u8, // The hash of the module of the service that runs, when the remote service knows it.
	error:       errors.Error_Record, // The record of a refusal, or of an export that failed.
}
#assert(size_of(Answer) == 112)

// read copies a value out of bytes, with no alignment.
@(private)
read :: proc "contextless" (bytes: []u8, $T: typeid) -> (value: T) {
	intrinsics.mem_copy_non_overlapping(&value, raw_data(bytes), size_of(T))
	return value
}

// write copies a value into bytes, with no alignment.
@(private)
write :: proc "contextless" (bytes: []u8, value: $T) {
	value := value
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), &value, size_of(T))
}

// refuse gives the error record of a refusal of a field of a request.
@(private)
refuse :: proc "contextless" (kind: errors.Kind, unit: errors.Unit, field: int, value: i64, limit: i64 = 0) -> errors.Error_Record {
	return errors.error_make(kind, unit, i64(field), value, limit)
}

// The numbers of the fields, from 1: the argument of a refusal.
FIELD_KIND :: 1
FIELD_EXPORT :: 2
FIELD_SERVICE :: 3
FIELD_HASH :: 4
FIELD_ARGUMENTS :: 5
FIELD_RECORD_SIZE :: 6
FIELD_RESULT_START :: 7
FIELD_RESULT_COUNT :: 8
FIELD_RESULT_UNIT :: 9
FIELD_ERROR_START :: 10
FIELD_DETAILS_END :: 11

// What the bytes of one direction of a call stream are, so far.
Stream_Progress :: enum u8 {
	Waiting, // Not all bytes came: the end of the stream did not come.
	Complete, // The end of the stream came, within the limit.
	Too_Large, // More bytes than the limit came, with or without the end.
}

// stream_progress says what the bytes of one direction of a call stream
// are: received bytes so far, finished when the end of the stream came,
// against limit (REQUEST_LIMIT for a request, ANSWER_LIMIT for an answer).
// A stream over its limit is Too_Large at once: its reader does not wait
// for the end to refuse it.
stream_progress :: proc "contextless" (received: u64, finished: bool, limit: u64) -> Stream_Progress {
	switch {
	case received > limit:
		return .Too_Large
	case finished:
		return .Complete
	}
	return .Waiting
}

// request_check reads the header of a call request in the bytes of a whole
// request stream, and checks it against those bytes and a call region of
// region_size bytes. When ok is false, error says which field is wrong:
// the remote service sends it in an answer with the status Refused. The
// header is a copy: the stream buffer can change after the check.
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
	case request.details_end != 0 && (request.details_end % 8 != 0 || request.details_end < size_of(isolated.Table_Field) || request.details_end > request.record_size):
		// The field of the table is inside the argument record.
		return request, nil, refuse(.Bad_Value, .Bytes, FIELD_DETAILS_END, i64(request.details_end), i64(request.record_size)), false
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

// details_bytes gives the error details of a call that failed, from the call
// region after the call: the records that the service appended from the
// start of the field of the table of error details (the caller gave a count
// of 0, so the first record is at the start), and count, the count of the
// full answer that the field holds. The service wrote the field: no number
// of it is trusted, and the bytes are cut to the call region. A table in a
// memory object has no bytes here.
details_bytes :: proc "contextless" (request: Request, region: []u8) -> (bytes: []u8, count: u64) {
	if request.details_end == 0 || u64(request.details_end) < size_of(isolated.Table_Field) || u64(request.details_end) > u64(len(region)) {
		return nil, 0
	}
	field := read(region[u64(request.details_end) - size_of(isolated.Table_Field):], isolated.Table_Field)
	if field.memory_handle != 0 || field.start > u64(len(region)) {
		return nil, field.count
	}
	records := min(field.count, field.capacity, (u64(len(region)) - field.start) / isolated.ERROR_RECORD_SIZE)
	return region[field.start:][:records * isolated.ERROR_RECORD_SIZE], field.count
}

// details_shown gives how many error details of an answer the host reads,
// from the bytes of the answer of a failed call: whole records only, and at
// most the count that the answer names. sound is false when the bytes are
// not whole records, or are more records than the count: the answer lies,
// and the host says so.
details_shown :: proc "contextless" (answer: Answer, byte_count: u64) -> (shown: u64, sound: bool) {
	records := byte_count / isolated.ERROR_RECORD_SIZE
	shown = min(records, u64(answer.details))
	return shown, byte_count % isolated.ERROR_RECORD_SIZE == 0 && records <= u64(answer.details)
}

// answer_write writes a whole call answer in out: the header, with total
// set to the bytes of result, then result. ok is false when out is too
// small or the result is larger than a call region.
answer_write :: proc "contextless" (out: []u8, header: Answer, result: []u8) -> (bytes: []u8, ok: bool) {
	total := u64(len(result))
	if total > REGION_SIZE || u64(len(out)) < ANSWER_SIZE + total {
		return nil, false
	}
	header := header
	header.total = u32(total)
	write(out, header)
	if total > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(out[ANSWER_SIZE:]), raw_data(result), int(total))
	}
	return out[:ANSWER_SIZE + total], true
}

// answer_check reads a whole call answer: the bytes of its stream up to the
// end. result is the bytes after the header. ok is false when the bytes
// are not exactly a header and the total that it names, or when the total
// is larger than a call region.
answer_check :: proc "contextless" (bytes: []u8) -> (header: Answer, result: []u8, ok: bool) {
	if len(bytes) < ANSWER_SIZE {
		return {}, nil, false
	}
	header = read(bytes, Answer)
	rest := u64(len(bytes) - ANSWER_SIZE)
	if u64(header.total) != rest || u64(header.total) > REGION_SIZE {
		return header, nil, false
	}
	return header, bytes[ANSWER_SIZE:], true
}

// request_write writes a whole call request in out: the header, then the
// bytes of the call region. ok is false when they do not fit in out, or
// when the arguments are larger than a call region.
request_write :: proc "contextless" (out: []u8, header: Request, arguments: []u8) -> (bytes: []u8, ok: bool) {
	if len(arguments) > REGION_SIZE || len(out) < REQUEST_SIZE + len(arguments) {
		return nil, false
	}
	header := header
	header.arguments = u32(len(arguments))
	write(out, header)
	if len(arguments) > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(out[REQUEST_SIZE:]), raw_data(arguments), len(arguments))
	}
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
