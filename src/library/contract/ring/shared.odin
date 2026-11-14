// The shared queue: one queue of fixed records that several threads write
// and several threads read, with no lock.
//
// A queue of a ring has one writer and one reader: use a ring when you
// can, one for each pair. Use a shared queue when several threads must
// take work from one place, or give results to one place.
//
// The memory of a shared queue:
//   page 0        the head: the counters (Shared_Head)
//   after it      one turn word for each record
//   after it      the records
//
// A turn word says whose turn it is on its record. With the place of the
// record, it gives a count: the count of the write that can use the record
// now, or 1 more than the count of the write that filled it. A writer
// takes a count with one compare-and-exchange on `write`, writes the
// record, then changes the turn word. A reader does the same with `read`.
// Two writers never have the same count, and a reader never reads a
// record before its writer completed it.
//
// Memory that is all zero is an empty shared queue. The capacity comes
// from the size of the memory.
//
// The threads of a shared queue work together. A thread that writes wrong
// numbers in the head or in the turn words cannot make another thread use
// memory out of the queue: each place is a count and the mask. It can make
// the other threads lose records or read the same record again.
package ring

import "base:intrinsics"

SHARED_CAPACITY :: 64 // The capacity of the smallest shared queue.
SHARED_CAPACITY_LIMIT :: 1 << 16 // The largest capacity that `shared_open` takes: 65536 records.
TURNS_IN_PAGE :: PAGE_SIZE / size_of(u32) // The turn words of one page: 1024.
RECORDS_IN_PAGE :: PAGE_SIZE / size_of(Record) // The records of one page: 64.
SHARED_TRIES :: 1 << 16 // The times that a thread tries to take a count before it gives up.

// The head of a shared queue. write and read count records since the
// start. A thread that waits for a record waits on `written`; a thread
// that waits for room waits on `taken`. See system/wait.odin.
//
// The writers change the first line of the cache, the readers the second.
// The third changes only when a thread waits: each thread reads it.
Shared_Head :: struct {
	write:        u32, // The count of the next write.
	written:      u32, // A writer adds 1 after each record that it completed.
	reserved_0:   [56]u8, // The rest of the line of the writers.
	read:         u32, // The count of the next read.
	taken:        u32, // A reader adds 1 after each record that it took.
	reserved_1:   [56]u8, // The rest of the line of the readers.
	readers:      Waiters, // The threads that wait for a record.
	writer_waits: u32, // 1: a thread waits, or will wait, for room.
	reserved_2:   [48]u8, // The rest of the third line.
}
#assert(size_of(Shared_Head) == 192)

// The threads that wait on one word, when one wake is for one thread.
Waiters :: struct {
	count: u32, // The threads that wait, or will wait.
	spins: u32, // The threads that read the word for a short time before they wait (system.wait_spin).
	wakes: u32, // 1: a thread got a wake and does not run yet. It clears the word when it runs.
}

// A shared queue that is mapped. head is nil for no queue. This record is
// not in the shared memory: each thread can have a copy.
Shared :: struct {
	head:    ^Shared_Head, // The shared head.
	turns:   [^]u32, // The turn words, from the second page: one for each record.
	records: [^]Record, // The records, after the pages of the turn words.
	mask:    u32, // The capacity - 1.
}

// shared_pages gives the pages of a shared queue with a capacity: the head,
// the pages of the turn words, and the pages of the records.
//
// Example: `shared_pages(64)` is 3: the head, one page of turn words, one
// page of records.
shared_pages :: proc "contextless" (capacity: u32) -> u64 {
	return 1 + (u64(capacity) + TURNS_IN_PAGE - 1) / TURNS_IN_PAGE + u64(capacity) / RECORDS_IN_PAGE
}

