package server

// The pages that the server serves by name: objects of its private store in
// the storage service, as each program has one. The server reads them into
// its memory when it starts, and serves them from there: a request never
// waits for the storage service. The principal changes them from the console
// through the exports of the server, functions with typed parameters,
// which write the store first:
//
//   server.put("hello.html", "a text")    a page, new or changed
//   server.remove("hello.html")
//   server.pages()                        the table of the pages
//   server.served()                       the counts of the server
//
// The store holds each page under its name, and one object PAGE_INDEX_NAME
// with the names of the pages.

import "contract:errors"
import "contract:isolated"
import "support:storage"
import "support:system"
import "support:web"

PAGE_CAPACITY :: 16
PAGE_SIZE_LIMIT :: 60 * 1024 // Bytes of one page: the call region of a connection has 64 KiB.
PAGE_NAME_LIMIT :: web.PAGE_NAME_LIMIT
PAGE_INDEX_NAME :: web.PAGE_INDEX_NAME
PAGE_MEMORY_PAGES :: PAGE_CAPACITY * PAGE_SIZE_LIMIT / system.PAGE_SIZE

ERROR_ACTS_FOR_PRINCIPAL :: -1
ERROR_NAME :: -2
ERROR_TOO_LARGE :: -3
ERROR_FULL :: -4
ERROR_ABSENT :: -5
ERROR_STORE :: -6

Page_Entry :: struct {
	name:        [40]u8,
	name_length: int,
	length:      int, // The bytes of the page.
	used:        bool, // false: the place is free.
	served:      u64,
	generation:  u64, // Changes at each put and remove of the place: an answer of an older generation ends, so that it never sends the bytes of another page.
}

// One row of server.pages().
Page_Row :: struct {
	name:   [40]u8,
	bytes:  i64,
	served: i64, // The answers of this page since the start of the server.
	type:   [32]u8,
}

// What server.served() gives.
Served :: struct {
	requests:             i64, // Requests answered.
	answers_2xx:          i64,
	answers_4xx:          i64,
	answers_5xx:          i64,
	connections_accepted: i64,
	connections_open:     i64,
	bytes_in:             i64, // Bytes of data that arrived on connections that ended.
	bytes_out:            i64,
	pages:                i64,
	calls:                i64, // The calls of its exports.
}

pages: [PAGE_CAPACITY]Page_Entry
page_memory: []u8
// The bytes of a put, and of a page that the start reads: the store takes
// them from here, and the page memory changes only when the store took
// them: what is served is always what the store keeps. One byte over the
// limit shows a page that is
// too large.
page_staging: [PAGE_SIZE_LIMIT + 1]u8
page_generation_last: u64 // The generation that the last put or remove gave.

// page_generation_new gives a generation that no place had: never 0.
page_generation_new :: proc "contextless" () -> u64 {
	page_generation_last += 1
	return page_generation_last
}

page_bytes :: proc "contextless" (index: int) -> []u8 {
	return page_memory[index * PAGE_SIZE_LIMIT:][:pages[index].length]
}

page_name :: proc "contextless" (index: int) -> string {
	return string(pages[index].name[:pages[index].name_length])
}

page_find :: proc "contextless" (name: string) -> int {
	for &item, index in pages {
		if item.used && string(item.name[:item.name_length]) == name {
			return index
		}
	}
	return -1
}

