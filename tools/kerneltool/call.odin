package kerneltool

import "contract:blake3"
import "contract:errors"
import "contract:isolated"
import module "contract:module"
import "contract:remote"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "support:sentence"

// The call from the host (docs/MODULE_CONTRACT.md, section 4, "A call from
// the host"): `kerneltool call "monitor.programs()"` calls an export of a
// service in the machine, and prints its typed result.
//
// The tool reads the description of the export in the module file of the
// service (build/modules/<service>.module), checks each argument against
// it, and writes the argument record with isolated.encode, as a caller
// program does. It sends one call request to the peer on the loopback of
// the host; the peer gives it to the remote service in the machine, and
// gives the datagrams of the call answer back.
//
// `kerneltool run` starts the peer with its port of call requests at
// CALL_PORT; the machine test gives the peer a port of the system, and the
// step Call uses the same code.

CALL_PORT :: 7101 // On 127.0.0.1: the peer of `kerneltool run` receives the call requests there.
CALL_REPEAT_TIME :: 300 * time.Millisecond // With no complete answer, the request goes again.
CALL_TIME_LIMIT :: 10 * time.Second

// What a call gave, for the machine test.
Call_Outcome :: enum {
	Result, // The export ran and gave its result.
	Failed, // The export ran and gave an error record.
	Refused, // The remote service or the service refused the call.
	No_Answer, // No complete answer came.
	Wrong, // The text of the call, or its arguments, do not agree with the description.
}

Call_Result :: struct {
	outcome:  Call_Outcome,
	lines:    [dynamic]string, // What the tool prints, one line each.
	rows:     int, // A Table: its count of rows.
	value:    i64,
	datagrams: int, // The datagrams of the answer.
}

// A call that the tool can send again and again: the measures.
Prepared_Call :: struct {
	service:  string,
	export:   string,
	file:     []u8,
	function: module.Function,
	index:    u32,
	request:  remote.Request,
	bytes:    []u8, // The bytes of the call region, from offset 0.
}

Call_Client :: struct {
	socket: net.UDP_Socket,
	peer:   net.Endpoint,
	number: u64, // The last request number.
	sends:  int, // The times that the last call request went: 1, or more after a lost datagram.
	wrong_hash: bool, // The next call request names another hash of the module: the test of the refusal.
	last_hash:  [32]u8, // The hash that the last call request named.
	modules:    [dynamic]Read_Module, // The module files that the client read, with their hashes: a call reads and hashes a file one time.
	region: []u8,
	result: []u8,
}

call_client_open :: proc(client: ^Call_Client, port: int) -> bool {
	socket, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if err != nil {
		fmt.eprintfln("kerneltool: no UDP socket for the call: %v", err)
		return false
	}
	_ = net.set_option(socket, .Receive_Timeout, 50 * time.Millisecond)
	client.socket = socket
	client.peer = {address = net.IP4_Loopback, port = port}
	// A number that a call of an earlier run did not use: the remote service
	// keeps the answer of its last number.
	client.number = u64(time.now()._nsec) & (remote.PEER_NUMBERS - 1)
	client.region = make([]u8, remote.REGION_SIZE)
	client.result = make([]u8, remote.REGION_SIZE)
	return true
}

call_client_close :: proc(client: ^Call_Client) {
	net.close(client.socket)
	delete(client.region)
	delete(client.result)
	for item in client.modules {
		delete(item.file)
		delete(item.service)
	}
	delete(client.modules)
}

Read_Module :: struct {
	service: string,
	file:    []u8,
	hash:    [32]u8,
}

// module_read gives the module file of a service and its hash. The client
// reads each file one time.
module_read :: proc(client: ^Call_Client, service: string) -> (file: []u8, hash: [32]u8, problem: string) {
	for &item in client.modules {
		if item.service == service {
			return item.file, item.hash, ""
		}
	}
	path := module_path(service)
	bytes, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil, {}, fmt.tprintf("no module %s in %s: build it, or name a service of the build (%v)", service, path, err)
	}
	if module.validate(bytes) != .None {
		delete(bytes)
		return nil, {}, fmt.tprintf("%s is not a valid module", path)
	}
	item := Read_Module{service = strings.clone(service), file = bytes, hash = blake3.hash(bytes)}
	append(&client.modules, item)
	return item.file, item.hash, ""
}

