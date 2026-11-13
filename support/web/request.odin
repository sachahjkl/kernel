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
LEADING_EMPTY_LINES_LIMIT :: 2 // Empty lines before the request line that are ignored (RFC 9112 2.2).

// The methods of RFC 9110, section 9, that the reader knows. Another method
// is the problem Unknown_Method (501).
Request_Method :: enum u8 {
	None    = 0, // No method: the request line was not read.
	Get     = 1, // GET.
	Head    = 2, // HEAD.
	Post    = 3, // POST.
	Put     = 4, // PUT.
	Delete  = 5, // DELETE.
	Options = 6, // OPTIONS.
	Patch   = 7, // PATCH (RFC 5789).
	Connect = 8, // CONNECT.
	Trace   = 9, // TRACE.
}

// The name of each method, as the request line writes it.
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
	None                  = 0, // The head is valid.
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

// The status code that answers each problem.
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

// The words of each problem, for the log of the server.
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

// A request head, as `request_read` gives it.
Request :: struct {
	head_size:      int, // The bytes of the head, with its empty line.
	method:         Request_Method, // The method.
	target:         [REQUEST_TARGET_LIMIT]u8, // The target, copied.
	target_length:  int, // The bytes of the target.
	minor_version:  u8, // 1: HTTP/1.1, 0: HTTP/1.0.
	has_host:       bool, // The head has a Host field.
	content_length: i64, // -1: no Content-Length.
	close:          bool, // The connection ends after the answer: "Connection: close", or HTTP/1.0 with no "keep-alive".
	field_count:    int, // The header fields.
	problem:        Request_Problem, // What is wrong. None: the head is valid.
	problem_offset: int, // The byte of the head where the problem is.
}

// request_target gives the target of a request.
request_target :: proc "contextless" (request: ^Request) -> string {
	return string(request.target[:request.target_length])
}

// request_problem_status gives the status that answers a problem: 400 for
// a number out of the enumeration.
request_problem_status :: proc "contextless" (problem: Request_Problem) -> int {
	return request_problem_statuses[problem] if problem <= max(Request_Problem) else 400
}

// request_problem_text gives the words of a problem.
request_problem_text :: proc "contextless" (problem: Request_Problem) -> string {
	return request_problem_texts[problem] if problem <= max(Request_Problem) else "an unknown problem"
}

// request_method_name gives the name of a method, or an empty text.
request_method_name :: proc "contextless" (method: Request_Method) -> string {
	return request_method_names[method] if method <= max(Request_Method) else ""
}

