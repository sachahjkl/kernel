#+build !freestanding
package web

import "core:math/rand"
import "core:strings"
import "core:testing"

read_text :: proc(text: string) -> (Request, bool) {
	return request_read(transmute([]u8)text)
}

@(test)
request_with_each_field :: proc(t: ^testing.T) {
	request, complete := read_text("GET /index.html HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: keep-alive, close\r\nContent-Length: 12\r\n\r\nthe body....GET")
	testing.expect(t, complete)
	testing.expect_value(t, request.problem, Request_Problem.None)
	testing.expect_value(t, request.method, Request_Method.Get)
	testing.expect_value(t, request_target(&request), "/index.html")
	testing.expect_value(t, request.minor_version, 1)
	testing.expect_value(t, request.content_length, 12)
	testing.expect(t, request.close)
	testing.expect_value(t, request.head_size, len("GET /index.html HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: keep-alive, close\r\nContent-Length: 12\r\n\r\n"))
	// HTTP/1.0: the connection ends after the answer, unless keep-alive.
	request, _ = read_text("HEAD / HTTP/1.0\r\n\r\n")
	testing.expect_value(t, request.problem, Request_Problem.None)
	testing.expect(t, request.close)
	request, _ = read_text("HEAD / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")
	testing.expect(t, !request.close)
	// Not whole yet.
	_, complete = read_text("GET / HTTP/1.1\r\nHost: x\r\n")
	testing.expect(t, !complete)
}

@(test)
request_problems :: proc(t: ^testing.T) {
	Case :: struct {
		text:    string,
		problem: Request_Problem,
		status:  int,
	}
	cases := []Case {
		{"GET / HTTP/1.1\r\n\r\n", .Missing_Host, 400},
		{"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", .Repeated_Host, 400},
		{"GET /  HTTP/1.1\r\nHost: a\r\n\r\n", .Bad_Request_Line, 400},
		{"GET / HTTP/1.1 \r\nHost: a\r\n\r\n", .Bad_Request_Line, 400},
		{" GET / HTTP/1.1\r\nHost: a\r\n\r\n", .Bad_Request_Line, 400},
		{"GET /\x01 HTTP/1.1\r\nHost: a\r\n\r\n", .Bad_Request_Line, 400},
		{"GET / HTTP/2.0\r\nHost: a\r\n\r\n", .Version_Not_Supported, 505},
		{"GET ftp://a/ HTTP/1.1\r\nHost: a\r\n\r\n", .Target_Not_Origin, 400},
		{"GET http:/a HTTP/1.1\r\nHost: a\r\n\r\n", .Target_Not_Origin, 400},
		{"\r\n\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\n\r\n", .Bad_Request_Line, 400},
		{"GET / HTTX/1.1\r\nHost: a\r\n\r\n", .Bad_Request_Line, 400},
		{"BREW / HTTP/1.1\r\nHost: a\r\n\r\n", .Unknown_Method, 501},
		{"GET / HTTP/1.1\r\nHost : a\r\n\r\n", .Bad_Field, 400},
		{"GET / HTTP/1.1\r\nHost: a\r\nNo colon\r\n\r\n", .Bad_Field, 400},
		{"GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n", .Bad_Field, 400},
		{"GET / HTTP/1.1\r\nHost: a\x00b\r\n\r\n", .Bad_Field, 400},
		{"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 12x\r\n\r\n", .Bad_Content_Length, 400},
		{"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n", .Bad_Content_Length, 400},
		{"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n", .Bad_Content_Length, 400},
		{"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 9999999999999999999999\r\n\r\n", .Content_Length_Too_Large, 413},
		{"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n", .Transfer_Coding, 501},
	}
	for item in cases {
		request, complete := read_text(item.text)
		testing.expectf(t, complete && request.problem == item.problem, "%q: %v", item.text, request.problem)
		testing.expectf(t, request_problem_status(request.problem) == item.status, "%q: %d", item.text, request_problem_status(request.problem))
	}
	// Two equal Content-Length fields are one value.
	request, _ := read_text("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n")
	testing.expect_value(t, request.problem, Request_Problem.None)
}

