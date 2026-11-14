package compositor

import "modus:support/display"
import "modus:support/key_path"
import "modus:contract/ring"
import "modus:support/system"

// The events of a window whose ring is full
// (docs/ARCHITECTURE.md, "The path of a key").
//
// The compositor cannot wait for a window: one program that does not read
// would stop the desktop. So it keeps, for each window, the records that
// the ring of the window refused (`key_path.Window_Queue`), and it sends
// them in order, before any newer record, when the ring has room. The keys
// stay with the window that had the focus when they arrived: a change of
// the focus moves no record. The moves of the pointer that wait become one
// move. When the queue of a window is full too, the record is refused: it
// is counted, and the log has one line when the loss begins and one line
// with the counts when it ends.

// The queue of each client, at the index of the client in `clients`.
window_queues: [CLIENT_CAPACITY]key_path.Window_Queue
// The memory of the records of each queue: 0 until the ring of a window of
// this place is full a first time. The place keeps it for its next windows.
window_queue_memory: [CLIENT_CAPACITY]system.Handle
window_queue_records: [CLIENT_CAPACITY][^]ring.Record
window_queue_memory_refused: [CLIENT_CAPACITY]bool // The system gave no memory: the log has it one time.
// The records that the queues of all the windows refused since the start,
// the windows that closed included.
key_records_refused: u64
pointer_records_refused: u64
other_records_refused: u64

WINDOW_QUEUE_PAGES :: key_path.WINDOW_QUEUE_CAPACITY * size_of(ring.Record) / system.PAGE_SIZE

@(private = "file")
client_index :: proc "contextless" (client: ^Client) -> int {
	return int((uintptr(client) - uintptr(&clients[0])) / size_of(Client))
}

// window_queue_memory_open gives its memory to the queue of a client, at
// the first time that the ring of a window of this place is full.
@(private = "file")
window_queue_memory_open :: proc "contextless" (index: int) {
	queue := &window_queues[index]
	if len(queue.records) > 0 || window_queue_memory_refused[index] {
		return
	}
	if window_queue_records[index] == nil {
		memory, status := system.memory_create(WINDOW_QUEUE_PAGES)
		address: rawptr
		if status == .Ok {
			address, status = system.memory_map(memory)
			if status != .Ok {
				system.close(memory)
			}
		}
		if status != .Ok {
			window_queue_memory_refused[index] = true
			system.log("compositor: no memory for the records that wait for window ", system.name_of(clients[index].title[:]), ": each record that its full ring refuses is lost")
			return
		}
		window_queue_memory[index] = memory
		window_queue_records[index] = ([^]ring.Record)(address)
	}
	queue.records = window_queue_records[index][:key_path.WINDOW_QUEUE_CAPACITY]
}

// window_event_send gives an event to a window. The records that wait for
// the window go first; when its ring is full, the event waits in the queue
// of the window, and a move of the pointer replaces the move that waits.
window_event_send :: proc "contextless" (client: ^Client, record: ring.Record) {
	index := client_index(client)
	queue := &window_queues[index]
	target := &client.ring.completions
	if ring.count(target) == ring.capacity(target) {
		window_queue_memory_open(index)
	}
	class := key_path.Record_Class.Other
	#partial switch display.Event_Kind(record.kind) {
	case .Pointer:
		class = .Pointer
	case .Key:
		class = .Key
	}
	refused_before := queue.refused[class]
	result: key_path.Put_Result
	if class == .Pointer {
		result = key_path.window_queue_put_pointer(queue, target, record, record.values[2])
	} else {
		result = key_path.window_queue_put(queue, target, record, class)
	}
	if result.wrote {
		system.wake_reader(target)
	}
	if result.loss_began {
		system.log("compositor: window ", system.name_of(client.title[:]), " does not read its events: ", u64(queue.count), " records wait for it, and a new record is lost")
	}
	if queue.refused[class] != refused_before {
		switch class {
		case .Key:
			key_records_refused += 1
		case .Pointer:
			pointer_records_refused += 1
		case .Other:
			other_records_refused += 1
		}
	}
}

// window_events_pass sends the records that wait to each window whose ring
// has room again, and writes the end of a loss period in the log. The loop
// of the compositor calls it one time in each turn: it reads one count for
// each client, and it writes only for a window that had a full ring.
window_events_pass :: proc "contextless" () {
	for &queue, index in window_queues {
		if !key_path.window_queue_waits(&queue) && !queue.loss.open {
			continue
		}
		client := &clients[index]
		if client.ring.head == nil {
			continue
		}
		if key_path.window_queue_send_waiting(&queue, &client.ring.completions) {
			system.wake_reader(&client.ring.completions)
		}
		if lost, ended := key_path.window_queue_loss_ended(&queue); ended {
			system.log("compositor: window ", system.name_of(client.title[:]), " reads its events again: ", lost[.Key], " key records, ", lost[.Pointer], " pointer records and ", lost[.Other], " other records were lost")
		}
	}
}

// window_events_wait adds to the wait of the loop the ring of each window
// that has records waiting: the compositor wakes when the window read half
// of its ring, or before the window waits itself.
//
// It waits only on a ring that is exactly full. A program writes the read
// counter of its ring: with a false count, the wait would end at once in
// each turn. A window that gives a false count gets its records in a later
// turn of the loop, and nothing more.
window_events_wait :: proc "contextless" (wait: ^system.Wait) {
	TRIES :: 4 // The window can read between the send and the look at the counters.
	for &queue, index in window_queues {
		client := &clients[index]
		if client.ring.head == nil {
			continue
		}
		target := &client.ring.completions
		for _ in 0 ..< TRIES {
			if !key_path.window_queue_waits(&queue) {
				break
			}
			if key_path.queue_is_exactly_full(target) {
				system.wait_room(wait, target)
				break
			}
			if key_path.window_queue_send_waiting(&queue, target) {
				system.wake_reader(target)
			}
		}
	}
}

// window_queue_close ends the queue of a client that leaves: the records
// that wait have no reader any more. A loss period that is open ends in
// the log. The memory of the queue stays with the place of the client.
window_queue_close :: proc "contextless" (index: int) {
	queue := &window_queues[index]
	if queue.loss.open {
		lost := key_path.window_queue_loss_close(queue)
		system.log("compositor: window ", system.name_of(clients[index].title[:]), " closed and did not read its events: ", lost[.Key], " key records, ", lost[.Pointer], " pointer records and ", lost[.Other], " other records were lost")
	}
	queue^ = {}
}

// keys_waiting_of_all_windows gives the key records that wait in the
// queues of all the windows.
keys_waiting_of_all_windows :: proc "contextless" () -> (count: int) {
	for &queue in window_queues {
		count += queue.waiting_keys
	}
	return count
}