// pages_load opens the private store and reads the pages into memory.
pages_load :: proc "contextless" (ctx: ^system.Context) {
	memory, memory_status := system.memory_create(PAGE_MEMORY_PAGES)
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		fail("no memory for the pages")
	}
	page_memory = ([^]u8)(address)[:PAGE_MEMORY_PAGES * system.PAGE_SIZE]
	store_client, store_connected = storage.open(ctx)
	if !store_connected {
		system.log("server: no private store: it serves no page of a store")
		return
	}
	index: [PAGE_CAPACITY * web.PAGE_INDEX_ENTRY_SIZE]u8
	bytes, found, status := storage.read(&store_client, storage.ROOT, PAGE_INDEX_NAME, index[:])
	if status != .Ok || !found || len(bytes) != size_of(index) {
		system.log("server: a new store: no page")
		return
	}
	// The store is hostile input too: each name
	// must follow the rules and come once, each page must fit.
	loaded, refused := 0, 0
	for place in 0 ..< PAGE_CAPACITY {
		name, name_ok := web.page_index_entry(index[:], place)
		if !name_ok {
			refused += 1
			continue
		}
		if len(name) == 0 {
			continue
		}
		text, page_found, page_status := storage.read(&store_client, storage.ROOT, name, page_staging[:])
		if page_status != .Ok || !page_found {
			continue
		}
		if len(text) > PAGE_SIZE_LIMIT {
			refused += 1
			continue
		}
		copy(page_memory[place * PAGE_SIZE_LIMIT:][:PAGE_SIZE_LIMIT], text)
		pages[place] = {name_length = copy(pages[place].name[:], name), length = len(text), used = true, generation = page_generation_new()}
		loaded += 1
	}
	system.log("server: ", u64(loaded), " pages read from the private store, ", u64(refused), " refused")
}

// index_write writes the names of the pages in the store.
@(private = "file")
index_write :: proc "contextless" () -> bool {
	index: [PAGE_CAPACITY * web.PAGE_INDEX_ENTRY_SIZE]u8
	for &item, place in pages {
		if item.used {
			copy(index[place * web.PAGE_INDEX_ENTRY_SIZE:][:web.PAGE_INDEX_ENTRY_SIZE - 1], page_name(place))
		}
	}
	_, status := storage.write(&store_client, storage.ROOT, PAGE_INDEX_NAME, ([^]u8)(&index)[:size_of(index)])
	return status == .Ok
}

// acts_for_principal says if the caller of the export that runs acts for the principal:
// only such a caller changes the pages that the network sees.
@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// put writes a page in the private store of the server, and serves it at /name from now on.
//
// It is the one way to change what the network sees: HTTP itself refuses PUT and DELETE (405), because the
// network is not authenticated. The order is the store first, then the memory of the server: the page that is
// served is always the page that the store keeps, and a refused write leaves the old page in place. A page that
// changes keeps its count of answers.
//
// - **name**: 1 to 39 bytes of letters, digits, ".", "-" and "_". Its end gives the content type: .html, .txt,
//   .css, .js, .json or .svg.
// - **text**: the bytes of the page, 60 KiB at most (the call region of a connection has 64 KiB).
//
// The caller must act for the principal (**Acts_For_Principal**). The result is the bytes of the page, or a
// negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Empty`, `Too_Long` or `Bad_Byte` (-2): the name; for `Bad_Byte`, the record holds the place of the byte.
// - `Too_Long` (-3): the text has more than 60 KiB.
// - `Full` (-4): 16 pages exist, and the name is new.
// - `Refused` (-6): the server has no store, or the storage service refused the page or the index of the pages.
//
// Example: `server.put("hello.html", "<h1>hello</h1>")`, then the host reads `http://<the address>/hello.html`.
@(export, link_name = "put")
put :: proc "c" (name: ^string, text: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	// The call region stays writable by the caller during the call: copy
	// the name one time before the checks, then check and use the copy only.
	name_copy: [PAGE_NAME_LIMIT + 1]u8
	name_length := min(len(name^), len(name_copy))
	copy(name_copy[:], name^)
	if len(name^) == 0 {
		return errors.fail(error, ERROR_NAME, .Empty, .Bytes, 1, 0, PAGE_NAME_LIMIT)
	}
	if len(name^) > PAGE_NAME_LIMIT {
		return errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, 1, i64(len(name^)), PAGE_NAME_LIMIT)
	}
	if ok, bad := web.page_name_valid(string(name_copy[:name_length])); !ok {
		return errors.fail(error, ERROR_NAME, .Bad_Byte, .Bytes, 1, i64(max(bad, 0)), 0, bad >= 0 ? i64(name_copy[bad]) : 0)
	}
	if len(text^) > PAGE_SIZE_LIMIT {
		return errors.fail(error, ERROR_TOO_LARGE, .Too_Long, .Bytes, 2, i64(len(text^)), PAGE_SIZE_LIMIT)
	}
	if !store_connected {
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	key := string(name_copy[:name_length])
	place := page_find(key)
	if place < 0 {
		for &item, index in pages {
			if !item.used {
				place = index
				break
			}
		}
	}
	if place < 0 {
		return errors.fail(error, ERROR_FULL, .Full, .Records, 0, 0, PAGE_CAPACITY)
	}
	// The bytes go to the staging buffer first (the call region can
	// change), then to the store, then to the page memory: the page that is
	// served changes only when the store took it.
	length := copy(page_staging[:PAGE_SIZE_LIMIT], text^)
	if _, status := storage.write(&store_client, storage.ROOT, key, page_staging[:length]); status != .Ok {
		system.log("server: the store refused the page /", key, ": the page that is served did not change")
		return errors.fail(error, ERROR_STORE, .Refused, .Store, 0, 0, 0, i64(status))
	}
	was_used := pages[place].used
	// A page that changes keeps its count of answers.
	served := was_used ? pages[place].served : 0
	copy(page_memory[place * PAGE_SIZE_LIMIT:][:PAGE_SIZE_LIMIT], page_staging[:length])
	pages[place] = {length = length, used = true, name_length = name_length, served = served, generation = page_generation_new()}
	copy(pages[place].name[:], key)
	if !was_used && !index_write() {
		// The index does not name the page: the page goes out again, so
		// that the store and what is served stay the same.
		pages[place] = {generation = page_generation_new()}
		arguments := [2]isolated.Argument{{integer = u64(storage.ROOT)}, {text = name_copy[:name_length]}}
		storage.call(&store_client, "remove", arguments[:])
		system.log("server: the store refused the index of the pages: /", key, " is not served")
		return errors.fail(error, ERROR_STORE, .Refused, .Store)
	}
	system.log("server: the page /", key, " is in the store: ", u64(length), " bytes")
	return i64(length)
}

