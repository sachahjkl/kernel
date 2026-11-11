package web

// The head of an HTTP/1.1 request (RFC 9112 section 2 to 6, RFC 9110), read
// as hostile input: each length is checked before a byte is read, each part
// has a bound, and a head that breaks a rule gives a problem with the status
// that the server answers. Nothing is allocated: the request is a record of
// fixed size, and the target is copied into it.

REQUEST_HEAD_LIMIT :: 8192 // The bytes of a request head, with its empty line: 431 over it.
REQUEST_FIELD_LIMIT :: 64 // Header fields of one request: 431 over it.
REQUEST_TARGET_LIMIT :: 1024 // The bytes of the target: 414 over it.
CONTENT_LENGTH_DIGITS_LIMIT :: 15 // A Content-Length of 15 digits at most: a larger one is 413 for each server of this system.

Request_Method :: enum u8 {
	None    = 0,
	Get     = 1,
	Head    = 2,
	Post    = 3,
	Put     = 4,
	Delete  = 5,
	Options = 6,
	Patch   = 7,
	Connect = 8,
	Trace   = 9,
}

@(rodata)
request_method_names := [Request_Method]string {
	.None    = "",
	.Get     = "GET",
	.Head    = "HEAD",
	.Post    = "POST",
	.Put     = "PUT",
	.Delete  = "DELETE",
	.Options = "OPTIONS",
	.Patch   = "PATCH",
	.Connect = "CONNECT",
	.Trace   = "TRACE",
}

// What is wrong with a request head, and the status that answers it.
Request_Problem :: enum u8 {
	None                  = 0,
	Bad_Request_Line      = 1, // 400
	Bad_Field             = 2, // 400: a field with no colon, a space before the colon, a name that is not a token, a folded line.
	Missing_Host          = 3, // 400: HTTP/1.1 with no Host.
	Repeated_Host         = 4, // 400
	Bad_Content_Length    = 5, // 400: not digits, or two different values.
	Target_Not_Origin     = 6, // 400: the target does not start with "/".
	Head_Too_Large        = 7, // 431
	Too_Many_Fields       = 8, // 431
	Target_Too_Long       = 9, // 414
	Content_Length_Too_Large = 10, // 413
	Unknown_Method        = 11, // 501
	Transfer_Coding       = 12, // 501: this server decodes no transfer coding (chunked).
	Version_Not_Supported = 13, // 505
}

@(rodata)
request_problem_statuses := [Request_Problem]int {
	.None                     = 200,
	.Bad_Request_Line         = 400,
	.Bad_Field                = 400,
	.Missing_Host             = 400,
	.Repeated_Host            = 400,
	.Bad_Content_Length       = 400,
	.Target_Not_Origin        = 400,
	.Head_Too_Large           = 431,
	.Too_Many_Fields          = 431,
	.Target_Too_Long          = 414,
	.Content_Length_Too_Large = 413,
	.Unknown_Method           = 501,
	.Transfer_Coding          = 501,
	.Version_Not_Supported    = 505,
}

@(rodata)
request_problem_texts := [Request_Problem]string {
	.None                     = "",
	.Bad_Request_Line         = "the request line is not METHOD SP TARGET SP HTTP/1.x",
	.Bad_Field                = "a header field breaks the rules of RFC 9112 section 5",
	.Missing_Host             = "an HTTP/1.1 request needs a Host field",
	.Repeated_Host            = "the request has two Host fields",
	.Bad_Content_Length       = "Content-Length is not one number of digits",
	.Target_Not_Origin        = "the target must start with /",
	.Head_Too_Large           = "the head of the request is over 8192 bytes",
	.Too_Many_Fields          = "the request has over 64 header fields",
	.Target_Too_Long          = "the target is over 1024 bytes",
	.Content_Length_Too_Large = "Content-Length is over the limit",
	.Unknown_Method           = "this server does not know the method",
	.Transfer_Coding          = "this server decodes no transfer coding",
	.Version_Not_Supported    = "this server speaks HTTP/1.1 and HTTP/1.0",
}

Request :: struct {
	head_size:      int, // The bytes of the head, with its empty line.
	method:         Request_Method,
	target:         [REQUEST_TARGET_LIMIT]u8,
	target_length:  int,
	minor_version:  u8, // 1: HTTP/1.1, 0: HTTP/1.0.
	has_host:       bool,
	content_length: i64, // -1: no Content-Length.
	close:          bool, // The connection ends after the answer: "Connection: close", or HTTP/1.0 with no "keep-alive".
	field_count:    int,
	problem:        Request_Problem,
	problem_offset: int, // The byte of the head where the problem is.
}

