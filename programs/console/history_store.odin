package console

// The line history across a stop (docs/CONSOLE.md, section 6). The history
// is the state of the console: it goes to a store of its own in the
// storage service, apart from the private store that the person fills.
// The root service gives the connection (Root_Command.Connect_History):
// that store and no other one, with a limit of 4 blocks.
//
//   the load   At the start, in the first thread, before it reads a key:
//              the connection, then the file of the history. The second
//              thread runs no line yet, so the history has one user.
//   the save   After each line that the history added, in the second
//              thread, while the line still counts as running: the first
//              thread adds no line meanwhile. One commit for each line
//              added: a held Enter adds one line at most (an empty line
//              and the newest line again add nothing), so the commits
//              follow the lines that the person types. Before shutdown()
//              and stop("console"), whose save after the line never comes.
//
// A line of the file is data that this run did not write: the read checks
// each field and each byte, a line keeps the bounds of a typed line (200
// bytes, the bytes 32 to 126), and nothing of the file runs. A file that a
// check refuses gives an empty history and one log line.

import "contract:blake3"
import "contract:errors"
import module "contract:module"
import "support:line_editor"
import "support:storage"
import "support:system"

HISTORY_OBJECT_NAME :: "line_history"
// The time that the console waits for the connection at its start: the
// storage service mounts the data disk at boot, which takes longer than a
// call of the root ring.
HISTORY_CONNECT_TIME :: 30_000

history_client: storage.Client
history_connected: bool
history_saved_lines: u64 // history.lines_written at the last save or load.
history_save_failure_logged: bool

// history_store_open asks the root service for the connection to the store
// of the history, and maps its call ring and its call region. The file of
// the storage service, with its descriptions, is the file of the boot image
// with the hash that the root service names.
history_store_open :: proc "contextless" () -> (opened: bool) {
	completion, answered := request_record(.Connect_History, "storage", 0, HISTORY_CONNECT_TIME)
	if !answered {
		system.log("console: the line history stays in memory: the root service did not answer")
		return false
	}
	if system.Status(completion.kind) != .Ok {
		text: [240]u8
		system.log("console: the line history stays in memory: ", root_refusal_text(text[:], completion))
		return false
	}
	client := storage.Client {
		service       = system.Handle(completion.values[0]),
		ring_memory   = system.Handle(completion.values[1]),
		region_memory = system.Handle(completion.values[2]),
	}
	hash := transmute([32]u8)[4]u64{completion.values[3], completion.values[4], completion.values[5], completion.values[6]}
	entry := system.image_entry_of(image, hash)
	file: []u8
	if entry != nil {
		file = image[entry.offset:][:entry.size]
	}
	if file == nil || blake3.hash(file) != hash || module.validate(file) != .None {
		system.log("console: the line history stays in memory: the boot image has no valid file of the storage service")
		history_store_close(&client)
		return false
	}
	client.file = file
	ring_status, region_status: system.Status
	client.calls, ring_status = system.ring_open(client.ring_memory)
	address: rawptr
	address, region_status = system.memory_map(client.region_memory)
	if ring_status != .Ok || region_status != .Ok {
		system.log("console: the line history stays in memory: the call ring or the call region does not map")
		history_store_close(&client)
		return false
	}
	client.region = ([^]u8)(address)[:system.memory_size(client.region_memory) * system.PAGE_SIZE]
	history_client = client
	history_connected = true
	return true
}

history_store_close :: proc "contextless" (client: ^storage.Client) {
	if client.calls.head != nil {
		system.ring_close(&client.calls)
	}
	system.close(client.ring_memory)
	system.close(client.region_memory)
	system.close(client.service)
	client^ = {}
}

// history_load reads the history of the run before, at the start of the
// console. Each outcome writes one log line.
history_load :: proc "contextless" () {
	if !history_store_open() {
		return
	}
	// One byte more than a file can have: a larger object is refused.
	buffer: [line_editor.HISTORY_FILE_SIZE_LIMIT + 1]u8
	error: errors.Error_Record
	bytes, found, status := storage.read(&history_client, storage.ROOT, HISTORY_OBJECT_NAME, buffer[:], &error)
	switch {
	case status == .Damaged:
		system.log("console: the line history is damaged in its store: the history starts empty")
	case status != .Ok:
		text: [240]u8
		writer := system.Writer {
			buffer = text[:],
		}
		if status == .Failed {
			storage.error_text(&writer, &history_client, &error)
		} else {
			system.write_part(&writer, "the storage service did not answer the read")
		}
		system.log("console: the line history cannot be read: ", system.written(&writer), ": the history starts empty")
	case !found:
		system.log("console: no line history kept: the history starts empty")
	case len(bytes) > line_editor.HISTORY_FILE_SIZE_LIMIT:
		system.log("console: the line history has more than ", u64(line_editor.HISTORY_FILE_SIZE_LIMIT), " bytes: the history starts empty")
	case:
		if problem := line_editor.history_file_read(bytes, &history); problem != .None {
			system.log("console: the line history is refused, ", line_editor.history_file_problem_texts[problem], ": the history starts empty")
		} else {
			system.log("console: the line history: ", u64(line_editor.history_count(&history)), " lines kept from before the stop")
		}
	}
	history_saved_lines = history.lines_written
}

// history_save writes the history to its store, when lines were added
// since the last save. A failure writes one log line in a run: the history
// stays in memory.
history_save :: proc "contextless" () {
	if !history_connected || history.lines_written == history_saved_lines {
		return
	}
	buffer: [line_editor.HISTORY_FILE_SIZE_LIMIT]u8
	bytes := line_editor.history_file_write(&history, buffer[:])
	error: errors.Error_Record
	_, status := storage.write(&history_client, storage.ROOT, HISTORY_OBJECT_NAME, bytes, &error)
	if status == .Ok {
		history_saved_lines = history.lines_written
		return
	}
	if !history_save_failure_logged {
		history_save_failure_logged = true
		text: [240]u8
		writer := system.Writer {
			buffer = text[:],
		}
		if status == .Failed {
			storage.error_text(&writer, &history_client, &error)
		} else {
			system.write_part(&writer, "the store of the history is not reachable")
		}
		system.log("console: the line history is not kept: ", system.written(&writer))
	}
}

// history_clear forgets the line history: in the memory of the console,
// and its object and each version of it in its store. The line of the
// command goes too.
history_clear :: proc "contextless" (arguments: []Value) -> Value {
	count := line_editor.history_count(&history)
	history = {}
	history_place = 0
	history_saved_lines = history.lines_written
	if !history_connected {
		print("the line history is cleared: ", u64(count), " lines; it had no store\n")
		return {}
	}
	error: errors.Error_Record
	result, status := storage.remove(&history_client, storage.ROOT, HISTORY_OBJECT_NAME, &error)
	if status == .Ok || status == .Failed && result == storage.ERROR_ABSENT {
		print("the line history is cleared: ", u64(count), " lines, and its store\n")
		return {}
	}
	text: [240]u8
	writer := system.Writer {
		buffer = text[:],
	}
	storage.error_text(&writer, &history_client, &error)
	return fail("the line history is cleared in memory; its store: ", system.written(&writer))
}