// path_of_absolute_target gives the path and the query of a target of the
// absolute form "http://authority/path?query": the bytes after the
// authority. absolute is false for each other form, and for an empty
// authority.
@(private)
path_of_absolute_target :: proc "contextless" (target: []u8) -> (path: []u8, absolute: bool) {
	rest: []u8
	switch {
	case len(target) > 7 && same_text_without_case(target[:7], "http://"):
		rest = target[7:]
	case len(target) > 8 && same_text_without_case(target[:8], "https://"):
		rest = target[8:]
	case:
		return nil, false
	}
	authority_end := 0
	for authority_end < len(rest) && rest[authority_end] != '/' && rest[authority_end] != '?' {
		authority_end += 1
	}
	if authority_end == 0 {
		return nil, false
	}
	return rest[authority_end:], true
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

// same_text_without_case compares bytes and a text in any case of ASCII.
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

// trim_spaces gives the bytes with the spaces and tabs around them taken
// away.
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
	// Empty lines before the request line: RFC 9112 2.2 says that a server
	// SHOULD ignore at least one. Two are ignored; a third is a bad line.
	leading := 0
	for leading < 2 * LEADING_EMPTY_LINES_LIMIT && len(bytes) >= leading + 2 && bytes[leading] == '\r' && bytes[leading + 1] == '\n' {
		leading += 2
	}
	scanned := bytes[leading:min(len(bytes), REQUEST_HEAD_LIMIT)]
	end_of_head := head_end(scanned)
	if end_of_head == 0 {
		if len(bytes) >= REQUEST_HEAD_LIMIT {
			request.problem = .Head_Too_Large
			request.problem_offset = REQUEST_HEAD_LIMIT
			return request, true
		}
		return request, false
	}
	request.head_size = leading + end_of_head
	head := bytes[leading:request.head_size - 2] // Each line with its CRLF; the empty line removed.
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
	if version[5] != '1' {
		return fail(&request, .Version_Not_Supported, target_end + 1)
	}
	// A higher minor version is read as HTTP/1.1, the highest that this
	// server speaks (RFC 9110 2.5).
	request.minor_version = min(version[7] - '0', 1)
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
	target := line[target_start:target_end]
	if target[0] != '/' {
		// The absolute form (RFC 9112 3.2.2: a server MUST accept it): the
		// scheme http or https and the authority go; the path stays, "/"
		// when it is empty. Host stays required, and is not used.
		path, absolute := path_of_absolute_target(target)
		if !absolute {
			return fail(&request, .Target_Not_Origin, target_start)
		}
		if len(path) == 0 || path[0] == '?' {
			request.target[0] = '/'
			request.target_length = 1 + copy(request.target[1:], path)
		} else {
			request.target_length = copy(request.target[:], path)
		}
	} else {
		request.target_length = copy(request.target[:], target)
	}
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

// content_type_of_name gives the media type of a page by the end of its
// name (".html", ".png"), or the type of a file of bytes.
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

// The pages that a server serves by name, from its private store: the
// rules of their names, and the index object that lists them. The store is
// hostile input too: an index that the server reads back can have each byte.
PAGE_NAME_LIMIT :: 39 // The names of the storage service have 39 bytes at most.
PAGE_INDEX_NAME :: "pages.index" // The object that lists the pages.
PAGE_INDEX_ENTRY_SIZE :: 40 // One name in the index, ended by a zero byte.

// page_name_valid: 1 to 39 bytes of letters, digits, ".", "-" and "_", not
// the name of the index. A name is the target of a request: no "/".
// bad_byte is the place of the first byte that breaks the rule, or -1.
page_name_valid :: proc "contextless" (name: string) -> (ok: bool, bad_byte: int) {
	if len(name) == 0 || len(name) > PAGE_NAME_LIMIT {
		return false, -1
	}
	for index in 0 ..< len(name) {
		switch name[index] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', '_':
		case:
			return false, index
		}
	}
	return name != PAGE_INDEX_NAME, -1
}

// page_index_entry gives the name in the entry `place` of an index object.
// An empty entry gives "" and ok. ok is false for an entry outside the
// index, an entry with no zero byte, a name that breaks page_name_valid,
// and a name that an entry before it has.
page_index_entry :: proc "contextless" (index: []u8, place: int) -> (name: string, ok: bool) {
	entry_name :: proc "contextless" (index: []u8, place: int) -> (name: string, ended: bool) {
		entry := index[place * PAGE_INDEX_ENTRY_SIZE:][:PAGE_INDEX_ENTRY_SIZE]
		for length in 0 ..< PAGE_INDEX_ENTRY_SIZE {
			if entry[length] == 0 {
				return string(entry[:length]), true
			}
		}
		return "", false
	}
	if place < 0 || (place + 1) * PAGE_INDEX_ENTRY_SIZE > len(index) {
		return "", false
	}
	ended: bool
	if name, ended = entry_name(index, place); !ended {
		return "", false
	}
	if len(name) == 0 {
		return "", true
	}
	if valid, _ := page_name_valid(name); !valid {
		return "", false
	}
	for earlier in 0 ..< place {
		if other, other_ended := entry_name(index, earlier); other_ended && other == name {
			return "", false
		}
	}
	return name, true
}

// html_text_escape writes text into destination with the five characters
// of HTML markup escaped, and gives the bytes written. An escape that does
// not fit is not written in part: the text stops before it.
html_text_escape :: proc "contextless" (destination: []u8, text: string) -> int {
	count := 0
	for index in 0 ..< len(text) {
		replacement: string
		switch text[index] {
		case '<':
			replacement = "&lt;"
		case '>':
			replacement = "&gt;"
		case '&':
			replacement = "&amp;"
		case '"':
			replacement = "&quot;"
		case '\'':
			replacement = "&#39;"
		case:
			if count == len(destination) {
				return count
			}
			destination[count] = text[index]
			count += 1
			continue
		}
		if count + len(replacement) > len(destination) {
			return count
		}
		count += copy(destination[count:], replacement)
	}
	return count
}
