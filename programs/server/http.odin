package server

// The HTTP side of each connection (RFC 9112): the bytes of a connection
// are read into the input of its session; a request head is read there
// (web.request_read); the bytes after a head are the body, or the next
// request (pipelining: no byte is lost, and the answers go in the order of
// the requests). One answer at a time for each connection: the next head is
// read when the answer before it is all in the send buffer.

import "support:system"
import "support:tcp"
import "support:web"

// The limits of a connection that makes no progress (milliseconds), so
// that one host cannot keep a record for ever. 10 s is long for a request
// on a link of the machine, where a round trip is under 1 ms, and short
// against 48 records.
IDLE_LIMIT :: 10_000 // No byte of a request on an open connection: a close.
HEAD_TIME_LIMIT :: 10_000 // A head that started and is not whole: 408.
PROGRESS_LIMIT :: 10_000 // A request in progress with no byte read and no byte acknowledged (a zero window for ever): a RST.
BODY_GRACE :: 10_000 // After it, a body must come at BODY_RATE bytes in one second at least: else a RST.
BODY_RATE :: 4096
SINK_LIMIT :: 16 << 20 // The largest body of /sink: 413 over it.
ANSWER_HEAD_CAPACITY :: 6144 // The head of an answer, and a body that the server makes (a page of counts).

ACCESS_HISTORY :: 18 // The last requests, that the window shows.
REQUEST_LOG_LIMIT :: 100 // Request log records in one second, of the log limit of this program (1000).

// Where the body of an answer comes from.
Answer_Body :: enum u8 {
	None, // No body, or a body in the head buffer.
	Large, // The page /large: its bytes come from their offset.
	Page, // A page of the store: its bytes are in the page memory.
}

Session :: struct {
	input:              [web.REQUEST_HEAD_LIMIT]u8, // Bytes read and not used yet: a head, a body, the next request.
	input_length:       int,
	request:            web.Request,
	has_request:        bool, // A head was read; its answer is not all written.
	reading_body:       bool,
	body_left:          i64,
	body_bytes:         i64,
	body_hash:          u64,
	body_at:            u64, // Milliseconds: the head of a body.
	answer_head:        [ANSWER_HEAD_CAPACITY]u8,
	answer_head_length: int,
	answer_head_done:   int,
	answer_body:        Answer_Body,
	answer_page:        int,
	answer_left:        int, // Bytes of a body of Large or Page still to write.
	answer_offset:      int,
	answer_status:      int,
	answer_bytes:       u64, // The body bytes of the answer.
	written:            u64, // Bytes that this server wrote in the connection.
	close_after:        bool, // The connection ends after this answer.
	closing:            bool,
	logged:             bool, // The end of the connection is on the log and in the history.
	requests:           int,
	request_started_at: u64, // Nanoseconds: the first byte of the head.
	first_request_at:   u64, // Nanoseconds: the first request of the connection.
	last_answer_at:     u64, // Nanoseconds: the last answer of the connection was written.
	progress_at:        u64, // Milliseconds: the last byte read, or acknowledged.
	acknowledged:       u64, // bytes_sent of the connection at progress_at.
	head_at:            u64, // Milliseconds: the first byte of the head that is read now.
}

sessions: [CAPACITY]Session

// One request, as the access table of the window and the log show it.
Access_Record :: struct {
	remote_address: u32,
	remote_port:    u16,
	method:         web.Request_Method,
	status:         int,
	target:         [48]u8,
	target_length:  int,
	bytes:          u64, // Bytes of the body of the answer.
	time:           u64, // Microseconds: from the first byte of the head to the last byte of the answer in the send buffer.
}

access_records: [ACCESS_HISTORY]Access_Record
access_next: int
requests_answered: u64
status_classes: [6]u64 // Answers by class: index 2 is 2xx, 4 is 4xx, 5 is 5xx.
request_log_second: u64
request_log_count: u64
requests_not_logged: u64

// The measures of requests in one second.
second_start: u64 // Milliseconds.
second_requests: u64 // Requests answered in the second that runs.
second_connections: u64 // Connections accepted in the second that runs.
best_second_requests: u64 // The most requests answered in one second.
best_new_connection_rate: u64 // The most requests in one second when each one had a new connection.
best_keep_alive_rate: u64 // The best rate of one connection with 100 requests or more, in requests in one second.