// remove takes a page out of the private store of the server: /name gives 404 from now on.
//
// The store first: when the storage service refuses, the page stays in the store and stays served, so what the
// network sees never differs from what the store keeps.
//
// - **name**: the name of a page, as [put](server.put) gave it.
//
// The caller must act for the principal (**Acts_For_Principal**). The result is 0, or a negative number with an
// error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Absent` (-5): no page has this name.
// - `Refused` (-6): the storage service refused the removal; the page is still served.
@(export, link_name = "remove")
remove :: proc "c" (name: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	name_copy: [PAGE_NAME_LIMIT + 1]u8
	name_length := min(len(name^), len(name_copy))
	copy(name_copy[:], name^)
	place := page_find(string(name_copy[:name_length]))
	if place < 0 || len(name^) > PAGE_NAME_LIMIT {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 1)
	}
	// The store first: a page that the store keeps stays served. Else a
	// refused remove gives 404 until the next start of the server, and then
	// the page again.
	arguments := [2]isolated.Argument{{integer = u64(storage.ROOT)}, {text = name_copy[:name_length]}}
	_, _, status := storage.call(&store_client, "remove", arguments[:])
	if status != .Ok {
		system.log("server: the store refused the removal of /", string(name_copy[:name_length]), ": the page is still served")
		return errors.fail(error, ERROR_STORE, .Refused, .Store, 0, 0, 0, i64(status))
	}
	pages[place] = {generation = page_generation_new()}
	if !index_write() {
		// The object is out of the store; the index still names it, and the
		// next start skips a name with no object.
		system.log("server: the store refused the index of the pages after the removal of /", string(name_copy[:name_length]))
	}
	system.log("server: the page /", string(name_copy[:name_length]), " is out of the store")
	return 0
}

// pages gives one row for each page that the server serves: its name, its bytes, the answers of it since the start, its content type.
//
// Each caller gets the rows, with no grant: the pages are public on the network already.
//
// - **result**: a table of `Page_Row` rows; the call fills at most its length.
//
// The result is the count of pages, 16 at most. It never fails.
@(export, link_name = "pages")
pages_export :: proc "c" (result: ^[]Page_Row, error: ^errors.Error_Record) -> i64 {
	total := 0
	for &item, index in pages {
		if !item.used {
			continue
		}
		if total < len(result^) {
			row := &result[total]
			row^ = {bytes = i64(item.length), served = i64(item.served)}
			copy(row.name[:len(row.name) - 1], page_name(index))
			copy(row.type[:len(row.type) - 1], web.content_type_of_name(page_name(index)))
		}
		total += 1
	}
	return i64(total)
}