// Parsed argument of the text of a call.
Call_Argument :: struct {
	is_text: bool,
	integer: i64,
	text:    string,
}

// call_parse reads "service.export(argument, ...)": an argument is an
// integer (decimal, or hexadecimal after 0x) or a text in double quotes,
// with \" \\ and \n.
call_parse :: proc(call_text: string) -> (service, export: string, arguments: [dynamic]Call_Argument, problem: string) {
	text := strings.trim_space(call_text)
	open := strings.index_byte(text, '(')
	dot := strings.index_byte(text, '.')
	if dot <= 0 || open < dot + 2 || !strings.has_suffix(text, ")") {
		return "", "", nil, "a call is service.export(arguments), for example monitor.programs()"
	}
	service, export = text[:dot], text[dot + 1:open]
	rest := strings.trim_space(text[open + 1:len(text) - 1])
	arguments = make([dynamic]Call_Argument, context.temp_allocator)
	for len(rest) > 0 {
		argument: Call_Argument
		if rest[0] == '"' {
			builder := strings.builder_make(context.temp_allocator)
			index := 1
			closed := false
			for index < len(rest) {
				character := rest[index]
				if character == '"' {
					closed = true
					index += 1
					break
				}
				if character == '\\' && index + 1 < len(rest) {
					index += 1
					switch rest[index] {
					case 'n':
						strings.write_byte(&builder, '\n')
					case:
						strings.write_byte(&builder, rest[index])
					}
				} else {
					strings.write_byte(&builder, character)
				}
				index += 1
			}
			if !closed {
				return service, export, arguments, "a text has no closing double quote"
			}
			argument = {is_text = true, text = strings.to_string(builder)}
			rest = rest[index:]
		} else {
			end := strings.index_byte(rest, ',')
			if end < 0 {
				end = len(rest)
			}
			word := strings.trim_space(rest[:end])
			value, ok := strconv.parse_i64(word)
			if !ok {
				return service, export, arguments, fmt.tprintf("%q is not an integer and not a text in double quotes", word)
			}
			argument = {integer = value}
			rest = rest[end:]
		}
		append(&arguments, argument)
		rest = strings.trim_space(rest)
		if len(rest) > 0 {
			if rest[0] != ',' {
				return service, export, arguments, "two arguments need a comma between them"
			}
			rest = strings.trim_space(rest[1:])
			if len(rest) == 0 {
				return service, export, arguments, "an argument is missing after the last comma"
			}
		}
	}
	return
}

type_name :: proc(file: []u8, type: module.Type, detail: u32) -> string {
	buffer := make([]u8, 128, context.temp_allocator)
	writer := sentence.Writer{buffer = buffer}
	sentence.write_type(&writer, file, type, detail)
	return sentence.written(&writer)
}