// answer_start writes the head of an answer, and a small body after it.
answer_start :: proc "contextless" (index: int, status: int, content_type: string, body: string, body_source := Answer_Body.None, body_length := 0, allow := "") {
	session := &sessions[index]
	request := &session.request
	length := body_source == .None ? len(body) : body_length
	if status >= 400 && request.content_length > 0 && !session.reading_body {
		// A body that the server does not read: the bytes after the head are
		// not a next request, so the connection ends after the answer.
		session.close_after = true
	}
	if request.close || request.problem != .None || status == 408 {
		session.close_after = true
	}
	head := system.Writer{buffer = session.answer_head[:]}
	text :: proc "contextless" (writer: ^system.Writer, part: string) {
		system.write_bytes(writer, transmute([]u8)part)
	}
	text(&head, "HTTP/1.1 ")
	system.write_unsigned(&head, u64(status))
	text(&head, " ")
	text(&head, web.status_text(status))
	text(&head, "\r\nContent-Length: ")
	system.write_unsigned(&head, u64(length))
	text(&head, "\r\nContent-Type: ")
	text(&head, content_type)
	text(&head, "\r\n")
	if allow != "" {
		text(&head, "Allow: ")
		text(&head, allow)
		text(&head, "\r\n")
	}
	if session.close_after {
		text(&head, "Connection: close\r\n")
	}
	// No Date field: this system has no clock of the day, and RFC 9110
	// 6.6.1 says that a server with no clock does not send one.
	text(&head, "\r\n")
	head_length := head.count
	is_head := request.method == .Head
	if body_source == .None && !is_head {
		system.write_bytes(&head, transmute([]u8)body)
	}
	session.answer_head_length = head.count
	if head.count - head_length < (is_head || body_source != .None ? 0 : len(body)) {
		// The body did not fit: never with the pages that this server makes.
		session.answer_head_length = head_length
	}
	session.answer_head_done = 0
	session.answer_body = is_head ? .None : body_source
	session.answer_left = is_head || body_source == .None ? 0 : body_length
	session.answer_offset = 0
	session.answer_status = status
	session.answer_bytes = is_head ? 0 : u64(length)
	session.has_request = true
}

// answer_write writes what the send buffer takes. It gives true when the
// answer is all written.
answer_write :: proc "contextless" (index: int) -> bool {
	session := &sessions[index]
	if session.answer_head_done < session.answer_head_length {
		count, _ := tcp.write(&table, index, session.answer_head[session.answer_head_done:session.answer_head_length])
		session.answer_head_done += count
		session.written += u64(count)
		if session.answer_head_done < session.answer_head_length {
			return false
		}
	}
	chunk: [4096]u8
	for session.answer_left > 0 {
		room := tcp.send_room(&table, index)
		if room == 0 {
			return false
		}
		part := min(session.answer_left, len(chunk), room)
		bytes: []u8
		switch session.answer_body {
		case .Large:
			web.pattern_fill(chunk[:part], session.answer_offset)
			bytes = chunk[:part]
		case .Page:
			bytes = page_bytes(session.answer_page)[session.answer_offset:][:part]
		case .None:
			session.answer_left = 0
			return true
		}
		count, _ := tcp.write(&table, index, bytes)
		session.answer_left -= count
		session.answer_offset += count
		session.written += u64(count)
	}
	return true
}

// request_route answers a request head that has no problem.
request_route :: proc "contextless" (index: int) {
	session := &sessions[index]
	request := &session.request
	target := web.request_target(request)
	path := target
	for character, place in target {
		if character == '?' {
			path = target[:place]
			break
		}
	}
	reading := request.method == .Get || request.method == .Head
	switch {
	case path == "/sink":
		if request.method != .Post {
			answer_start(index, 405, "text/plain; charset=utf-8", "/sink takes POST only\n", allow = "POST")
			return
		}
		if request.content_length > SINK_LIMIT {
			answer_start(index, 413, "text/plain; charset=utf-8", "the body is over the limit of this server, 16 MiB\n")
			return
		}
		// RFC 9112 6.3: a request with no Content-Length and no
		// Transfer-Encoding has no body.
		session.reading_body = true
		session.body_left = max(request.content_length, 0)
		session.body_bytes = 0
		session.body_hash = web.FNV_START
		session.body_at = system.time()
		session.has_request = true
		return
	case !reading:
		// PUT and DELETE stay off: the network is not authenticated. A
		// person changes the pages with server.put and server.remove.
		answer_start(index, 405, "text/plain; charset=utf-8", "this server takes GET and HEAD here; a page changes with server.put from the console\n", allow = "GET, HEAD")
	case path == "/":
		page: [4096]u8
		answer_start(index, 200, "text/html; charset=utf-8", counts_html(page[:]))
	case path == "/counts.json":
		page: [2048]u8
		answer_start(index, 200, "application/json", counts_json(page[:]))
	case path == "/large":
		answer_start(index, 200, "application/octet-stream", "", .Large, web.LARGE_SIZE)
	case:
		found := page_find(path[1:])
		if found < 0 {
			answer_start(index, 404, "text/plain; charset=utf-8", "no such page\n")
			return
		}
		pages[found].served += 1
		answer_start(index, 200, web.content_type_of_name(page_name(found)), "", .Page, pages[found].length)
		session.answer_page = found
	}
}