// served gives the counts of the server: the requests that it answered, by class of status, its connections, its bytes and its pages.
//
// These are facts of the server itself: each caller sees them. The bytes in count the data of connections that
// ended; `calls` counts the calls of the exports.
//
// - **result**: one `Served` record.
//
// It never fails.
@(export, link_name = "served")
served :: proc "c" (result: ^Served) {
	page_count := 0
	for &item in pages {
		if item.used {
			page_count += 1
		}
	}
	result^ = {
		requests             = i64(requests_answered),
		answers_2xx          = i64(status_classes[2]),
		answers_4xx          = i64(status_classes[4]),
		answers_5xx          = i64(status_classes[5]),
		connections_accepted = i64(accepted),
		connections_open     = i64(tcp_open_count()),
		bytes_in             = i64(bytes_in),
		bytes_out            = i64(bytes_out),
		pages                = i64(page_count),
		calls                = i64(service.calls),
	}
}

// counts_html writes the page / : the counts of the server as HTML, and
// the links to its pages.
counts_html :: proc "contextless" (buffer: []u8) -> string {
	writer := system.Writer{buffer = buffer}
	text :: proc "contextless" (writer: ^system.Writer, parts: ..system.Part) {
		for part in parts {
			system.write_part(writer, part)
		}
	}
	row :: proc "contextless" (writer: ^system.Writer, name: string, value: u64) {
		text(writer, "<tr><td>", name, "</td><td>", value, "</td></tr>\n")
	}
	text(&writer, "<!doctype html>\n<html><head><title>server</title></head><body>\n<h1>server</h1>\n<p>An HTTP/1.1 server of this system: TCP in the program, one thread, one table of ", u64(CAPACITY), " connections.</p>\n<table>\n")
	row(&writer, "connections open", u64(tcp_open_count()))
	row(&writer, "connections accepted", accepted)
	row(&writer, "requests answered", requests_answered)
	row(&writer, "answers 2xx", status_classes[2])
	row(&writer, "answers 4xx", status_classes[4])
	row(&writer, "answers 5xx", status_classes[5])
	row(&writer, "bytes in", bytes_in)
	row(&writer, "bytes out", bytes_out)
	row(&writer, "retransmitted segments", retransmissions)
	row(&writer, "milliseconds since the start", system.time() - start_time)
	row(&writer, "kernel entries of this program", system.kernel_entries())
	text(&writer, "</table>\n<p>pages:")
	for &item, index in pages {
		if item.used {
			// The names follow the rules of web.page_name_valid; they are
			// escaped anyway: the store is hostile input too.
			escaped: [6 * PAGE_NAME_LIMIT]u8
			name := string(escaped[:web.html_text_escape(escaped[:], page_name(index))])
			text(&writer, " <a href=\"/", name, "\">", name, "</a>")
		}
	}
	text(&writer, "</p>\n</body></html>\n")
	return system.written(&writer)
}

// counts_json writes the page /counts.json: the same counts as one JSON object.
counts_json :: proc "contextless" (buffer: []u8) -> string {
	return system.format(buffer, "{\"connections_open\":", u64(tcp_open_count()), ",\"connections_accepted\":", accepted, ",\"requests\":", requests_answered, ",\"answers_2xx\":", status_classes[2], ",\"answers_4xx\":", status_classes[4], ",\"answers_5xx\":", status_classes[5], ",\"bytes_in\":", bytes_in, ",\"bytes_out\":", bytes_out, ",\"retransmissions\":", retransmissions, ",\"uptime_ms\":", system.time() - start_time, ",\"kernel_entries\":", system.kernel_entries(), "}\n")
}

tcp_open_count :: proc "contextless" () -> int {
	count := 0
	for &item in connections {
		if item.state != .Closed && item.state != .Time_Wait {
			count += 1
		}
	}
	return count
}