// call_prepare reads the description of the export, checks the arguments
// against it, and writes the call request in the region of the client.
call_prepare :: proc(client: ^Call_Client, text: string) -> (call: Prepared_Call, problem: string) {
	service, export, arguments, parse_problem := call_parse(text)
	if parse_problem != "" {
		return {}, parse_problem
	}
	file, hash, read_problem := module_read(client, service)
	if read_problem != "" {
		return {}, read_problem
	}
	index := module.export_find(file, export)
	head, _ := module.header(file)
	function, described := module.function(file, index)
	if index == 0 || !described || index == head.entry_export {
		return {}, fmt.tprintf("the module %s has no export %s", service, export)
	}
	if int(function.parameter_count) != len(arguments) {
		return {}, fmt.tprintf("%s.%s has %d parameters; the call gives %d", service, export, function.parameter_count, len(arguments))
	}
	encoded := make([]isolated.Argument, len(arguments), context.temp_allocator)
	for argument, number in arguments {
		type := function.parameters[number]
		name := module.string_at(file, function.parameter_names[number], u32(function.parameter_name_counts[number]))
		#partial switch type {
		case .Integer:
			if argument.is_text {
				return {}, fmt.tprintf("the parameter %s of %s.%s is an Integer, the argument is a Text", name, service, export)
			}
			encoded[number] = {integer = u64(argument.integer)}
		case .Text:
			if !argument.is_text {
				return {}, fmt.tprintf("the parameter %s of %s.%s is a Text, the argument is an Integer", name, service, export)
			}
			encoded[number] = {text = transmute([]u8)argument.text}
		case:
			// A handle of the host has no meaning in the machine, and a
			// Record argument has no text form yet.
			return {}, fmt.tprintf("the parameter %s of %s.%s is a %s: a call from the host gives Integers and Texts only", name, service, export, type_name(file, type, function.parameter_details[number]))
		}
	}
	slice.zero(client.region)
	_, size, result, error, ok := isolated.encode(file, function, encoded, client.region)
	if !ok {
		return {}, fmt.tprintf("the arguments of %s.%s do not fit in a call region", service, export)
	}
	// The bytes that the call region needs: the argument record, its Texts
	// and Records, the place of a Record result and of the error record. The
	// buffer of a Text or a Table result is the rest of the region.
	end := u64(size)
	field := u64(0)
	for type, number in function.parameters[:function.parameter_count] {
		#partial switch type {
		case .Text:
			slice_record := (^isolated.Slice)(&client.region[field])^
			end = max(end, slice_record.start + slice_record.count)
		case .Record:
			start := (^u64)(&client.region[field])^
			described, _ := module.record_type(file, function.parameter_details[number])
			end = max(end, start + u64(described.size))
		}
		field += isolated.field_size(type)
	}
	if error.count != 0 {
		end = max(end, error.start + error.count)
	}
	unit: u32
	#partial switch function.result {
	case .Record:
		end = max(end, result.start + result.count)
	case .Text:
		unit = 1
		result.count = u64(remote.REGION_SIZE) - result.start
	case .Table:
		described, _ := module.record_type(file, function.result_detail)
		unit = described.size
		result.count *= u64(described.size)
	}
	if end > remote.ARGUMENT_LIMIT {
		return {}, fmt.tprintf("the arguments of %s.%s take %d bytes; one call request carries %d", service, export, end, remote.ARGUMENT_LIMIT)
	}
	request := remote.Request {
		kind         = .Call,
		export       = index,
		record_size  = u32(size),
		result_start = u32(result.start),
		result_count = u32(result.count),
		result_unit  = unit,
		error_start  = u32(error.start),
	}
	if function.result == .Integer || function.result == .None {
		request.result_start, request.result_count = 0, 0
	}
	remote.name_set(&request.service, service)
	request.hash = hash
	return {service = service, export = export, file = file, function = function, index = index, request = request, bytes = client.region[:end]}, ""
}

// call_send sends a call request and gives the answer: its header and the
// bytes of the result. It sends the request again when no complete answer
// came: the remote service does not run it two times.
call_send :: proc(client: ^Call_Client, call: ^Prepared_Call) -> (answer: remote.Answer, result: []u8, datagrams: int, ok: bool) {
	client.number += 1
	call.request.number = client.number
	out: [remote.DATAGRAM_LIMIT]u8
	header := call.request
	if client.wrong_hash {
		header.hash[0] ~= 0xFF
		client.wrong_hash = false
	}
	client.last_hash = header.hash
	bytes, written := remote.request_write(out[:], header, call.bytes)
	if !written {
		return {}, nil, 0, false
	}
	parts: [remote.PART_CAPACITY]bool
	received, needed := 0, 0
	start := time.tick_now()
	client.sends = 0
	for time.tick_since(start) < CALL_TIME_LIMIT {
		client.sends += 1
		if _, err := net.send_udp(client.socket, bytes, client.peer); err != nil {
			return {}, nil, 0, false
		}
		sent := time.tick_now()
		for time.tick_since(sent) < CALL_REPEAT_TIME {
			buffer: [remote.DATAGRAM_LIMIT + 1]u8
			count, _, err := net.recv_udp(client.socket, buffer[:])
			if err != nil || count == 0 {
				continue
			}
			header, part, valid := remote.answer_check(buffer[:count])
			if !valid || header.number != client.number {
				continue
			}
			if needed == 0 {
				answer = header
				needed = int(remote.part_count(u64(header.total)))
			} else if header.total != answer.total || header.status != answer.status || header.value != answer.value {
				continue // A part of another answer: the remote service gives one answer for one number.
			}
			number := int(header.offset) / remote.PART_LIMIT
			if !parts[number] {
				parts[number] = true
				copy(client.result[header.offset:], part)
				received += 1
				datagrams += 1
			}
			if received == needed {
				return answer, client.result[:answer.total], datagrams, true
			}
		}
	}
	return {}, nil, datagrams, false
}

