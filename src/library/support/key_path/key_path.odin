// The path of a key: the rules of the queues between the keyboard and the
// program that reads a key, as code with no kernel entry, so that a test
// of the host runs them (docs/ARCHITECTURE.md, "The path of a key").
//
// The rule of the path: the system never loses a key in silence. A full
// queue stops its writer when the writer can wait. When the writer cannot
// wait, the queue has a stated capacity, and each record that it refuses is
// counted and is in the log.
//
// The parts:
//
// - `input_byte_can_be_read`, `Pointer_Backlog`: the input service does not
//   take a byte from the keyboard controller when it has no place for the
//   record of that byte. The moves of the pointer that wait become one move.
// - `Window_Queue`: the compositor cannot wait for a window. It keeps the
//   records that the ring of a window refused, and it sends them in order
//   before any newer record.
// - `Loss_Period`: a writer that must refuse a record writes one line in
//   the log when the loss begins and one line, with the count, when it
//   ends: not one line for each record.
package key_path

import "modus:contract/ring"
import "base:intrinsics"

// A time when a queue refuses records, from the first refusal to the
// moment when the queue takes a record again.
Loss_Period :: struct {
	lost:      u64, // The records lost since the start.
	in_period: u64, // The records lost in the period that is open.
	open:      bool, // A record was lost, and the loss did not end yet.
}

// loss_count counts lost records. true: the loss begins with them, and the
// caller writes the first line of the period in the log.
loss_count :: proc "contextless" (period: ^Loss_Period, count: u64 = 1) -> (began: bool) {
	period.lost += count
	period.in_period += count
	began = !period.open
	period.open = true
	return began
}

// loss_end ends the period that is open: the queue takes records again. It
// gives the records lost in the period; ended is false when no period was
// open, and the caller then writes nothing.
loss_end :: proc "contextless" (period: ^Loss_Period) -> (count: u64, ended: bool) {
	if !period.open {
		return 0, false
	}
	count = period.in_period
	period.in_period = 0
	period.open = false
	return count, true
}

// The changes of a button that the input service keeps while the input ring
// is full. A move with the same buttons joins the entry before it, so this
// is the count of presses and releases that can wait: 4 clicks. When no
// entry is free, the input service leaves the bytes of the mouse in the
// controller.
POINTER_BACKLOG_CAPACITY :: 8

// One packet of the mouse: a relative move and the state of the buttons.
Pointer_Packet :: struct {
	motion_x: i64,
	motion_y: i64,
	buttons:  u64,
}

// The packets of the mouse that found the input ring full, in order.
Pointer_Backlog :: struct {
	packets: [POINTER_BACKLOG_CAPACITY]Pointer_Packet,
	count:   int,
	merged:  u64, // The moves that joined the move before them since the start.
}

// input_byte_can_be_read is the back pressure rule of the input service:
// it says if the service takes the next byte of the keyboard controller.
// One byte makes at most one record, so the service takes a byte only when
// that record has a place.
//
// - A byte of the keyboard: only when the input ring has room and no packet
//   of the mouse waits before it. If not, the byte stays in the controller,
//   and the keyboard holds the bytes after it.
// - A byte of the mouse: also when the backlog has a free entry, because
//   the packet of this byte then joins the backlog.
input_byte_can_be_read :: proc "contextless" (from_mouse: bool, ring_has_room: bool, backlog_count: int) -> bool {
	if ring_has_room && backlog_count == 0 {
		return true
	}
	return from_mouse && backlog_count < POINTER_BACKLOG_CAPACITY
}

// pointer_backlog_add keeps a packet that the input ring refused. A packet
// with the buttons of the last packet joins it: the two moves become one
// move with the same end place, and no change of a button is lost. false:
// the packet changes a button and no entry is free; the caller must not
// read a byte of the mouse in that state (`input_byte_can_be_read`).
pointer_backlog_add :: proc "contextless" (backlog: ^Pointer_Backlog, packet: Pointer_Packet) -> bool {
	if backlog.count > 0 {
		last := &backlog.packets[backlog.count - 1]
		if last.buttons == packet.buttons {
			last.motion_x += packet.motion_x
			last.motion_y += packet.motion_y
			backlog.merged += 1
			return true
		}
	}
	if backlog.count == POINTER_BACKLOG_CAPACITY {
		return false
	}
	backlog.packets[backlog.count] = packet
	backlog.count += 1
	return true
}

