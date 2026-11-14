#+build !freestanding
package key_path

import "modus:contract/ring"
import "core:testing"

// The memory of the smallest ring: 32 records in each queue.
@(private = "file")
Ring_Memory :: struct #align (ring.PAGE_SIZE) {
	bytes: [ring.PAGE_COUNT * ring.PAGE_SIZE]u8,
}

@(private = "file")
window_ring :: proc(memory: ^Ring_Memory) -> ring.Ring {
	opened, _ := ring.open(memory, ring.PAGE_COUNT)
	return opened
}

@(private = "file")
key_record :: proc(number: int) -> ring.Record {
	return {kind = 1, values = {0 = u64(number)}}
}

@(private = "file")
pointer_record :: proc(x: int, buttons: u64) -> ring.Record {
	return {kind = 2, values = {0 = u64(x), 2 = buttons}}
}

// read_some takes at most count records from the ring, as the window does.
@(private = "file")
read_some :: proc(target: ^ring.Queue, count: int, read: ^[dynamic]ring.Record) {
	for _ in 0 ..< count {
		record, ok := ring.pop(target)
		if !ok {
			return
		}
		append(read, record)
	}
}

// 200 keys go to a window that reads nothing: 32 are in its ring, 168 wait.
// The window then reads a few records at a time, and a newer key arrives
// between two reads: each key arrives, in the order in which it was typed,
// and none is refused.
@(test)
keys_stay_in_order_across_a_full_ring :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	for number in 0 ..< 200 {
		result := window_queue_put(&queue, target, key_record(number), .Key)
		testing.expect(t, !result.loss_began)
		testing.expect_value(t, result.wrote, number < 32)
	}
	testing.expect_value(t, queue.delivered, 32)
	testing.expect_value(t, queue.count, 168)
	testing.expect_value(t, queue.waiting_keys, 168)
	testing.expect(t, window_queue_waits(&queue))
	testing.expect(t, queue_is_exactly_full(target))

	typed := 200
	for round := 0; len(read) < typed && round < 1000; round += 1 {
		read_some(target, 7, &read)
		if round == 3 {
			// A key typed while older keys wait goes after them.
			window_queue_put(&queue, target, key_record(typed), .Key)
			typed += 1
		}
		window_queue_send_waiting(&queue, target)
	}
	testing.expect_value(t, len(read), 201)
	for record, index in read {
		testing.expect_value(t, record.values[0], u64(index))
	}
	testing.expect_value(t, queue.refused[Record_Class.Key], 0)
	testing.expect_value(t, queue.keys_delivered, 201)
	testing.expect_value(t, queue.waiting_keys, 0)
	testing.expect(t, !window_queue_waits(&queue))
	testing.expect(t, !queue.loss.open)
}

// The moves of the pointer to a window with a full ring become one move,
// the newest. A change of a button waits in order, and takes the place of
// the move before it. No move takes a place of the queue of the keys.
@(test)
pointer_moves_merge_and_button_changes_wait :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	// A move goes to a ring that has room, with no wait.
	testing.expect(t, window_queue_put_pointer(&queue, target, pointer_record(1, 0), 0).wrote)
	read_some(target, 1, &read)
	clear(&read)
	for number in 0 ..< 32 {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	for x in 10 ..< 15 {
		result := window_queue_put_pointer(&queue, target, pointer_record(x, 0), 0)
		testing.expect(t, !result.wrote && !result.loss_began)
	}
	testing.expect(t, queue.move_waits)
	testing.expect_value(t, queue.count, 0)
	testing.expect_value(t, queue.moves_merged, 4)
	testing.expect_value(t, queue.move.values[0], 14)

	// A key, then a press at a new place, then a move with the button down.
	window_queue_put(&queue, target, key_record(32), .Key)
	window_queue_put_pointer(&queue, target, pointer_record(20, 1), 1)
	testing.expect(t, !queue.move_waits, "the press holds the newest place")
	testing.expect_value(t, queue.count, 2)
	testing.expect_value(t, queue.moves_merged, 5)
	window_queue_put_pointer(&queue, target, pointer_record(21, 1), 1)
	window_queue_put_pointer(&queue, target, pointer_record(22, 1), 1)
	testing.expect_value(t, queue.count, 2)
	testing.expect(t, queue.move_waits)
	// The release.
	window_queue_put_pointer(&queue, target, pointer_record(23, 0), 0)
	testing.expect_value(t, queue.count, 3)
	testing.expect(t, !queue.move_waits)

	for round := 0; window_queue_waits(&queue) && round < 100; round += 1 {
		read_some(target, 5, &read)
		window_queue_send_waiting(&queue, target)
	}
	read_some(target, 64, &read)
	// 33 keys, the press and the release: the release holds the newest
	// place, so no move waited after it.
	testing.expect_value(t, len(read), 35)
	testing.expect_value(t, queue.moves_merged, 7)
	if len(read) == 35 {
		for index in 0 ..< 33 {
			testing.expect_value(t, read[index].kind, 1)
			testing.expect_value(t, read[index].values[0], u64(index))
		}
		testing.expect_value(t, read[33].values[0], 20)
		testing.expect_value(t, read[33].values[2], 1)
		testing.expect_value(t, read[34].values[0], 23)
		testing.expect_value(t, read[34].values[2], 0)
	}
}