// call_run makes one call and gives what the tool prints.
call_run :: proc(client: ^Call_Client, text: string) -> (outcome: Call_Result) {
	outcome.lines = make([dynamic]string, context.temp_allocator)
	call, problem := call_prepare(client, text)
	if problem != "" {
		outcome.outcome = .Wrong
		append(&outcome.lines, fmt.tprintf("error: %s", problem))
		return outcome
	}
	answer, result, datagrams, answered := call_send(client, &call)
	outcome.datagrams = datagrams
	if !answered {
		outcome.outcome = .No_Answer
		append(&outcome.lines, "error: no complete answer in 10 s: does the machine run the program remote? (the menu of the bar, or start(\"remote\") in the console)")
		return outcome
	}
	outcome.value = answer.value
	write_sentence :: proc(prefix: string, record: ^errors.Error_Record, operation, argument: string) -> string {
		buffer := make([]u8, 512, context.temp_allocator)
		writer := sentence.Writer{buffer = buffer}
		sentence.write_part(&writer, prefix)
		sentence.error_text(&writer, record, operation, argument)
		return sentence.written(&writer)
	}
	switch answer.status {
	case .Refused:
		outcome.outcome = .Refused
		field := ""
		if answer.error.argument >= 1 && answer.error.argument <= len(remote.REQUEST_FIELD_NAMES) {
			field = remote.REQUEST_FIELD_NAMES[answer.error.argument - 1]
		}
		append(&outcome.lines, write_sentence("error: ", &answer.error, "remote", field))
		if answer.error.argument == remote.FIELD_HASH {
			append(&outcome.lines, fmt.tprintf("error: the machine runs %s %s; the request named %s (%s is %s): start the machine of this build", call.service, hex_of(answer.hash[:8]), hex_of(client.last_hash[:8]), module_path(call.service), hex_of(call.request.hash[:8])))
		}
		return outcome
	case .Started:
		outcome.outcome = .No_Answer
		append(&outcome.lines, "error: the answer has the status Started")
		return outcome
	case .Ok:
	case:
		outcome.outcome = .Refused
		append(&outcome.lines, fmt.tprintf("error: the answer has the unknown status %d", u32(answer.status)))
		return outcome
	}
	switch isolated.Status(answer.call_status) {
	case .Ok:
	case .Bad_Export:
		outcome.outcome = .Refused
		append(&outcome.lines, fmt.tprintf("error: the service %s has no export %d", call.service, call.index))
		return outcome
	case .Bad_Arguments:
		outcome.outcome = .Refused
		append(&outcome.lines, fmt.tprintf("error: the service %s refused the arguments of %s", call.service, call.export))
		return outcome
	case .Bad_Handle, .Load_Failed:
		outcome.outcome = .Refused
		append(&outcome.lines, fmt.tprintf("error: the service %s refused the call of %s: status %d", call.service, call.export, answer.call_status))
		return outcome
	case:
		outcome.outcome = .Refused
		append(&outcome.lines, fmt.tprintf("error: the service %s gave the unknown status %d", call.service, answer.call_status))
		return outcome
	}
	if call.function.error_record != 0 && answer.value < 0 {
		outcome.outcome = .Failed
		buffer := make([]u8, 512, context.temp_allocator)
		writer := sentence.Writer{buffer = buffer}
		sentence.write_part(&writer, "error: ")
		sentence.export_error_text(&writer, call.file, call.index, call.service, &answer.error)
		sentence.write_part(&writer, fmt.tprintf(" (%d)", answer.value))
		append(&outcome.lines, sentence.written(&writer))
		return outcome
	}
	outcome.outcome = .Result
	#partial switch call.function.result {
	case .None:
		append(&outcome.lines, "done")
	case .Integer:
		append(&outcome.lines, fmt.tprintf("%d", answer.value))
	case .Text:
		for line in strings.split_lines(string(result), context.temp_allocator) {
			append(&outcome.lines, line)
		}
		if answer.value > i64(call.request.result_count) {
			append(&outcome.lines, fmt.tprintf("(the text has %d bytes; %d fit in the call region)", answer.value, len(result)))
		}
	case .Record:
		described, _ := module.record_type(call.file, call.function.result_detail)
		append(&outcome.lines, record_text(call.file, described, result))
	case .Table:
		described, _ := module.record_type(call.file, call.function.result_detail)
		outcome.rows = table_print(&outcome.lines, call.file, described, result, answer.value)
	}
	return outcome
}

