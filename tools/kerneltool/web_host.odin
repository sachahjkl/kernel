package kerneltool

import "core:strconv"

import "support:calendar"

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "support:web"

// The test of TCP against a stack that this project did not write
// (docs/NETWORK.md). The machine has QEMU user networking: its TCP talks
// to the TCP of libslirp, which comes from 4.4BSD. Two ways:
//
//   hostfwd   a port of the loopback of the host goes to the port 80 of the
//             machine: the tool connects with core:net (the TCP of the host)
//             and fetches the pages of `server` (forward_fetch).
//   guestfwd  the address 10.0.2.100 port 80 of the network of the machine
//             goes to a port where the tool listens with core:net: the
//             program `fetch` connects to it (Listener).
//
// The listener answers as `server` does: GET /hello, GET /large, and POST
// /sink, which gives the length and the hash of the body.

GUEST_ADDRESS :: "10.0.2.100" // The address of the listener on the network of the machine.

Forward :: struct {
	host_port: int, // hostfwd: this port of the loopback of the host is the port 80 of the machine.
	listener:  ^Listener,
}

Listener :: struct {
	socket:     net.TCP_Socket,
	client:     net.TCP_Socket, // The connection that the listener serves; 0: none.
	port:       int,
	thread:     ^thread.Thread,
	stop:       bool,
	requests:   int,
	sink_bytes: int,
	failure:    string,
}

// free_port gives a port of the loopback that no socket holds now. Another
// program can take it before QEMU: the tests run one at a time.
free_port :: proc() -> (port: int, ok: bool) {
	socket, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		return 0, false
	}
	defer net.close(socket)
	bound, bound_err := net.bound_endpoint(socket)
	return bound.port, bound_err == nil
}

listener_start :: proc(listener: ^Listener) -> bool {
	socket, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		fmt.eprintfln("kerneltool: the listener has no TCP socket: %v", err)
		return false
	}
	bound, bound_err := net.bound_endpoint(socket)
	if bound_err != nil {
		net.close(socket)
		return false
	}
	listener^ = {socket = socket, port = bound.port}
	listener.thread = thread.create_and_start_with_poly_data(listener, listener_run)
	return true
}

listener_stop :: proc(listener: ^Listener) {
	if listener.thread == nil {
		return
	}
	sync.atomic_store(&listener.stop, true)
	// A shutdown ends a receive that waits, and the accept.
	if client := net.TCP_Socket(sync.atomic_load((^int)(&listener.client))); client != 0 {
		_ = net.shutdown(client, .Both)
	}
	_ = net.shutdown(listener.socket, .Both)
	net.close(listener.socket)
	thread.join(listener.thread)
	thread.destroy(listener.thread)
	listener.thread = nil
}

listener_run :: proc(listener: ^Listener) {
	for !sync.atomic_load(&listener.stop) {
		client, _, err := net.accept_tcp(listener.socket)
		if err != nil {
			return
		}
		// QEMU connects when it starts, long before `fetch` sends a request:
		// the receive waits with no time limit.
		sync.atomic_store((^int)(&listener.client), int(client))
		listener_serve(listener, client)
		sync.atomic_store((^int)(&listener.client), 0)
		net.close(client)
	}
}

// send_all sends each byte, or says that it could not.
send_all :: proc(socket: net.TCP_Socket, bytes: []u8) -> bool {
	for sent := 0; sent < len(bytes); {
		count, err := net.send_tcp(socket, bytes[sent:])
		if err != nil || count <= 0 {
			return false
		}
		sent += count
	}
	return true
}

// listener_serve answers the requests of one connection until its end.
listener_serve :: proc(listener: ^Listener, client: net.TCP_Socket) {
	buffer: [65536]u8
	length := 0
	for !sync.atomic_load(&listener.stop) {
		if web.head_end(buffer[:length]) == 0 {
			count, err := net.recv_tcp(client, buffer[length:])
			if err != nil || count == 0 {
				return
			}
			length += count
			continue
		}
		head, ok := web.head_read(buffer[:length])
		rest := buffer[head.size:length]
		if !ok {
			listener.failure = "a request that the listener cannot read"
			return
		}
		path := web.path(&head)
		answer: string
		switch {
		case head.method == .Get && path == "/hello":
			answer = "hello from the host\n"
		case head.method == .Get && path == "/large":
			head_text := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n", web.LARGE_SIZE)
			if !send_all(client, transmute([]u8)head_text) {
				return
			}
			chunk: [16384]u8
			for offset := 0; offset < web.LARGE_SIZE; offset += len(chunk) {
				web.pattern_fill(chunk[:], offset)
				if !send_all(client, chunk[:min(len(chunk), web.LARGE_SIZE - offset)]) {
					return
				}
			}
			sync.atomic_add(&listener.requests, 1)
			length = copy(buffer[:], rest)
			continue
		case head.method == .Post && path == "/sink" && head.content_length >= 0:
			hash := u64(web.FNV_START)
			taken := min(len(rest), head.content_length)
			hash = web.fnv(hash, rest[:taken])
			received := taken
			for received < head.content_length {
				count, err := net.recv_tcp(client, buffer[:min(len(buffer), head.content_length - received)])
				if err != nil || count == 0 {
					listener.failure = "the body of /sink ended early"
					return
				}
				hash = web.fnv(hash, buffer[:count])
				received += count
			}
			listener.sink_bytes = received
			answer = fmt.tprintf("received %d bytes, fnv1a64 %016x\n", received, hash)
			rest = nil
		case:
			answer = "no such page\n"
		}
		text := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s", len(answer), answer)
		if !send_all(client, transmute([]u8)text) {
			return
		}
		sync.atomic_add(&listener.requests, 1)
		length = copy(buffer[:], rest)
		free_all(context.temp_allocator)
	}
}