// request_finish ends a request whose answer is all in the send buffer.
request_finish :: proc "contextless" (index: int) {
	session := &sessions[index]
	connection := &connections[index]
	now := system.nanoseconds()
	took := (now - session.request_started_at) / 1000
	session.requests += 1
	if session.first_request_at == 0 {
		session.first_request_at = session.request_started_at
	}
	session.last_answer_at = now
	requests_answered += 1
	second_requests += 1
	status_classes[min(session.answer_status / 100, 5)] += 1
	request := &session.request
	record := Access_Record {
		remote_address = connection.remote_address,
		remote_port    = connection.remote_port,
		method         = request.method,
		status         = session.answer_status,
		bytes          = session.answer_bytes,
		time           = took,
	}
	record.target_length = copy(record.target[:], web.request_target(request))
	access_records[access_next] = record
	access_next = (access_next + 1) % ACCESS_HISTORY
	// The log of the requests, within the log limit of this program.
	second := system.time() / 1000
	if second != request_log_second {
		request_log_second, request_log_count = second, 0
	}
	if request_log_count < REQUEST_LOG_LIMIT {
		request_log_count += 1
		who: [32]u8
		method := web.request_method_name(request.method)
		system.log_in("requests", .Info, "server: ", method == "" ? "-" : method, " ", string(record.target[:min(record.target_length, 40)]), " ", u64(session.answer_status), ", ", session.answer_bytes, " bytes, ", took, " us, ", address_text(who[:], connection.remote_address, connection.remote_port))
	} else {
		requests_not_logged += 1
	}
	if session.answer_status == 200 && request.method == .Post {
		system.log("server: received /sink: ", u64(session.body_bytes), " bytes, fnv1a64 ", system.Hex(session.body_hash), ", ", rate(u64(session.body_bytes), now - session.request_started_at) / 1000, " MB/s")
	}
	close_after := session.close_after
	// The next request starts clean; the bytes after this head stay.
	session.has_request = false
	session.reading_body = false
	session.request = {}
	session.answer_head_length = 0
	session.answer_head_done = 0
	session.answer_left = 0
	session.progress_at = system.time()
	// The bytes that stay in the input are the start of the next head (an
	// independent read, B1): its time starts now, so that the limit of a
	// head applies to it. Else the next head starts with its first byte.
	if session.input_length > 0 {
		session.head_at = system.time()
		session.request_started_at = system.nanoseconds()
	} else {
		session.head_at = 0
	}
	if close_after {
		session.closing = true
		tcp.close(&table, index)
	}
}

