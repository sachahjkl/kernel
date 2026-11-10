// The ring: two queues of fixed records in shared memory (properties 4, 6).
//
// One side writes the queue of command records and reads the queue of
// completion records. The other side does the opposite. A queue has one
// writer and one reader: no queue operation needs a lock, and none enters
// the kernel. The same format is used between two programs and between a
// program and the kernel.
//
// The memory of a ring:
//   page 0        the head: the counters of the two queues (Head)
//   after it      the command records, then the completion records
//
// The capacity of a ring is the count of records of each queue. It is a
// power of two, and it comes from the size of the memory: a ring of
// 1 + capacity / 32 pages. The capacity is not written in the shared
// memory: each side computes it from the size that the kernel gives. A ring
// does not change its capacity. Memory that is all zero is an empty ring.
//
// Choose the capacity for the largest burst of the writer. When a queue is
// full, the writer waits, drops the record, or refuses: a full queue slows
// the writer to the speed of the reader.
package ring

import "base:intrinsics"

CAPACITY :: 32 // The capacity of the smallest ring.
PAGE_COUNT :: 2 // The pages of the smallest ring.
CAPACITY_LIMIT :: 1 << 16
PAGE_SIZE :: 4096

Record :: struct {
	kind:   u32,
	tag:    u32,
	values: [7]u64,
}
#assert(size_of(Record) == 64)

// The counters of one queue. write and read count records since the start;
// the place of a record is its count modulo the capacity. A side never
// trusts the numbers of the other side.
//
// A side that waits for the other side waits on a counter (the word wait of
// the kernel): the reader on `write`, while the queue is empty; the writer
// on `read`, while the queue is full. Before it waits, it sets its `waits`
// word. The other side enters the kernel to wake it only if that word is
// set. The system library does this: see system/wait.odin.
//
// The writer changes the first line of the cache, the reader the second.
Counters :: struct {
	write:        u32,
	writer_waits: u32, // The writer waits, or will wait, for room.
	reserved_0:   [56]u8,
	read:         u32,
	reader_waits: u32, // The reader waits, or will wait, for a record.
	reserved_1:   [56]u8,
}
#assert(size_of(Counters) == 128)

Head :: struct {
	commands:    Counters,
	reserved_0:  [PAGE_SIZE / 2 - size_of(Counters)]u8,
	completions: Counters,
	reserved_1:  [PAGE_SIZE / 2 - size_of(Counters)]u8,
}
#assert(size_of(Head) == PAGE_SIZE)

// One queue, as one side sees it. This record is not in the shared memory:
// the mask comes from the size of the memory.
Queue :: struct {
	counters: ^Counters,
	records:  [^]Record,
	mask:     u32, // The capacity - 1.
}

// A ring that is mapped. head is nil for no ring.
Ring :: struct {
	head:        ^Head,
	commands:    Queue,
	completions: Queue,
}

// pages gives the pages of a ring with a capacity.
pages :: proc "contextless" (capacity: u32) -> u64 {
	return 1 + u64(capacity) / CAPACITY
}

// open gives the ring in mapped memory of page_count pages. false: no ring
// has this size.
open :: proc "contextless" (memory: rawptr, page_count: u64) -> (ring: Ring, ok: bool) {
	if memory == nil || page_count < PAGE_COUNT {
		return {}, false
	}
	capacity := (page_count - 1) * CAPACITY
	if capacity > CAPACITY_LIMIT || capacity & (capacity - 1) != 0 {
		return {}, false
	}
	head := (^Head)(memory)
	records := ([^]Record)(uintptr(memory) + PAGE_SIZE)
	return {head = head, commands = {&head.commands, records, u32(capacity) - 1}, completions = {&head.completions, records[capacity:], u32(capacity) - 1}}, true
}

capacity :: proc "contextless" (queue: ^Queue) -> u32 {
	return queue.mask + 1
}

// count gives the records that wait in a queue.
count :: proc "contextless" (queue: ^Queue) -> u32 {
	return min(intrinsics.volatile_load(&queue.counters.write) - intrinsics.volatile_load(&queue.counters.read), queue.mask + 1)
}

push :: proc "contextless" (queue: ^Queue, record: Record) -> bool {
	write := intrinsics.volatile_load(&queue.counters.write)
	if write - intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire) > queue.mask {
		return false
	}
	queue.records[write & queue.mask] = record
	// The other side, on another processor, sees the record before the count.
	intrinsics.atomic_store_explicit(&queue.counters.write, write + 1, .Release)
	return true
}

pop :: proc "contextless" (queue: ^Queue) -> (record: Record, ok: bool) {
	read := intrinsics.volatile_load(&queue.counters.read)
	if intrinsics.atomic_load_explicit(&queue.counters.write, .Acquire) == read {
		return {}, false
	}
	record = queue.records[read & queue.mask]
	intrinsics.atomic_store_explicit(&queue.counters.read, read + 1, .Release)
	return record, true
}

empty :: proc "contextless" (queue: ^Queue) -> bool {
	return intrinsics.volatile_load(&queue.counters.write) == intrinsics.volatile_load(&queue.counters.read)
}

// complete makes the last store of a counter complete in memory, as each
// processor sees it, before the thread reads another word. push and pop do
// not do it: it costs more than the store. A side does it before it reads
// the `waits` word of the other side.
complete :: proc "contextless" (counter: ^u32) {
	intrinsics.atomic_store_explicit(counter, intrinsics.volatile_load(counter), .Seq_Cst)
}