// forward_fetch fetches a page of `server` through hostfwd, with the TCP of
// the host. "/sink" sends a body of LARGE_SIZE bytes. It prints one line
// with the result, and says if the result is the expected one.
forward_fetch :: proc(forward: Forward, path: string) -> bool {
	socket, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, forward.host_port})
	if err != nil {
		fmt.eprintfln("kerneltool: test failed: the host cannot connect to the port %d (hostfwd to the port 80 of the machine): %v", forward.host_port, err)
		return false
	}
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, HTTP_HOST_WAIT_LIMIT)
	start := time.tick_now()
	request_unix := time.time_to_unix(time.now()) // No date in the answer is before it.
	request: string
	body := path == "/sink"
	if body {
		request = fmt.tprintf("POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", web.LARGE_SIZE)
	} else {
		request = fmt.tprintf("GET %s HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n", path)
	}
	if !send_all(socket, transmute([]u8)request) {
		fmt.eprintln("kerneltool: test failed: the host could not send its request")
		return false
	}
	if body {
		chunk: [16384]u8
		for offset := 0; offset < web.LARGE_SIZE; offset += len(chunk) {
			web.pattern_fill(chunk[:], offset)
			if !send_all(socket, chunk[:]) {
				fmt.eprintln("kerneltool: test failed: the host could not send the body of /sink")
				return false
			}
		}
	}
	// The response, to the end of the connection: the server closes it.
	response := make([dynamic]u8, context.temp_allocator)
	buffer: [65536]u8
	for {
		count, recv_err := net.recv_tcp(socket, buffer[:])
		if recv_err != nil || count == 0 {
			break
		}
		append(&response, ..buffer[:count])
	}
	took := time.tick_since(start)
	head, ok := web.head_read(response[:])
	if !ok || head.status != 200 || len(response) - head.size != head.content_length {
		fmt.eprintfln("kerneltool: test failed: the host fetched %s and read %d bytes, the status %d and the Content-Length %d", path, len(response), head.status, head.content_length)
		return false
	}
	content := response[head.size:]
	// RFC 9110 6.6.1: the server sends the date of the machine.
	head_text := string(response[:head.size])
	date_at := strings.index(head_text, "\r\nDate: ")
	if date_at < 0 {
		fmt.eprintfln("kerneltool: test failed: the answer of server to %s has no field Date", path)
		return false
	}
	date_line := head_text[date_at + 8:]
	date_line = date_line[:max(strings.index(date_line, "\r\n"), 0)]
	date_seconds, date_ok := http_date_parse(date_line)
	if !date_ok {
		fmt.eprintfln("kerneltool: test failed: the field Date of server is \"%s\": not the form of RFC 9110 5.6.7", date_line)
		return false
	}
	date_check(-1, date_seconds, fmt.tprintf("the field Date \"%s\" of the answer to %s", date_line, path), request_unix) or_return
	speed := f64(max(len(content), body ? web.LARGE_SIZE : 0)) / max(time.duration_seconds(took), 1e-9) / 1e6
	switch path {
	case "/large":
		hash := web.fnv(web.FNV_START, content)
		if len(content) != web.LARGE_SIZE || hash != web.pattern_hash(web.LARGE_SIZE) {
			fmt.eprintfln("kerneltool: test failed: /large from the machine has %d bytes and the hash %016x", len(content), hash)
			return false
		}
		test_passed_print("the TCP of the host fetched /large from server through libslirp: %d bytes, fnv1a64 %016x as expected, %.1f MB/s", len(content), hash, speed)
	case "/sink":
		wanted := fmt.tprintf("received %d bytes, fnv1a64 %016x", web.LARGE_SIZE, web.pattern_hash(web.LARGE_SIZE))
		if !strings.has_prefix(string(content), wanted) {
			fmt.eprintfln("kerneltool: test failed: server answered \"%s\" to /sink, not \"%s\"", string(content), wanted)
			return false
		}
		test_passed_print("the TCP of the host sent 1 MiB to server through libslirp, and server gave the same hash, %.1f MB/s", speed)
	case:
		test_passed_print("the TCP of the host fetched %s from server through libslirp: %d bytes in %.2f ms: \"%s\"", path, len(content), time.duration_milliseconds(took), strings.trim_space(strings.split_lines(string(content), context.temp_allocator)[0]))
	}
	return true
}