// pointer_backlog_first gives the oldest packet that waits. ok is false
// when none waits.
pointer_backlog_first :: proc "contextless" (backlog: ^Pointer_Backlog) -> (packet: Pointer_Packet, ok: bool) {
	if backlog.count == 0 {
		return {}, false
	}
	return backlog.packets[0], true
}

// pointer_backlog_remove_first removes the oldest packet: the input ring
// took its record.
pointer_backlog_remove_first :: proc "contextless" (backlog: ^Pointer_Backlog) {
	if backlog.count == 0 {
		return
	}
	for index in 1 ..< backlog.count {
		backlog.packets[index - 1] = backlog.packets[index]
	}
	backlog.count -= 1
}

// The records that the compositor keeps for one window whose ring is full:
// 256, which is 4 pages. With the 32 records of the ring, a window that
// does not read for a moment misses nothing of 144 keys, each one a press
// and a release: more than half of the longest line of the console, typed
// while the window draws one picture.
WINDOW_QUEUE_CAPACITY :: 256

// What a record of a window is, for the counts of the refused records.
Record_Class :: enum u8 {
	Key, // A press or a release of a key.
	Pointer, // A change of a button of the pointer.
	Other, // Another event of the window, as a change of the settings.
}

// The records that wait for one window, as the compositor holds them.
//
// The records that have an order (a key, a change of a button, another
// event) wait in `records`, the oldest first. The moves of the pointer do
// not wait in that order: only the last place counts, so one record,
// `move`, holds the newest move, and it goes to the window after the
// records that have an order.
Window_Queue :: struct {
	records:     []ring.Record, // The memory of the records that wait. Its length is the capacity; with no memory, each record that the ring refuses is refused.
	first:       int, // The place of the oldest record that waits.
	count:       int, // The records that wait in `records`.
	move:        ring.Record, // The newest move of the pointer, when move_waits.
	move_waits:  bool,
	buttons:     u64, // The buttons of the last pointer record that the compositor gave for this window.
	delivered:   u64, // The records that the ring of the window took since the window opened.
	keys_delivered: u64, // The key records among them.
	waiting_keys: int, // The key records that wait in `records`.
	moves_merged: u64, // The moves that a newer move replaced before the window read them.
	refused:     [Record_Class]u64, // The records that found the queue full, since the window opened.
	period_start: [Record_Class]u64, // `refused` when the loss period that is open began.
	loss:        Loss_Period, // The records of each class together.
	classes:     [WINDOW_QUEUE_CAPACITY / 8]u8, // One bit for each place of `records`: 1 for a key record.
}

// What a put did, for the caller that wakes the reader and writes the log.
Put_Result :: struct {
	wrote:      bool, // The ring took at least one record: the caller wakes its reader.
	loss_began: bool, // The queue refused the record, and it is the first one of a loss period.
}

@(private)
place_is_key :: proc "contextless" (queue: ^Window_Queue, place: int) -> bool {
	bit := place % WINDOW_QUEUE_CAPACITY
	return queue.classes[bit / 8] & (u8(1) << uint(bit % 8)) != 0
}

@(private)
place_set_key :: proc "contextless" (queue: ^Window_Queue, place: int, is_key: bool) {
	bit := place % WINDOW_QUEUE_CAPACITY
	mask := u8(1) << uint(bit % 8)
	if is_key {
		queue.classes[bit / 8] |= mask
	} else {
		queue.classes[bit / 8] &~= mask
	}
}

// window_queue_capacity gives the records that can wait: the length of the
// memory, and at most `WINDOW_QUEUE_CAPACITY`.
window_queue_capacity :: proc "contextless" (queue: ^Window_Queue) -> int {
	return min(len(queue.records), WINDOW_QUEUE_CAPACITY)
}

// window_queue_waits says if a record waits for the window: the compositor
// then waits for room in the ring of the window.
window_queue_waits :: proc "contextless" (queue: ^Window_Queue) -> bool {
	return queue.count > 0 || queue.move_waits
}