// http_connection_work reads the bytes of a connection, its requests and
// their bodies, and writes the answers, as far as the buffers let it.
http_connection_work :: proc "contextless" (index: int) {
	session := &sessions[index]
	for !session.closing {
		// An answer in progress: write more of it.
		if session.has_request && !session.reading_body {
			if !answer_write(index) {
				return
			}
			request_finish(index)
			continue
		}
		// More bytes: into the input, as far as it has room.
		if session.input_length < len(session.input) {
			count, _ := tcp.read(&table, index, session.input[session.input_length:])
			if count > 0 {
				session.progress_at = system.time()
				if session.input_length == 0 && !session.reading_body {
					session.request_started_at = system.nanoseconds()
					session.head_at = system.time()
				}
				session.input_length += count
			}
		}
		if session.reading_body {
			// The body of /sink: from the input, then from the connection.
			taken := int(min(i64(session.input_length), session.body_left))
			session.body_hash = web.fnv(session.body_hash, session.input[:taken])
			session.body_bytes += i64(taken)
			session.body_left -= i64(taken)
			copy(session.input[:], session.input[taken:session.input_length])
			session.input_length -= taken
			if session.body_left > 0 {
				if taken == 0 {
					return
				}
				continue
			}
			session.reading_body = false
			body: [96]u8
			answer_start(index, 200, "text/plain; charset=utf-8", system.format(body[:], "received ", u64(session.body_bytes), " bytes, fnv1a64 ", system.Hex(session.body_hash), "\n"))
			continue
		}
		if session.input_length == 0 {
			return
		}
		request, complete := web.request_read(session.input[:session.input_length])
		if !complete {
			if session.input_length < len(session.input) {
				return // More bytes are needed.
			}
		}
		session.request = request
		if request.problem != .None {
			answer_start(index, web.request_problem_status(request.problem), "text/plain; charset=utf-8", web.request_problem_text(request.problem))
			session.input_length = 0 // The bytes after a wrong head mean nothing: the connection ends.
			continue
		}
		// The head is used; the bytes after it are the body or the next request.
		copy(session.input[:], session.input[request.head_size:session.input_length])
		session.input_length -= request.head_size
		request_route(index)
	}
}

// http_remote_closed takes the FIN of the remote: no byte comes after it,
// so a request that is not whole never will be. The connection closes now,
// or after the answer in progress.
http_remote_closed :: proc "contextless" (index: int) {
	session := &sessions[index]
	if session.closing {
		return
	}
	if session.has_request && !session.reading_body {
		session.close_after = true
		return
	}
	// The whole requests that wait in the input are answered first.
	http_connection_work(index)
	if session.has_request && !session.reading_body {
		session.close_after = true
		return
	}
	if !session.closing {
		session.closing = true
		tcp.close(&table, index)
	}
}

// http_limits ends what makes no progress on an open connection.
http_limits :: proc "contextless" (index: int, now: u64) {
	session := &sessions[index]
	connection := &connections[index]
	if connection.bytes_sent != session.acknowledged {
		session.acknowledged = connection.bytes_sent
		session.progress_at = now
	}
	if session.closing {
		return
	}
	switch {
	case session.reading_body:
		elapsed := now - session.body_at
		if elapsed > BODY_GRACE && u64(session.body_bytes) * 1000 < (elapsed - BODY_GRACE) * BODY_RATE {
			aborted(index, "aborted: a body under 4096 bytes in one second")
		}
	case session.has_request:
		if now - session.progress_at >= PROGRESS_LIMIT {
			aborted(index, "aborted: no byte acknowledged in 10 s")
		}
	case session.input_length == 0:
		if now - session.progress_at >= IDLE_LIMIT {
			who: [32]u8
			system.log("server: ", address_text(who[:], connection.remote_address, connection.remote_port), ": no request in 10 s, closed")
			session.closing = true
			tcp.close(&table, index)
		}
	case:
		if session.head_at != 0 && now - session.head_at >= HEAD_TIME_LIMIT {
			session.request = {}
			session.input_length = 0
			answer_start(index, 408, "text/plain; charset=utf-8", "the head of the request did not come in 10 s\n")
		}
	}
}

// keep_alive_measure writes the rate of a connection that served 100
// requests or more: the requests of one connection in one second.
keep_alive_measure :: proc "contextless" (index: int) {
	session := &sessions[index]
	if session.requests < 100 || session.last_answer_at <= session.first_request_at {
		return
	}
	took := session.last_answer_at - session.first_request_at
	per_second := u64(session.requests) * 1_000_000_000 / took
	best_keep_alive_rate = max(best_keep_alive_rate, per_second)
	who: [32]u8
	connection := &connections[index]
	system.log("server: ", u64(session.requests), " requests on one connection of ", address_text(who[:], connection.remote_address, connection.remote_port), " in ", took / 1_000_000, " ms: ", per_second, " requests in one second")
}

// second_measure ends a second of measure: the requests answered in it, and
// the connections accepted in it.
second_measure :: proc "contextless" (now: u64) {
	if now - second_start < 1000 {
		return
	}
	if second_requests >= 50 {
		best_second_requests = max(best_second_requests, second_requests)
		new_connections := accepted - second_connections
		if new_connections >= second_requests * 9 / 10 {
			best_new_connection_rate = max(best_new_connection_rate, second_requests)
		}
		system.log("server: ", second_requests, " requests answered in one second, on ", new_connections, " new connections")
	}
	second_start = now
	second_requests = 0
	second_connections = accepted
}
