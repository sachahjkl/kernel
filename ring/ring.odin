// The ring: two queues of fixed records in shared memory (properties 4, 6).
//
// A ring is two pages. The first page is the queue of command records, the
// second page is the queue of completion records. One side writes a queue and
// the other side reads it. No queue operation enters the kernel.
// The same format is used between two programs and between a program and
// the kernel.
package ring

import "base:intrinsics"

CAPACITY :: 32 // Records in one queue. A power of two.
PAGE_COUNT :: 2

Record :: struct {
	kind:   u32,
	tag:    u32,
	values: [7]u64,
}
#assert(size_of(Record) == 64)

// write and read count records since the start; the slot is the count modulo
// CAPACITY. A reader never trusts the two numbers of the other side.
Queue :: struct {
	write:    u32,
	read:     u32,
	reserved: [56]u8,
	records:  [63]Record,
}
#assert(size_of(Queue) == 4096)

Ring :: struct {
	commands:    Queue,
	completions: Queue,
}

push :: proc "contextless" (queue: ^Queue, record: Record) -> bool {
	write := intrinsics.volatile_load(&queue.write)
	if write - intrinsics.volatile_load(&queue.read) >= CAPACITY {
		return false
	}
	queue.records[write % CAPACITY] = record
	intrinsics.volatile_store(&queue.write, write + 1)
	return true
}

pop :: proc "contextless" (queue: ^Queue) -> (record: Record, ok: bool) {
	read := intrinsics.volatile_load(&queue.read)
	if intrinsics.volatile_load(&queue.write) == read {
		return {}, false
	}
	record = queue.records[read % CAPACITY]
	intrinsics.volatile_store(&queue.read, read + 1)
	return record, true
}

empty :: proc "contextless" (queue: ^Queue) -> bool {
	return intrinsics.volatile_load(&queue.write) == intrinsics.volatile_load(&queue.read)
}