// A table that a call gave: the rows, and the description of a row.
Call_Table :: struct {
	file:      []u8,
	described: module.Record,
	rows:      []u8, // A copy, in the temporary memory.
	size:      int, // The bytes of one row.
	total:     i64, // The count of the full table, as the export gave it.
}

// table_call makes a call with a Table result, and gives its rows.
table_call :: proc(client: ^Call_Client, text: string) -> (table: Call_Table, ok: bool) {
	call, problem := call_prepare(client, text)
	if problem != "" || call.function.result != .Table {
		return {}, false
	}
	answer, result, _, answered := call_send(client, &call)
	if !answered || answer.status != .Ok || isolated.Status(answer.call_status) != .Ok || answer.value < 0 {
		return {}, false
	}
	table.described = module.record_type(call.file, call.function.result_detail) or_return
	table.file = call.file
	table.size = int(max(table.described.size, 1))
	table.rows = slice.clone(result[:len(result) / table.size * table.size], context.temp_allocator)
	table.total = answer.value
	return table, true
}

// table_value gives the field with a name of row `row`, as text: an
// Integer as decimal digits.
table_value :: proc(table: ^Call_Table, row: int, name: string) -> string {
	bytes := table.rows[row * table.size:][:table.size]
	for number in 0 ..< table.described.field_count {
		item, _ := module.field(table.file, table.described, number)
		if module.string_at(table.file, item.name_offset, item.name_count) == name {
			return field_value(bytes, item)
		}
	}
	return ""
}

// hex_of gives bytes in hexadecimal.
hex_of :: proc(bytes: []u8) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for byte in bytes {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	return strings.to_string(builder)
}

// record_field calls an export with no arguments and a Record result, or
// a Table result, and gives one Integer field of the record (of the first
// row of the Table), by its name.
record_field :: proc(client: ^Call_Client, text: string, name: string) -> (value: i64, ok: bool) {
	values := record_fields(client, text, {name}) or_return
	return values[0], true
}

// record_fields gives several Integer fields, from one call.
record_fields :: proc(client: ^Call_Client, text: string, names: []string) -> (values: []i64, ok: bool) {
	call, problem := call_prepare(client, text)
	if problem != "" || (call.function.result != .Record && call.function.result != .Table) {
		return nil, false
	}
	answer, result, _, answered := call_send(client, &call)
	if !answered || answer.status != .Ok || isolated.Status(answer.call_status) != .Ok || (call.function.result == .Table && answer.value < 1) {
		return nil, false
	}
	described := module.record_type(call.file, call.function.result_detail) or_return
	values = make([]i64, len(names), context.temp_allocator)
	found := 0
	for name, index in names {
		for number in 0 ..< described.field_count {
			item := module.field(call.file, described, number) or_return
			if module.string_at(call.file, item.name_offset, item.name_count) == name && item.type == .Integer && int(item.offset) + 8 <= len(result) {
				values[index] = (^i64)(&result[item.offset])^
				found += 1
			}
		}
	}
	return values, found == len(names)
}

// field_value gives the text of one field of a record.
field_value :: proc(record: []u8, item: module.Field) -> string {
	#partial switch item.type {
	case .Integer:
		if u64(item.offset) + 8 <= u64(len(record)) {
			return fmt.tprintf("%d", (^i64)(&record[item.offset])^)
		}
	case .Handle:
		if u64(item.offset) + 4 <= u64(len(record)) {
			return fmt.tprintf("0x%x", (^u32)(&record[item.offset])^)
		}
	case .Text:
		return module.field_text(record, item)
	}
	return "?"
}

