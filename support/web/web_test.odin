#+build !freestanding
package web

import "core:hash"
import "core:testing"

@(test)
request_and_response :: proc(t: ^testing.T) {
	request := "POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\nbody"
	head, ok := head_read(transmute([]u8)request)
	testing.expect(t, ok)
	testing.expect_value(t, head.method, Method.Post)
	testing.expect_value(t, path(&head), "/sink")
	testing.expect_value(t, head.content_length, 1 << 20)
	testing.expect(t, head.close)
	testing.expect_value(t, head.size, len(request) - 4)

	response := "HTTP/1.1 200 OK\r\ncontent-length: 12\r\n\r\n"
	head, ok = head_read(transmute([]u8)response)
	testing.expect(t, ok)
	testing.expect_value(t, head.status, 200)
	testing.expect_value(t, head.content_length, 12)
	testing.expect(t, !head.close)

	// Not complete, not HTTP/1.1, a method that the package does not know.
	_, ok = head_read(transmute([]u8)string("GET / HTTP/1.1\r\n"))
	testing.expect(t, !ok)
	_, ok = head_read(transmute([]u8)string("GET / HTTP/2\r\n\r\n"))
	testing.expect(t, !ok)
	_, ok = head_read(transmute([]u8)string("DELETE / HTTP/1.1\r\n\r\n"))
	testing.expect(t, !ok)
	_, ok = head_read(transmute([]u8)string("GET / HTTP/1.1\r\nContent-Length: 12x\r\n\r\n"))
	testing.expect(t, !ok)
}

// The hash of this package is FNV-1a of 64 bits: the one of core:hash.
@(test)
hash_of_the_large_page :: proc(t: ^testing.T) {
	page := make([]u8, LARGE_SIZE)
	defer delete(page)
	pattern_fill(page, 0)
	testing.expect_value(t, fnv(FNV_START, page), hash.fnv64a(page))
	testing.expect_value(t, pattern_hash(LARGE_SIZE), hash.fnv64a(page))
	testing.expect_value(t, pattern_hash(1000), hash.fnv64a(page[:1000]))
}