request_target :: proc "contextless" (request: ^Request) -> string {
	return string(request.target[:request.target_length])
}

request_problem_status :: proc "contextless" (problem: Request_Problem) -> int {
	return request_problem_statuses[problem] if problem <= max(Request_Problem) else 400
}

request_problem_text :: proc "contextless" (problem: Request_Problem) -> string {
	return request_problem_texts[problem] if problem <= max(Request_Problem) else "an unknown problem"
}

request_method_name :: proc "contextless" (method: Request_Method) -> string {
	return request_method_names[method] if method <= max(Request_Method) else ""
}

// A token character of RFC 9110 section 5.6.2.
@(private)
token_character :: proc "contextless" (byte: u8) -> bool {
	switch byte {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return true
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

@(private)
same_text_without_case :: proc "contextless" (bytes: []u8, text: string) -> bool {
	if len(bytes) != len(text) {
		return false
	}
	for index in 0 ..< len(text) {
		if lower(bytes[index]) != lower(text[index]) {
			return false
		}
	}
	return true
}

@(private)
trim_spaces :: proc "contextless" (bytes: []u8) -> []u8 {
	first, end := 0, len(bytes)
	for first < end && (bytes[first] == ' ' || bytes[first] == '\t') {
		first += 1
	}
	for end > first && (bytes[end - 1] == ' ' || bytes[end - 1] == '\t') {
		end -= 1
	}
	return bytes[first:end]
}

// request_read reads the head of a request at the start of bytes. complete
// is false when the empty line that ends the head is not there yet and the
// bytes are under REQUEST_HEAD_LIMIT: more bytes are needed. Else the
// request has its problem, or None. The bytes after head_size belong to the
// body or to the next request.
request_read :: proc "contextless" (bytes: []u8) -> (request: Request, complete: bool) {
	request.content_length = -1
	scanned := bytes[:min(len(bytes), REQUEST_HEAD_LIMIT)]
	request.head_size = head_end(scanned)
	if request.head_size == 0 {
		if len(bytes) >= REQUEST_HEAD_LIMIT {
			request.problem = .Head_Too_Large
			request.problem_offset = REQUEST_HEAD_LIMIT
			return request, true
		}
		return request, false
	}
	head := bytes[:request.head_size - 2] // Each line with its CRLF; the empty line removed.
	position := 0
	line_end :: proc "contextless" (head: []u8, start: int) -> int {
		for index in start ..< len(head) - 1 {
			if head[index] == '\r' && head[index + 1] == '\n' {
				return index
			}
		}
		return len(head)
	}
	fail :: proc "contextless" (request: ^Request, problem: Request_Problem, offset: int) -> (Request, bool) {
		request.problem = problem
		request.problem_offset = offset
		return request^, true
	}
	// The request line: METHOD SP TARGET SP HTTP/1.x.
	end := line_end(head, 0)
	line := head[:end]
	method_end := 0
	for method_end < len(line) && token_character(line[method_end]) {
		method_end += 1
	}
	if method_end == 0 || method_end >= len(line) || line[method_end] != ' ' {
		return fail(&request, .Bad_Request_Line, method_end)
	}
	target_start := method_end + 1
	target_end := target_start
	for target_end < len(line) && line[target_end] != ' ' {
		if line[target_end] <= ' ' || line[target_end] == 0x7F {
			return fail(&request, .Bad_Request_Line, target_end)
		}
		target_end += 1
	}
	if target_end == target_start || target_end >= len(line) {
		return fail(&request, .Bad_Request_Line, target_end)
	}
	version := line[target_end + 1:]
	if len(version) != 8 || string(version[:5]) != "HTTP/" || version[6] != '.' || version[5] < '0' || version[5] > '9' || version[7] < '0' || version[7] > '9' {
		return fail(&request, .Bad_Request_Line, target_end + 1)
	}
	if version[5] != '1' || version[7] > '1' {
		return fail(&request, .Version_Not_Supported, target_end + 1)
	}
	request.minor_version = version[7] - '0'
	method_text := line[:method_end]
	for name, method in request_method_names {
		if method != .None && string(method_text) == name {
			request.method = method
		}
	}
	if request.method == .None {
		return fail(&request, .Unknown_Method, 0)
	}
	if target_end - target_start > REQUEST_TARGET_LIMIT {
		return fail(&request, .Target_Too_Long, target_start)
	}
	if line[target_start] != '/' {
		return fail(&request, .Target_Not_Origin, target_start)
	}
	request.target_length = copy(request.target[:], line[target_start:target_end])
	// The fields: name ":" OWS value OWS (RFC 9112 section 5).
	keep_alive := false
	position = end + 2
	for position < len(head) {
		end = line_end(head, position)
		field := head[position:end]
		offset := position
		position = end + 2
		if len(field) == 0 {
			continue
		}
		if field[0] == ' ' || field[0] == '\t' {
			return fail(&request, .Bad_Field, offset) // A folded line (obs-fold).
		}
		request.field_count += 1
		if request.field_count > REQUEST_FIELD_LIMIT {
			return fail(&request, .Too_Many_Fields, offset)
		}
		colon := 0
		for colon < len(field) && token_character(field[colon]) {
			colon += 1
		}
		if colon == 0 || colon >= len(field) || field[colon] != ':' {
			return fail(&request, .Bad_Field, offset + colon)
		}
		name := field[:colon]
		value := trim_spaces(field[colon + 1:])
		for byte in value {
			if (byte < ' ' && byte != '\t') || byte == 0x7F {
				return fail(&request, .Bad_Field, offset)
			}
		}
		switch {
		case same_text_without_case(name, "host"):
			if request.has_host {
				return fail(&request, .Repeated_Host, offset)
			}
			request.has_host = true
		case same_text_without_case(name, "content-length"):
			if len(value) == 0 {
				return fail(&request, .Bad_Content_Length, offset)
			}
			if len(value) > CONTENT_LENGTH_DIGITS_LIMIT {
				for byte in value {
					if byte < '0' || byte > '9' {
						return fail(&request, .Bad_Content_Length, offset)
					}
				}
				return fail(&request, .Content_Length_Too_Large, offset)
			}
			length: i64
			for byte in value {
				if byte < '0' || byte > '9' {
					return fail(&request, .Bad_Content_Length, offset)
				}
				length = length * 10 + i64(byte - '0')
			}
			if request.content_length >= 0 && request.content_length != length {
				return fail(&request, .Bad_Content_Length, offset)
			}
			request.content_length = length
		case same_text_without_case(name, "transfer-encoding"):
			return fail(&request, .Transfer_Coding, offset)
		case same_text_without_case(name, "connection"):
			// A list of tokens: close, keep-alive.
			start := 0
			for index in 0 ..= len(value) {
				if index == len(value) || value[index] == ',' {
					token := trim_spaces(value[start:index])
					if same_text_without_case(token, "close") {
						request.close = true
					}
					if same_text_without_case(token, "keep-alive") {
						keep_alive = true
					}
					start = index + 1
				}
			}
		}
	}
	if request.minor_version == 1 && !request.has_host {
		return fail(&request, .Missing_Host, 0)
	}
	if request.minor_version == 0 && !keep_alive {
		request.close = true
	}
	return request, true
}

// The content type of a name, by the end of the name.
@(rodata)
content_types := [?][2]string {
	{".html", "text/html; charset=utf-8"},
	{".htm", "text/html; charset=utf-8"},
	{".txt", "text/plain; charset=utf-8"},
	{".css", "text/css; charset=utf-8"},
	{".js", "text/javascript; charset=utf-8"},
	{".json", "application/json"},
	{".svg", "image/svg+xml"},
	{".png", "image/png"},
	{".ico", "image/x-icon"},
}

content_type_of_name :: proc "contextless" (name: string) -> string {
	for item in content_types {
		if len(name) >= len(item[0]) && name[len(name) - len(item[0]):] == item[0] {
			return item[1]
		}
	}
	return "application/octet-stream"
}

// The reason phrase of a status (RFC 9110 section 15).
status_text :: proc "contextless" (status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 400:
		return "Bad Request"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 408:
		return "Request Timeout"
	case 413:
		return "Content Too Large"
	case 414:
		return "URI Too Long"
	case 431:
		return "Request Header Fields Too Large"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 505:
		return "HTTP Version Not Supported"
	}
	return "Unknown"
}