FRAMES_OF_USER_NETWORK :: BUILD_FOLDER + "/frames_of_user_network.pcap"

// frames_of_the_fetch_report reads the frames that QEMU wrote for the
// machine with libslirp (filter-dump, the pcap format) and prints the frames
// of `GET /hello` of `fetch`: from its request to the end of the answer,
// each with its time after the request, its direction, its flags and its
// bytes of data. It is a measure, not a check.
frames_of_the_fetch_report :: proc() {
	bytes, err := os.read_entire_file(FRAMES_OF_USER_NETWORK, context.temp_allocator)
	if err != nil || len(bytes) < 24 {
		fmt.println("kerneltool: no frames of the machine with libslirp")
		return
	}
	read_32_little :: proc(bytes: []u8, offset: int) -> u64 {
		return u64(bytes[offset]) | u64(bytes[offset + 1]) << 8 | u64(bytes[offset + 2]) << 16 | u64(bytes[offset + 3]) << 24
	}
	start: u64
	printed := 0
	after_answer := -1
	for offset := 24; offset + 16 <= len(bytes) && printed < 24; {
		time_of_frame := read_32_little(bytes, offset) * 1_000_000 + read_32_little(bytes, offset + 4)
		length := int(read_32_little(bytes, offset + 8))
		frame := bytes[offset + 16:][:min(length, len(bytes) - offset - 16)]
		offset += 16 + length
		if len(frame) < 54 || frame[12] != 0x08 || frame[13] != 0x00 || frame[23] != 6 {
			continue
		}
		ip := frame[14:]
		header := int(ip[0] & 15) * 4
		total := int(ip[2]) << 8 | int(ip[3])
		segment := ip[header:min(total, len(ip))]
		if len(segment) < 20 {
			continue
		}
		data := segment[int(segment[12] >> 4) * 4:]
		from_machine := ip[12] == 10 && ip[15] == 15
		other := from_machine ? ip[19] : ip[15]
		if other != 100 {
			continue // Only the connection of fetch to 10.0.2.100.
		}
		if start == 0 {
			if !from_machine || !strings.has_prefix(string(data), "GET /hello") {
				continue
			}
			start = time_of_frame
		}
		flags := segment[13]
		names := [6]string{"FIN", "SYN", "RST", "PSH", "ACK", "URG"}
		text := strings.builder_make(context.temp_allocator)
		for name, bit in names {
			if flags >> uint(bit) & 1 != 0 {
				strings.write_string(&text, name)
				strings.write_byte(&text, ' ')
			}
		}
		fmt.printfln("kerneltool: a frame of GET /hello through libslirp: +%d us, %s, %s%d bytes of data%s", time_of_frame - start, from_machine ? "fetch to libslirp" : "libslirp to fetch", strings.to_string(text), len(data), strings.has_prefix(string(data), "HTTP/1.1") ? " (the answer)" : "")
		printed += 1
		if !from_machine && strings.has_prefix(string(data), "HTTP/1.1") {
			after_answer = 2
		} else if after_answer > 0 {
			after_answer -= 1
		}
		if after_answer == 0 {
			break
		}
	}
}

// http_date_parse reads an IMF-fixdate (RFC 9110 5.6.7):
// "Sun, 06 Nov 1994 08:49:37 GMT".
http_date_parse :: proc(text: string) -> (seconds: i64, ok: bool) {
	if len(text) != 29 || text[3] != ',' || text[25:] != " GMT" {
		return 0, false
	}
	month := 0
	for name, index in calendar.MONTH_SHORT_NAMES {
		if text[8:11] == name {
			month = index + 1
		}
	}
	day, day_ok := strconv.parse_int(text[5:7])
	year, year_ok := strconv.parse_i64(text[12:16])
	hour, hour_ok := strconv.parse_int(text[17:19])
	minute, minute_ok := strconv.parse_int(text[20:22])
	second, second_ok := strconv.parse_int(text[23:25])
	if month == 0 || !day_ok || !year_ok || !hour_ok || !minute_ok || !second_ok {
		return 0, false
	}
	value := calendar.Civil{year = year, month = month, day = day, hour = hour, minute = minute, second = second}
	seconds = calendar.seconds_of(value)
	return seconds, calendar.WEEKDAY_SHORT_NAMES[calendar.civil(seconds).weekday] == text[:3]
}