@(test)
request_bounds :: proc(t: ^testing.T) {
	// A target of 1024 bytes passes; 1025 is 414.
	target := strings.repeat("a", REQUEST_TARGET_LIMIT - 1, context.temp_allocator)
	request, _ := read_text(strings.concatenate({"GET /", target, " HTTP/1.1\r\nHost: a\r\n\r\n"}, context.temp_allocator))
	testing.expect_value(t, request.problem, Request_Problem.None)
	testing.expect_value(t, request.target_length, REQUEST_TARGET_LIMIT)
	request, _ = read_text(strings.concatenate({"GET /a", target, " HTTP/1.1\r\nHost: a\r\n\r\n"}, context.temp_allocator))
	testing.expect_value(t, request.problem, Request_Problem.Target_Too_Long)
	// 64 fields pass; 65 is 431.
	fields := strings.repeat("X-A: b\r\n", REQUEST_FIELD_LIMIT - 1, context.temp_allocator)
	request, _ = read_text(strings.concatenate({"GET / HTTP/1.1\r\nHost: a\r\n", fields, "\r\n"}, context.temp_allocator))
	testing.expect_value(t, request.problem, Request_Problem.None)
	request, _ = read_text(strings.concatenate({"GET / HTTP/1.1\r\nHost: a\r\n", fields, "X-B: c\r\n\r\n"}, context.temp_allocator))
	testing.expect_value(t, request.problem, Request_Problem.Too_Many_Fields)
	// A head of 8192 bytes with no end: 431, not a wait for more.
	long := strings.concatenate({"GET / HTTP/1.1\r\nX-Long: ", strings.repeat("z", REQUEST_HEAD_LIMIT, context.temp_allocator)}, context.temp_allocator)
	request_long, complete := read_text(long)
	testing.expect(t, complete)
	testing.expect_value(t, request_long.problem, Request_Problem.Head_Too_Large)
	_, complete = read_text(long[:REQUEST_HEAD_LIMIT - 1])
	testing.expect(t, !complete)
	// Content-Length of 15 digits is read; 16 digits is 413.
	request, _ = read_text("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 999999999999999\r\n\r\n")
	testing.expect_value(t, request.content_length, 999_999_999_999_999)
	request, _ = read_text("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1000000000000000\r\n\r\n")
	testing.expect_value(t, request.problem, Request_Problem.Content_Length_Too_Large)
}

// Random damage of a request: each byte can change and the head can end
// anywhere. request_read never reads outside the bytes (the test build
// checks each index), and a complete head is never longer than the bytes.
@(test)
request_with_random_damage :: proc(t: ^testing.T) {
	base := "POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\nbody"
	bytes: [256]u8
	for _ in 0 ..< 50_000 {
		count := copy(bytes[:], base)
		for _ in 0 ..< 1 + rand.int_max(6) {
			bytes[rand.int_max(count)] = u8(rand.int_max(256))
		}
		length := rand.int_max(count + 1)
		request, complete := request_read(bytes[:length])
		if complete && request.problem != .Head_Too_Large {
			testing.expect(t, request.head_size <= length)
		}
		testing.expect(t, request.target_length <= REQUEST_TARGET_LIMIT)
	}
}

@(test)
content_types_by_name :: proc(t: ^testing.T) {
	testing.expect_value(t, content_type_of_name("index.html"), "text/html; charset=utf-8")
	testing.expect_value(t, content_type_of_name("counts.json"), "application/json")
	testing.expect_value(t, content_type_of_name("a.tar"), "application/octet-stream")
	testing.expect_value(t, content_type_of_name("html"), "application/octet-stream")
}