// record_text gives a record as Name{field = value, field = "text"}.
record_text :: proc(file: []u8, described: module.Record, record: []u8) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, module.string_at(file, described.name_offset, described.name_count))
	strings.write_byte(&builder, '{')
	for number in 0 ..< described.field_count {
		item, _ := module.field(file, described, number)
		if number > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(&builder, module.string_at(file, item.name_offset, item.name_count))
		strings.write_string(&builder, " = ")
		value := field_value(record, item)
		if item.type == .Text {
			strings.write_quoted_string(&builder, value)
		} else {
			strings.write_string(&builder, value)
		}
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// table_print writes a table: one line of the names of the fields, one line
// for each record, each column as wide as its widest value, and a count.
// It gives the count of rows that it printed.
table_print :: proc(lines: ^[dynamic]string, file: []u8, described: module.Record, bytes: []u8, count: i64) -> int {
	size := int(max(described.size, 1))
	rows := len(bytes) / size
	columns := int(described.field_count)
	cells := make([][]string, rows + 1, context.temp_allocator)
	widths := make([]int, columns, context.temp_allocator)
	numeric := make([]bool, columns, context.temp_allocator)
	for row in 0 ..= rows {
		cells[row] = make([]string, columns, context.temp_allocator)
		for column in 0 ..< columns {
			item, _ := module.field(file, described, u32(column))
			value := row == 0 ? module.string_at(file, item.name_offset, item.name_count) : field_value(bytes[(row - 1) * size:][:size], item)
			cells[row][column] = value
			widths[column] = max(widths[column], len(value))
			numeric[column] = item.type != .Text
		}
	}
	for row in cells {
		builder := strings.builder_make(context.temp_allocator)
		for value, column in row {
			if column > 0 {
				strings.write_string(&builder, "  ")
			}
			pad := widths[column] - len(value)
			if numeric[column] {
				for _ in 0 ..< pad {
					strings.write_byte(&builder, ' ')
				}
				strings.write_string(&builder, value)
			} else {
				strings.write_string(&builder, value)
				if column < columns - 1 {
					for _ in 0 ..< pad {
						strings.write_byte(&builder, ' ')
					}
				}
			}
		}
		append(lines, strings.to_string(builder))
	}
	name := module.string_at(file, described.name_offset, described.name_count)
	if i64(rows) < count {
		append(lines, fmt.tprintf("%d rows of %s; the table has %d, and %d fit in the call region", rows, name, count, rows))
	} else {
		append(lines, fmt.tprintf("%d rows of %s", rows, name))
	}
	return rows
}

// call_measure sends the same call again and again: the round trip of one
// call, then the calls in one second, one after the other.
call_measure :: proc(client: ^Call_Client, text: string, count: int) -> (least, middle: time.Duration, per_second: int, ok: bool) {
	call, problem := call_prepare(client, text)
	if problem != "" {
		return 0, 0, 0, false
	}
	times := make([]time.Duration, count, context.temp_allocator)
	for index in 0 ..< count {
		start := time.tick_now()
		_, _, _, answered := call_send(client, &call)
		if !answered {
			return 0, 0, 0, false
		}
		times[index] = time.tick_since(start)
	}
	slice.sort(times)
	start := time.tick_now()
	for time.tick_since(start) < time.Second {
		if _, _, _, answered := call_send(client, &call); !answered {
			return 0, 0, 0, false
		}
		per_second += 1
	}
	return times[0], times[count / 2], per_second, true
}

// run_call is the command `call`: a call to the machine that `kerneltool
// run` started.
run_call :: proc(args: []string) -> int {
	if len(args) != 1 {
		fmt.eprintln("kerneltool: call \"service.export(arguments)\", for example call \"monitor.programs()\"")
		return EXIT_USAGE
	}
	client: Call_Client
	if !call_client_open(&client, CALL_PORT) {
		return EXIT_FAILURE
	}
	defer call_client_close(&client)
	result := call_run(&client, args[0])
	for line in result.lines {
		if result.outcome == .Result {
			fmt.println(line)
		} else {
			fmt.eprintln(line)
		}
	}
	return result.outcome == .Result ? 0 : EXIT_FAILURE
}
