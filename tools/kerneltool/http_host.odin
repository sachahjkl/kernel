package kerneltool

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import "support:web"

// The tests of the HTTP/1.1 server of the system, from the host: the TCP of
// the host connects through hostfwd and libslirp (web_host.odin), and the
// tool checks each answer with its own reading of HTTP (support/web).

HTTP_HOST_WAIT_LIMIT :: 120 * time.Second

// An HTTP connection of the host: the bytes that came and were not used
// yet, so that answers in one segment, or split, are read right.
Http_Host_Connection :: struct {
	socket:   net.TCP_Socket,
	received: [dynamic]u8,
}

Http_Host_Answer :: struct {
	status:         int,
	content_length: int,
	head:           string,
	body:           []u8,
	ok:             bool,
}

http_host_connect :: proc(forward: Forward) -> (connection: Http_Host_Connection, ok: bool) {
	socket, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, forward.host_port})
	if err != nil {
		fmt.eprintfln("kerneltool: the host cannot connect to the port %d: %v", forward.host_port, err)
		return {}, false
	}
	// The bound of a wait for an answer: the timers of the server count on
	// the clock of the machine, which a loaded host slows (the flake of
	// master failed at a load of 28 on the 408 after 10 s). The bound only
	// ends a test that hangs; no check compares a time of the host.
	_ = net.set_option(socket, .Receive_Timeout, HTTP_HOST_WAIT_LIMIT)
	return {socket = socket, received = make([dynamic]u8, context.temp_allocator)}, true
}

http_host_close :: proc(connection: ^Http_Host_Connection) {
	net.close(connection.socket)
}

http_host_send :: proc(connection: ^Http_Host_Connection, text: string) -> bool {
	return send_all(connection.socket, transmute([]u8)text)
}

// http_host_answer reads one answer: its head, and its body of
// Content-Length bytes (none for an answer of HEAD).
http_host_answer :: proc(connection: ^Http_Host_Connection, of_head := false) -> (answer: Http_Host_Answer) {
	buffer: [65536]u8
	head: web.Head
	for {
		if web.head_end(connection.received[:]) != 0 {
			ok: bool
			if head, ok = web.head_read(connection.received[:]); !ok {
				return {}
			}
			length := of_head ? 0 : max(head.content_length, 0)
			if len(connection.received) >= head.size + length {
				answer = {status = head.status, content_length = head.content_length, ok = true}
				answer.head = strings.clone(string(connection.received[:head.size]), context.temp_allocator)
				answer.body = make([]u8, length, context.temp_allocator)
				copy(answer.body, connection.received[head.size:])
				remove_range(&connection.received, 0, head.size + length)
				return answer
			}
		}
		count, err := net.recv_tcp(connection.socket, buffer[:])
		if err != nil || count == 0 {
			return {}
		}
		append(&connection.received, ..buffer[:count])
	}
}

// http_host_request sends a request on a new connection and reads its answer.
http_host_request :: proc(forward: Forward, request: string, of_head := false) -> Http_Host_Answer {
	connection, ok := http_host_connect(forward)
	if !ok {
		return {}
	}
	defer http_host_close(&connection)
	if !http_host_send(&connection, request) {
		return {}
	}
	return http_host_answer(&connection, of_head)
}

// http_host_read_to_the_end reads until the server ends the connection, or
// for limit at most. ended says if the end came.
http_host_read_to_the_end :: proc(connection: ^Http_Host_Connection, limit: time.Duration) -> (bytes: []u8, ended: bool, took: time.Duration) {
	_ = net.set_option(connection.socket, .Receive_Timeout, limit)
	start := time.tick_now()
	buffer: [65536]u8
	for time.tick_since(start) < limit {
		count, err := net.recv_tcp(connection.socket, buffer[:])
		if err != nil {
			// A RST ends the connection too; a timeout does not.
			ended = err != net.TCP_Recv_Error.Timeout
			break
		}
		if count == 0 {
			ended = true
			break
		}
		append(&connection.received, ..buffer[:count])
	}
	return connection.received[:], ended, time.tick_since(start)
}