// Three forms that a server must take: the absolute form of a target (RFC
// 9112 3.2.2: a server MUST accept it), a higher minor version (RFC 9110 2.5: it is read as HTTP/1.1), and empty
// lines before the request line (RFC 9112 2.2: a server SHOULD ignore at
// least one).
@(test)
request_forms_that_a_server_must_accept :: proc(t: ^testing.T) {
	Case :: struct {
		text:   string,
		target: string,
	}
	cases := []Case {
		{"GET http://10.0.2.15/index.html?a=b HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n", "/index.html?a=b"},
		{"GET HTTP://10.0.2.15 HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n", "/"},
		{"GET https://a:8080/b HTTP/1.1\r\nHost: a\r\n\r\n", "/b"},
		{"GET http://a?x HTTP/1.1\r\nHost: a\r\n\r\n", "/?x"},
	}
	for item in cases {
		request, complete := read_text(item.text)
		testing.expectf(t, complete && request.problem == .None, "%q: %v", item.text, request.problem)
		testing.expectf(t, request_target(&request) == item.target, "%q: the target %q", item.text, request_target(&request))
	}
	request, _ := read_text("GET / HTTP/1.2\r\nHost: a\r\n\r\n")
	testing.expect_value(t, request.problem, Request_Problem.None)
	testing.expect_value(t, request.minor_version, 1)
	text := "\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\n\r\nGET"
	complete: bool
	request, complete = read_text(text)
	testing.expect(t, complete)
	testing.expect_value(t, request.problem, Request_Problem.None)
	testing.expect_value(t, request.head_size, len(text) - 3)
	_, complete = read_text("\r\n")
	testing.expect(t, !complete)
}

// head_end_from finds the same end as head_end, from where the last scan
// stopped: a head that comes one byte at a time costs each byte once.
@(test)
head_end_from_where_the_scan_stopped :: proc(t: ^testing.T) {
	text := transmute([]u8)string("GET / HTTP/1.1\r\nHost: a\r\n\r\nbody")
	for length in 0 ..= len(text) {
		for start in 0 ..= length {
			testing.expectf(t, head_end_from(text[:length], start) == head_end(text[:length]) || head_end(text[:length]) - 4 < max(start - 3, 0), "length %d, start %d", length, start)
		}
	}
	testing.expect_value(t, head_end_from(text, len("GET / HTTP/1.1\r\nHost: a\r\n\r")), head_end(text))
}

// The pages of a store are hostile input too: a name that breaks the
// rules, an entry with no end, or a name that came before is refused; a
// name goes into HTML only escaped.
@(test)
page_index_entries :: proc(t: ^testing.T) {
	index: [6 * PAGE_INDEX_ENTRY_SIZE]u8
	put :: proc(index: []u8, place: int, name: string) {
		copy(index[place * PAGE_INDEX_ENTRY_SIZE:][:PAGE_INDEX_ENTRY_SIZE], name)
	}
	put(index[:], 0, "hello.html")
	put(index[:], 1, "<script>")
	put(index[:], 2, "pages.index")
	put(index[:], 3, "hello.html")
	for &byte in index[4 * PAGE_INDEX_ENTRY_SIZE:][:PAGE_INDEX_ENTRY_SIZE] {
		byte = 'a'
	}
	name, ok := page_index_entry(index[:], 0)
	testing.expect(t, ok && name == "hello.html")
	for place in 1 ..= 4 {
		_, ok = page_index_entry(index[:], place)
		testing.expectf(t, !ok, "the entry %d", place)
	}
	name, ok = page_index_entry(index[:], 5)
	testing.expect(t, ok && name == "")
	_, ok = page_index_entry(index[:], 6)
	testing.expect(t, !ok)
	valid, bad := page_name_valid("a-b_c.d9")
	testing.expect(t, valid && bad == -1)
	valid, bad = page_name_valid("a/b")
	testing.expect(t, !valid && bad == 1)
	escaped: [64]u8
	count := html_text_escape(escaped[:], "<a href=\"x\">&'")
	testing.expect_value(t, string(escaped[:count]), "&lt;a href=&quot;x&quot;&gt;&amp;&#39;")
	// An escape that does not fit is not cut in its middle.
	count = html_text_escape(escaped[:5], "a<b")
	testing.expect_value(t, string(escaped[:count]), "a&lt;")
	count = html_text_escape(escaped[:4], "a<b")
	testing.expect_value(t, string(escaped[:count]), "a")
}