// The move that waits goes to the window after the records that have an
// order.
@(test)
a_move_after_the_ordered_records :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	for number in 0 ..< 33 {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	window_queue_put_pointer(&queue, target, pointer_record(5, 0), 0)
	window_queue_put_pointer(&queue, target, pointer_record(6, 0), 0)
	testing.expect_value(t, queue.count, 1)
	testing.expect(t, queue.move_waits)
	read_some(target, 32, &read)
	testing.expect(t, window_queue_send_waiting(&queue, target))
	read_some(target, 32, &read)
	testing.expect_value(t, len(read), 34)
	if len(read) == 34 {
		testing.expect_value(t, read[32].values[0], 32)
		testing.expect_value(t, read[33].kind, 2)
		testing.expect_value(t, read[33].values[0], 6)
	}
	testing.expect_value(t, queue.delivered, 34)
	testing.expect_value(t, queue.keys_delivered, 33)
}

// With the ring full and 256 records waiting, a record is refused and
// counted. The loss period begins one time, ends when the window read each
// record that waited, and gives the counts of the period only.
@(test)
a_full_queue_refuses_and_counts :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	for period in 0 ..< 2 {
		clear(&read)
		kept := 32 + WINDOW_QUEUE_CAPACITY
		for number in 0 ..< kept {
			testing.expect(t, !window_queue_put(&queue, target, key_record(number), .Key).loss_began)
		}
		testing.expect_value(t, queue.count, WINDOW_QUEUE_CAPACITY)
		began := 0
		for number in 0 ..< 3 + period {
			if window_queue_put(&queue, target, key_record(1000 + number), .Key).loss_began {
				began += 1
			}
		}
		if window_queue_put(&queue, target, ring.Record{kind = 3}, .Other).loss_began {
			began += 1
		}
		// A change of a button is refused too; a move is not: it waits alone.
		if window_queue_put_pointer(&queue, target, pointer_record(1, u64(1 + period)), u64(1 + period)).loss_began {
			began += 1
		}
		window_queue_put_pointer(&queue, target, pointer_record(2, u64(1 + period)), u64(1 + period))
		testing.expect_value(t, began, 1)
		testing.expect(t, queue.loss.open)
		testing.expect(t, queue.move_waits)
		_, ended_early := window_queue_loss_ended(&queue)
		testing.expect(t, !ended_early, "records still wait")

		for round := 0; window_queue_waits(&queue) && round < 1000; round += 1 {
			read_some(target, 9, &read)
			window_queue_send_waiting(&queue, target)
		}
		read_some(target, 64, &read)
		lost, ended := window_queue_loss_ended(&queue)
		testing.expect(t, ended)
		testing.expect_value(t, lost[Record_Class.Key], u64(3 + period))
		testing.expect_value(t, lost[Record_Class.Other], 1)
		testing.expect_value(t, lost[Record_Class.Pointer], 1)
		_, again := window_queue_loss_ended(&queue)
		testing.expect(t, !again)
		// Each record that was kept arrived, in order; the move after them.
		testing.expect_value(t, len(read), kept + 1)
		for index in 0 ..< min(kept, len(read)) {
			testing.expect_value(t, read[index].values[0], u64(index))
		}
	}
	testing.expect_value(t, queue.refused[Record_Class.Key], 7)
	testing.expect_value(t, queue.loss.lost, 11)
}

// A queue with no memory keeps nothing: the ring is the only room.
@(test)
a_queue_with_no_memory_refuses_at_a_full_ring :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	queue: Window_Queue
	for number in 0 ..< 32 {
		testing.expect(t, window_queue_put(&queue, target, key_record(number), .Key).wrote)
	}
	result := window_queue_put(&queue, target, key_record(32), .Key)
	testing.expect(t, !result.wrote && result.loss_began)
	testing.expect_value(t, queue.refused[Record_Class.Key], 1)
	testing.expect_value(t, queue.count, 0)
}