// window_queue_send_waiting writes in the ring the records that wait, the
// oldest first, while the ring has room; then the newest move of the
// pointer. true: the ring took at least one record, and the caller wakes
// its reader.
window_queue_send_waiting :: proc "contextless" (queue: ^Window_Queue, target: ^ring.Queue) -> (wrote: bool) {
	capacity := window_queue_capacity(queue)
	for queue.count > 0 {
		if !ring.push(target, queue.records[queue.first]) {
			return wrote
		}
		wrote = true
		queue.delivered += 1
		if place_is_key(queue, queue.first) {
			queue.keys_delivered += 1
			queue.waiting_keys -= 1
		}
		queue.first = (queue.first + 1) % capacity
		queue.count -= 1
	}
	if queue.move_waits && ring.push(target, queue.move) {
		queue.move_waits = false
		queue.delivered += 1
		wrote = true
	}
	return wrote
}

// window_queue_put gives to a window a record that has an order: a key
// (class Key), or another event (class Other). The records that wait go
// first. When the ring is full, the record waits; when the queue is full
// too, the record is refused and counted.
window_queue_put :: proc "contextless" (queue: ^Window_Queue, target: ^ring.Queue, record: ring.Record, class: Record_Class) -> (result: Put_Result) {
	result.wrote = window_queue_send_waiting(queue, target)
	if queue.count == 0 && ring.push(target, record) {
		queue.delivered += 1
		if class == .Key {
			queue.keys_delivered += 1
		}
		result.wrote = true
		return result
	}
	capacity := window_queue_capacity(queue)
	if queue.count >= capacity {
		queue.refused[class] += 1
		if loss_count(&queue.loss) {
			result.loss_began = true
			queue.period_start = queue.refused
			queue.period_start[class] -= 1 // The record of this call is in the period.
		}
		return result
	}
	place := (queue.first + queue.count) % capacity
	queue.records[place] = record
	place_set_key(queue, place, class == .Key)
	if class == .Key {
		queue.waiting_keys += 1
	}
	queue.count += 1
	return result
}

// window_queue_put_pointer gives to a window a record of the pointer.
// buttons is the state of the buttons in the record.
//
// A record that changes a button has an order, as a key: a press that the
// window never sees is a lost action. It also holds the newest place, so
// the move that waited before it is dropped as merged. A record with the
// same buttons is a move: when the ring is full, it replaces the move that
// waits. No move takes a place of the queue of the keys.
window_queue_put_pointer :: proc "contextless" (queue: ^Window_Queue, target: ^ring.Queue, record: ring.Record, buttons: u64) -> (result: Put_Result) {
	if buttons != queue.buttons {
		queue.buttons = buttons
		result.wrote = window_queue_send_waiting(queue, target)
		if queue.move_waits {
			queue.move_waits = false
			queue.moves_merged += 1
		}
		put := window_queue_put(queue, target, record, .Pointer)
		result.wrote = result.wrote || put.wrote
		result.loss_began = put.loss_began
		return result
	}
	result.wrote = window_queue_send_waiting(queue, target)
	if !window_queue_waits(queue) && ring.push(target, record) {
		queue.delivered += 1
		result.wrote = true
		return result
	}
	if queue.move_waits {
		queue.moves_merged += 1
	}
	queue.move = record
	queue.move_waits = true
	return result
}

// window_queue_loss_ended says if the loss period of a window ends now: a
// period is open and no record waits, so the window reads again. It gives
// the records of each class that were refused in the period, and closes
// the period. The caller writes the second line of the period in the log.
window_queue_loss_ended :: proc "contextless" (queue: ^Window_Queue) -> (lost: [Record_Class]u64, ended: bool) {
	if !queue.loss.open || queue.count > 0 {
		return {}, false
	}
	return window_queue_loss_close(queue), true
}

// window_queue_loss_close closes the loss period that is open and gives its
// counts, also while records wait: for a window that closes.
window_queue_loss_close :: proc "contextless" (queue: ^Window_Queue) -> (lost: [Record_Class]u64) {
	for class in Record_Class {
		lost[class] = queue.refused[class] - queue.period_start[class]
	}
	loss_end(&queue.loss)
	queue.period_start = queue.refused
	return lost
}

// queue_is_exactly_full says if the counters of a queue give exactly a full
// queue: the one state in which a writer can wait for room. The reader
// writes one of the two counters, and a reader that is another program can
// write any number: a count above the capacity is a false count, and a
// writer that waited on it would never sleep.
queue_is_exactly_full :: proc "contextless" (target: ^ring.Queue) -> bool {
	return intrinsics.atomic_load_explicit(&target.counters.write, .Relaxed) - intrinsics.atomic_load_explicit(&target.counters.read, .Relaxed) == ring.capacity(target)
}