// shared_open gives the shared queue in mapped memory of page_count pages.
// false: no shared queue has this size: the count of pages is the count of
// `shared_pages` of no power of two from `SHARED_CAPACITY` to
// `SHARED_CAPACITY_LIMIT`.
shared_open :: proc "contextless" (memory: rawptr, page_count: u64) -> (queue: Shared, ok: bool) {
	if memory == nil {
		return {}, false
	}
	for capacity := u32(SHARED_CAPACITY); capacity <= SHARED_CAPACITY_LIMIT; capacity *= 2 {
		if shared_pages(capacity) == page_count {
			turn_pages := (uintptr(capacity) + TURNS_IN_PAGE - 1) / TURNS_IN_PAGE
			return {head = (^Shared_Head)(memory), turns = ([^]u32)(uintptr(memory) + PAGE_SIZE), records = ([^]Record)(uintptr(memory) + PAGE_SIZE * (1 + turn_pages)), mask = capacity - 1}, true
		}
	}
	return {}, false
}

// shared_capacity gives the records that a shared queue holds when it is
// full.
shared_capacity :: proc "contextless" (queue: ^Shared) -> u32 {
	return queue.mask + 1
}

// shared_count gives the records that wait in a shared queue. Other
// threads change it at the same time: it is right only for a moment.
shared_count :: proc "contextless" (queue: ^Shared) -> u32 {
	count := intrinsics.atomic_load_explicit(&queue.head.write, .Relaxed) - intrinsics.atomic_load_explicit(&queue.head.read, .Relaxed)
	return i32(count) < 0 ? 0 : min(count, queue.mask + 1)
}

// shared_push writes a record. false: the queue is full. It does not wake
// a reader: see system.shared_send.
shared_push :: proc "contextless" (queue: ^Shared, record: Record) -> bool {
	count := intrinsics.atomic_load(&queue.head.write)
	for _ in 0 ..< SHARED_TRIES {
		place := count & queue.mask
		turn := intrinsics.atomic_load_explicit(&queue.turns[place], .Acquire) + place
		if turn == count {
			// The record is free for this count. Take the count.
			old, ok := intrinsics.atomic_compare_exchange_weak(&queue.head.write, count, count + 1)
			if ok {
				queue.records[place] = record
				intrinsics.atomic_store_explicit(&queue.turns[place], count + 1 - place, .Release)
				return true
			}
			count = old
		} else if i32(turn - count) < 0 {
			return false // A reader did not take the record of one lap before.
		} else {
			count = intrinsics.atomic_load(&queue.head.write) // Another writer took the count.
		}
	}
	return false
}

// shared_pop reads a record. false: the queue is empty, or the writer of
// the next record did not complete it yet. It does not wake a writer: see
// system.shared_receive.
shared_pop :: proc "contextless" (queue: ^Shared) -> (record: Record, ok: bool) {
	count := intrinsics.atomic_load(&queue.head.read)
	for _ in 0 ..< SHARED_TRIES {
		place := count & queue.mask
		turn := intrinsics.atomic_load_explicit(&queue.turns[place], .Acquire) + place
		if turn == count + 1 {
			old, taken := intrinsics.atomic_compare_exchange_weak(&queue.head.read, count, count + 1)
			if taken {
				record = queue.records[place]
				// The record is free for the write of the next lap.
				intrinsics.atomic_store_explicit(&queue.turns[place], count + queue.mask + 1 - place, .Release)
				return record, true
			}
			count = old
		} else if i32(turn - (count + 1)) < 0 {
			return {}, false
		} else {
			count = intrinsics.atomic_load(&queue.head.read)
		}
	}
	return {}, false
}

// shared_ready says if a reader can read a record now.
shared_ready :: proc "contextless" (queue: ^Shared) -> bool {
	count := intrinsics.atomic_load(&queue.head.read)
	place := count & queue.mask
	return i32(intrinsics.atomic_load(&queue.turns[place]) + place - (count + 1)) >= 0
}

// shared_room says if a writer can write a record now.
shared_room :: proc "contextless" (queue: ^Shared) -> bool {
	count := intrinsics.atomic_load(&queue.head.write)
	place := count & queue.mask
	return i32(intrinsics.atomic_load(&queue.turns[place]) + place - count) >= 0
}
