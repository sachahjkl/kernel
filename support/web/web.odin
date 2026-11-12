// The small HTTP/1.1 of the test of TCP: what the program `server`, the
// program `fetch` and the kernel tool read and write the same way. The
// head of a request or of a response, its Content-Length and the end of
// its connection; the large page, whose bytes come from their offset; the
// hash FNV-1a of 64 bits, that each side computes over a body.
//
// The functions read and write memory that the caller gives, and allocate
// nothing. A head that breaks a rule gives ok = false.
package web

LARGE_SIZE :: 1 << 20 // The bytes of the page /large and of a body to /sink.
HEAD_LIMIT :: 2048 // The bytes of the head of a request or a response, at most.
FNV_START :: 0xCBF2_9CE4_8422_2325

Method :: enum u8 {
	None = 0,
	Get  = 1,
	Post = 2,
}

Head :: struct {
	size:           int, // The bytes of the head, with the empty line at its end.
	method:         Method,
	path:           [64]u8,
	path_length:    int,
	status:         int, // A response: its status code.
	content_length: int, // -1: the head has no Content-Length.
	close:          bool, // "Connection: close".
}

// pattern gives the byte at an offset of the page /large.
pattern :: #force_inline proc "contextless" (offset: int) -> u8 {
	return u8(offset * 7 + offset >> 11)
}

pattern_fill :: proc "contextless" (buffer: []u8, offset: int) {
	for &byte, index in buffer {
		byte = pattern(offset + index)
	}
}

fnv :: proc "contextless" (hash: u64, bytes: []u8) -> u64 {
	hash := hash
	for byte in bytes {
		hash = (hash ~ u64(byte)) * 0x0000_0100_0000_01B3
	}
	return hash
}

// pattern_hash gives the hash of the first count bytes of the page /large.
pattern_hash :: proc "contextless" (count: int) -> u64 {
	hash := u64(FNV_START)
	chunk: [4096]u8
	for offset := 0; offset < count; offset += len(chunk) {
		part := min(len(chunk), count - offset)
		pattern_fill(chunk[:part], offset)
		hash = fnv(hash, chunk[:part])
	}
	return hash
}

// head_end gives the bytes of a head: up to the empty line, with it. 0:
// the empty line is not there yet.
head_end :: proc "contextless" (bytes: []u8) -> int {
	return head_end_from(bytes, 0)
}

// head_end_from is head_end for bytes whose first scanned_length bytes were
// scanned before with no end: the scan starts at the first place where an
// end can be. Else a head that comes one byte at a time costs each byte
// again on each read.
head_end_from :: proc "contextless" (bytes: []u8, scanned_length: int) -> int {
	for index in max(scanned_length, 3) ..< len(bytes) {
		if bytes[index - 3] == '\r' && bytes[index - 2] == '\n' && bytes[index - 1] == '\r' && bytes[index] == '\n' {
			return index + 1
		}
	}
	return 0
}

@(private)
lower :: proc "contextless" (byte: u8) -> u8 {
	return byte >= 'A' && byte <= 'Z' ? byte + 32 : byte
}

@(private)
same_name :: proc "contextless" (line: []u8, name: string) -> bool {
	if len(line) < len(name) {
		return false
	}
	for index in 0 ..< len(name) {
		if lower(line[index]) != name[index] {
			return false
		}
	}
	return true
}

@(private)
number :: proc "contextless" (bytes: []u8) -> (value: int, ok: bool) {
	digits := 0
	for byte in bytes {
		switch byte {
		case ' ', '\t':
			if digits > 0 {
				return value, true
			}
		case '0' ..= '9':
			if digits == 12 {
				return 0, false
			}
			value = value * 10 + int(byte - '0')
			digits += 1
		case:
			return 0, false
		}
	}
	return value, digits > 0
}

// head_read reads a head: the first line of a request ("GET /path
// HTTP/1.1") or of a response ("HTTP/1.1 200 OK"), then the fields that
// this package knows. bytes holds at least the whole head (head_end).
head_read :: proc "contextless" (bytes: []u8) -> (head: Head, ok: bool) {
	head.size = head_end(bytes)
	if head.size == 0 {
		return {}, false
	}
	head.content_length = -1
	text := bytes[:head.size]
	first := true
	for start := 0; start < len(text); {
		end := start
		for end + 1 < len(text) && !(text[end] == '\r' && text[end + 1] == '\n') {
			end += 1
		}
		line := text[start:end]
		start = end + 2
		if len(line) == 0 {
			break
		}
		if first {
			first = false
			first_line(&head, line) or_return
			continue
		}
		switch {
		case same_name(line, "content-length:"):
			head.content_length = number(line[len("content-length:"):]) or_return
		case same_name(line, "connection:"):
			rest := line[len("connection:"):]
			for len(rest) > 0 && rest[0] == ' ' {
				rest = rest[1:]
			}
			head.close = same_name(rest, "close")
		}
	}
	return head, !first
}

@(private)
first_line :: proc "contextless" (head: ^Head, line: []u8) -> bool {
	if same_name(line, "http/1.1 ") || same_name(line, "http/1.0 ") {
		status, ok := number(line[9:])
		head.status = status
		return ok
	}
	space := 0
	for space < len(line) && line[space] != ' ' {
		space += 1
	}
	switch string(line[:space]) {
	case "GET":
		head.method = .Get
	case "POST":
		head.method = .Post
	case:
		return false
	}
	path_end := space + 1
	for path_end < len(line) && line[path_end] != ' ' {
		path_end += 1
	}
	if path_end >= len(line) || path_end - space - 1 > len(head.path) || string(line[path_end:]) != " HTTP/1.1" {
		return false
	}
	head.path_length = copy(head.path[:], line[space + 1:path_end])
	return true
}

path :: proc "contextless" (head: ^Head) -> string {
	return string(head.path[:head.path_length])
}