// A reader that writes a false read count does not look like a full queue:
// the writer waits for room only on a queue that is exactly full.
@(test)
only_an_exactly_full_queue_is_waited_on :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	testing.expect(t, !queue_is_exactly_full(target))
	for number in 0 ..< 32 {
		ring.push(target, key_record(number))
	}
	testing.expect(t, queue_is_exactly_full(target))
	target.counters.read = target.counters.write - 40 // More records than the queue holds.
	testing.expect(t, !queue_is_exactly_full(target))
	testing.expect(t, !ring.push(target, key_record(0)), "the queue still takes nothing")
	target.counters.read = target.counters.write - 31
	testing.expect(t, !queue_is_exactly_full(target))
}

// The back pressure rule of the input service: a byte of the keyboard is
// read only when its record has a place in the ring, after each packet of
// the mouse that waits; a byte of the mouse also while the backlog has a
// free entry.
@(test)
the_input_service_reads_a_byte_only_with_a_place_for_its_record :: proc(t: ^testing.T) {
	testing.expect(t, input_byte_can_be_read(false, true, 0))
	testing.expect(t, input_byte_can_be_read(true, true, 0))
	testing.expect(t, !input_byte_can_be_read(false, false, 0), "a full ring holds the keyboard")
	testing.expect(t, !input_byte_can_be_read(false, true, 1), "a key does not pass a packet that waits")
	testing.expect(t, input_byte_can_be_read(true, false, 0))
	testing.expect(t, input_byte_can_be_read(true, false, POINTER_BACKLOG_CAPACITY - 1))
	testing.expect(t, !input_byte_can_be_read(true, false, POINTER_BACKLOG_CAPACITY), "a full backlog holds the mouse")
	testing.expect(t, !input_byte_can_be_read(true, true, POINTER_BACKLOG_CAPACITY))
}

// The moves that wait in the input service add up: the end place is the
// same. Each change of a button keeps its entry and its order.
@(test)
the_moves_of_the_backlog_add_up :: proc(t: ^testing.T) {
	backlog: Pointer_Backlog
	_, any := pointer_backlog_first(&backlog)
	testing.expect(t, !any)
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 3, motion_y = -2}))
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 4, motion_y = -1}))
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = -10, motion_y = 5}))
	testing.expect_value(t, backlog.count, 1)
	testing.expect_value(t, backlog.merged, 2)
	testing.expect_value(t, backlog.packets[0], Pointer_Packet{motion_x = -3, motion_y = 2})
	// A press, a move with the button down, a release.
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 1, buttons = 1}))
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 1, buttons = 1}))
	testing.expect(t, pointer_backlog_add(&backlog, {buttons = 0}))
	testing.expect_value(t, backlog.count, 3)
	first, _ := pointer_backlog_first(&backlog)
	testing.expect_value(t, first, Pointer_Packet{motion_x = -3, motion_y = 2})
	pointer_backlog_remove_first(&backlog)
	first, _ = pointer_backlog_first(&backlog)
	testing.expect_value(t, first, Pointer_Packet{motion_x = 2, buttons = 1})
	pointer_backlog_remove_first(&backlog)
	pointer_backlog_remove_first(&backlog)
	pointer_backlog_remove_first(&backlog) // None waits: nothing changes.
	testing.expect_value(t, backlog.count, 0)

	// Changes of a button fill the backlog; a move with the last buttons
	// still joins; one more change has no entry.
	for number in 0 ..< POINTER_BACKLOG_CAPACITY {
		testing.expect(t, pointer_backlog_add(&backlog, {buttons = u64(number % 2 + 1)}))
	}
	last_buttons := u64((POINTER_BACKLOG_CAPACITY - 1) % 2 + 1)
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 9, buttons = last_buttons}))
	testing.expect(t, !pointer_backlog_add(&backlog, {buttons = 4}))
	testing.expect_value(t, backlog.count, POINTER_BACKLOG_CAPACITY)
}

// One line when a loss begins, the count when it ends, and a new period
// after that.
@(test)
a_loss_period_begins_one_time_and_gives_its_count :: proc(t: ^testing.T) {
	period: Loss_Period
	_, ended := loss_end(&period)
	testing.expect(t, !ended, "no period is open")
	testing.expect(t, loss_count(&period))
	testing.expect(t, !loss_count(&period))
	testing.expect(t, !loss_count(&period, 3))
	count: u64
	count, ended = loss_end(&period)
	testing.expect(t, ended)
	testing.expect_value(t, count, 5)
	_, ended = loss_end(&period)
	testing.expect(t, !ended)
	testing.expect(t, loss_count(&period))
	count, _ = loss_end(&period)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, period.lost, 6)
}