// answers_count reads the answers in bytes one after the other, by their
// heads and their Content-Length; heads_only gives the places of the
// answers to HEAD (no body). It stops at bytes that are not an answer.
answers_count :: proc(bytes: []u8, heads_only: []int = nil) -> int {
	count, offset := 0, 0
	for offset < len(bytes) {
		end := web.head_end(bytes[offset:])
		if end == 0 {
			break
		}
		head, ok := web.head_read(bytes[offset:][:end])
		if !ok {
			break
		}
		body := max(head.content_length, 0)
		for place in heads_only {
			if place == count {
				body = 0
			}
		}
		offset += end + body
		count += 1
	}
	return count
}

// http_case_run runs one case; it prints what it found, and says if each
// answer is the expected one.
http_case_run :: proc(forward: Forward, case_text: string, expected: string) -> bool {
	parts := strings.fields(case_text, context.temp_allocator)
	if len(parts) == 0 {
		return false
	}
	switch parts[0] {
	case "keep-alive":
		// Requests one after the other on one connection.
		COUNT :: 1000
		connection, ok := http_host_connect(forward)
		if !ok {
			return false
		}
		defer http_host_close(&connection)
		start := time.tick_now()
		for index in 0 ..< COUNT {
			if !http_host_send(&connection, "GET /counts.json HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n") {
				return false
			}
			answer := http_host_answer(&connection)
			if !answer.ok || answer.status != 200 || !strings.has_prefix(string(answer.body), "{\"connections_open\":") {
				fmt.eprintfln("kerneltool: the answer %d of the connection: status %d, %q", index, answer.status, string(answer.body))
				return false
			}
			free_all(context.temp_allocator)
		}
		took := time.tick_since(start)
		fmt.printfln("kerneltool: test passed: %d requests on one connection of the host through libslirp, each 200: %.0f requests in one second (the clock of the host)", COUNT, f64(COUNT) / time.duration_seconds(took))
	case "new-connections":
		// One connection for each request.
		COUNT :: 300
		start := time.tick_now()
		for index in 0 ..< COUNT {
			answer := http_host_request(forward, "GET /counts.json HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n")
			if !answer.ok || answer.status != 200 {
				fmt.eprintfln("kerneltool: the request %d with a new connection: status %d", index, answer.status)
				return false
			}
			free_all(context.temp_allocator)
		}
		took := time.tick_since(start)
		fmt.printfln("kerneltool: test passed: %d requests, each with a new connection of the host through libslirp, each 200: %.0f requests in one second (the clock of the host)", COUNT, f64(COUNT) / time.duration_seconds(took))
	case "pipeline":
		// Three requests in one send: three answers, in order.
		connection, ok := http_host_connect(forward)
		if !ok {
			return false
		}
		defer http_host_close(&connection)
		http_host_send(&connection, "GET / HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\nHEAD /counts.json HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\nGET /nothing HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n")
		first := http_host_answer(&connection)
		second := http_host_answer(&connection, of_head = true)
		third := http_host_answer(&connection)
		if first.status != 200 || !strings.has_prefix(string(first.body), "<!doctype html>") || second.status != 200 || second.content_length <= 0 || third.status != 404 {
			fmt.eprintfln("kerneltool: the pipelined answers: %d, %d (Content-Length %d), %d", first.status, second.status, second.content_length, third.status)
			return false
		}
		fmt.printfln("kerneltool: test passed: three requests in one segment, three answers in order: GET / 200 (%d bytes), HEAD /counts.json 200 (Content-Length %d, no body), GET /nothing 404", len(first.body), second.content_length)
	case "split":
		// A head and a body in many sends, with waits between them.
		connection, ok := http_host_connect(forward)
		if !ok {
			return false
		}
		defer http_host_close(&connection)
		SIZE :: 200_000
		head := fmt.tprintf("POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: %d\r\n\r\n", SIZE)
		http_host_send(&connection, head[:7])
		time.sleep(20 * time.Millisecond)
		http_host_send(&connection, head[7:])
		body := make([]u8, SIZE, context.temp_allocator)
		web.pattern_fill(body, 0)
		for offset := 0; offset < SIZE; offset += SIZE / 10 {
			send_all(connection.socket, body[offset:][:SIZE / 10])
			time.sleep(20 * time.Millisecond)
		}
		answer := http_host_answer(&connection)
		wanted := fmt.tprintf("received %d bytes, fnv1a64 %016x", SIZE, web.pattern_hash(SIZE))
		if answer.status != 200 || !strings.has_prefix(string(answer.body), wanted) {
			fmt.eprintfln("kerneltool: the split body: status %d, %q", answer.status, string(answer.body))
			return false
		}
		fmt.printfln("kerneltool: test passed: a head in 2 sends and a body of %d bytes in 10, 20 ms apart: the server gave the same hash", SIZE)
	case "head":
		// HEAD gives the head of GET with no body: the next request on the
		// same connection is read right.
		connection, ok := http_host_connect(forward)
		if !ok {
			return false
		}
		defer http_host_close(&connection)
		http_host_send(&connection, "HEAD / HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n")
		head := http_host_answer(&connection, of_head = true)
		http_host_send(&connection, "GET /counts.json HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n")
		after := http_host_answer(&connection)
		if head.status != 200 || head.content_length <= 0 || !strings.contains(head.head, "text/html") || after.status != 200 {
			fmt.eprintfln("kerneltool: HEAD: status %d, Content-Length %d; the next answer %d", head.status, head.content_length, after.status)
			return false
		}
		fmt.printfln("kerneltool: test passed: HEAD / gave 200, text/html and Content-Length %d with no body; the next request on the connection gave 200", head.content_length)
	case "errors":
		Error_Case :: struct {
			name:    string,
			request: string,
			status:  int,
		}
		long_target := strings.repeat("a", 1100, context.temp_allocator)
		many_fields := strings.repeat("X-Field: a\r\n", 70, context.temp_allocator)
		cases := []Error_Case {
			{"no Host", "GET / HTTP/1.1\r\n\r\n", 400},
			{"a bad request line", "GET  / HTTP/1.1\r\nHost: a\r\n\r\n", 400},
			{"PUT", "PUT /hello.txt HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nhi", 405},
			{"DELETE", "DELETE /hello.txt HTTP/1.1\r\nHost: a\r\n\r\n", 405},
			{"no such page", "GET /nothing.html HTTP/1.1\r\nHost: a\r\n\r\n", 404},
			{"a target of 1100 bytes", fmt.tprintf("GET /%s HTTP/1.1\r\nHost: a\r\n\r\n", long_target), 414},
			{"71 fields", fmt.tprintf("GET / HTTP/1.1\r\nHost: a\r\n%s\r\n", many_fields), 431},
			{"a body over 16 MiB", "POST /sink HTTP/1.1\r\nHost: a\r\nContent-Length: 99999999999\r\n\r\n", 413},
			{"an unknown method", "BREW / HTTP/1.1\r\nHost: a\r\n\r\n", 501},
			{"a chunked body", "POST /sink HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", 501},
			{"HTTP/2.0", "GET / HTTP/2.0\r\nHost: a\r\n\r\n", 505},
		}
		found := strings.builder_make(context.temp_allocator)
		for item in cases {
			answer := http_host_request(forward, item.request)
			if answer.status != item.status {
				fmt.eprintfln("kerneltool: %s: status %d, not %d", item.name, answer.status, item.status)
				return false
			}
			fmt.sbprintf(&found, " %s %d;", item.name, answer.status)
		}
		// Half a head, then nothing: 408 after 10 s of the clock of the
		// machine; the host waits up to HTTP_HOST_WAIT_LIMIT.
		start := time.tick_now()
		late := http_host_request(forward, "GET / HTTP/1.1\r\nHo")
		if late.status != 408 {
			fmt.eprintfln("kerneltool: half a head: status %d, not 408", late.status)
			return false
		}
		fmt.printfln("kerneltool: test passed: each refusal has its status:%s half a head 408 after %.1f s", strings.to_string(found), time.duration_seconds(time.tick_since(start)))
	case "page":
		// A page of the store of the server, byte for byte.
		answer := http_host_request(forward, fmt.tprintf("GET /%s HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n", parts[1]))
		if answer.status != 200 || string(answer.body) != expected {
			fmt.eprintfln("kerneltool: /%s: status %d, %q, not %q", parts[1], answer.status, string(answer.body), expected)
			return false
		}
		fmt.printfln("kerneltool: test passed: the host fetched /%s from the store of server: %d bytes, the same bytes that the console put", parts[1], len(answer.body))
	case "missing":
		answer := http_host_request(forward, fmt.tprintf("GET /%s HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n", parts[1]))
		if answer.status != 404 {
			fmt.eprintfln("kerneltool: /%s: status %d, not 404", parts[1], answer.status)
			return false
		}
		fmt.printfln("kerneltool: test passed: /%s gives 404 after server.remove", parts[1])
	// An independent read of the HTTP server (F4): a request with a body
	// that the server does not take. The body must not be read as the next
	// request (RFC 9112 6.3; with a proxy before the server: request
	// smuggling): one answer, then the end of the connection.
	case "body-not-taken":
		connection, ok := http_host_connect(forward)
		if !ok {
			return false
		}
		defer http_host_close(&connection)
		hidden := "GET /nothing HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n"
		http_host_send(&connection, fmt.tprintf("GET / HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: %d\r\n\r\n%s", len(hidden), hidden))
		bytes, ended, took := http_host_read_to_the_end(&connection, HTTP_HOST_WAIT_LIMIT)
		answers := answers_count(bytes)
		if answers != 1 || !ended || !strings.has_prefix(string(bytes), "HTTP/1.1 200 ") {
			fmt.eprintfln("kerneltool: a GET with a body of a request: %d answers, the end of the connection: %v, the first line %q", answers, ended, string(bytes[:min(len(bytes), 20)]))
			return false
		}
		fmt.printfln("kerneltool: test passed: a GET with a body that is a request: one answer 200, then the server ended the connection after %.0f ms; the body was not read as a request", time.duration_milliseconds(took))
	// W7: three whole requests, then a FIN: three answers, then the end.
	case "requests-then-fin":
		connection, ok := http_host_connect(forward)
		if !ok {
			return false
		}
		defer http_host_close(&connection)
		http_host_send(&connection, "GET /counts.json HTTP/1.1\r\nHost: a\r\n\r\nGET /nothing HTTP/1.1\r\nHost: a\r\n\r\nHEAD / HTTP/1.1\r\nHost: a\r\n\r\n")
		net.shutdown(connection.socket, .Send)
		bytes, ended, _ := http_host_read_to_the_end(&connection, HTTP_HOST_WAIT_LIMIT)
		answers := answers_count(bytes, {2})
		if answers != 3 || !ended {
			fmt.eprintfln("kerneltool: three requests then a FIN: %d answers, the end of the connection: %v", answers, ended)
			return false
		}
		fmt.printfln("kerneltool: test passed: three requests then a FIN in one send: three answers (200, 404, 200 of HEAD), then the end of the connection")
	// The notes of the read: each answer says nosniff; HTTP/1.0 with
	// keep-alive gets "Connection: keep-alive" and a second answer on the
	// same connection.
	case "headers":
		connection, ok := http_host_connect(forward)
		if !ok {
			return false
		}
		defer http_host_close(&connection)
		http_host_send(&connection, "GET /counts.json HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
		first := http_host_answer(&connection)
		http_host_send(&connection, "GET /nothing HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
		second := http_host_answer(&connection)
		head := strings.to_lower(first.head, context.temp_allocator)
		if first.status != 200 || !strings.contains(head, "\r\nx-content-type-options: nosniff\r\n") || !strings.contains(head, "\r\nconnection: keep-alive\r\n") || second.status != 404 || !strings.contains(strings.to_lower(second.head, context.temp_allocator), "nosniff") {
			fmt.eprintfln("kerneltool: HTTP/1.0 with keep-alive: %d, then %d; the head %q", first.status, second.status, first.head)
			return false
		}
		fmt.printfln("kerneltool: test passed: HTTP/1.0 with keep-alive: the answer says Connection: keep-alive and X-Content-Type-Options: nosniff, and a second request on the connection gets its answer (404, nosniff too)")
	case "crowd":
		// 16 connections at once: each sends, then each reads.
		COUNT :: 16
		connections: [COUNT]Http_Host_Connection
		for &connection in connections {
			ok: bool
			if connection, ok = http_host_connect(forward); !ok {
				return false
			}
		}
		for &connection in connections {
			http_host_send(&connection, "GET / HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n")
		}
		answered := 0
		for &connection in connections {
			answer := http_host_answer(&connection)
			if answer.status == 200 {
				answered += 1
			}
			http_host_close(&connection)
		}
		if answered != COUNT {
			fmt.eprintfln("kerneltool: 16 connections at once: %d answers 200", answered)
			return false
		}
		fmt.printfln("kerneltool: test passed: 16 connections of the host at once, 16 answers 200")
	case:
		return false
	}
	return true
}
