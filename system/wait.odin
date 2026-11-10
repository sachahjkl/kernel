package system

import op "../kernel/operation"
import "../ring"
import "base:intrinsics"

// The wait: the one way for a thread to wait for something else than a
// time. A thread waits while each word of a list holds a value. The words
// are the counters of ring queues, the event word of the thread, and the
// words of the program itself (a lock).
//
//   for {
//       wait := system.wait_begin()       // Reads the event word.
//       system.wait_records(&wait, queue) // The thread waits while the queue is empty.
//       ... read the queues, read the state ...
//       system.wait_end(&wait, deadline)
//   }
//
// If a word changes after the thread reads it and before the thread waits,
// the wait ends at once: no wake is lost.

WAKE_ALL :: max(u64)

Wait :: struct {
	words: [op.WORD_WAIT_CAPACITY]op.Word,
	count: int,
	full:  bool, // A word did not fit: the wait ends at once.
}

// events gives the address of the event word of the thread that runs. The
// kernel adds 1 to it when an interrupt of the program arrives, when a
// program that this program holds stops, and when another thread ends.
events :: proc "contextless" () -> ^u32 {
	return &thread_record().events
}

// wait_begin starts a list with the event word. Call it before the thread
// reads the state that an event changes.
wait_begin :: proc "contextless" () -> (wait: Wait) {
	word := events()
	wait_word(&wait, word, intrinsics.volatile_load(word))
	return wait
}

// wait_word adds a word: the thread waits while the word holds value.
// word_wake ends the wait.
wait_word :: proc "contextless" (wait: ^Wait, word: ^u32, value: u32) {
	if wait.count == len(wait.words) {
		wait.full = true
		return
	}
	wait.words[wait.count] = {address = u64(uintptr(word)), value = u64(value)}
	wait.count += 1
}

// wait_records adds a queue that this thread reads: the thread waits while
// the queue is empty.
wait_records :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	intrinsics.atomic_store(&queue.reader_waits, 1)
	wait_word(wait, &queue.write, intrinsics.volatile_load(&queue.read))
}

// wait_room adds a queue that this thread writes: the thread waits while
// the queue is full.
wait_room :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	intrinsics.atomic_store(&queue.writer_waits, 1)
	wait_word(wait, &queue.read, intrinsics.volatile_load(&queue.write) - ring.CAPACITY)
}

// wait_end stops the thread while each word holds its value, or until the
// time is deadline. It gives the time.
wait_end :: proc "contextless" (wait: ^Wait, deadline: u64 = WAIT_FOREVER) -> u64 {
	if wait.full {
		return time()
	}
	ring.push(&kernel_ring().commands, ring.Record{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&wait.words)), 1 = u64(wait.count)}})
	now := system_enter(max(deadline, 1))
	ring.pop(&kernel_ring().completions)
	return now
}

// word_wait stops the thread while the word holds value, until word_wake
// names the word or until the time is deadline. It gives the time.
// The word can be in memory that another program maps.
// Read the word again after the wait: the deadline also ends it.
word_wait :: proc "contextless" (word: ^u32, value: u32, deadline: u64 = WAIT_FOREVER) -> u64 {
	wait: Wait
	wait_word(&wait, word, value)
	return wait_end(&wait, deadline)
}

// word_wake wakes at most count threads that wait on the word. It gives
// the number of threads that it woke.
word_wake :: proc "contextless" (word: ^u32, count: u64 = 1) -> u64 {
	results, _ := call(.Word_Wake, u64(uintptr(word)), count)
	return results[0]
}

// send writes a record in a queue, and wakes the reader if it waits. It
// enters the kernel only for that wake. false: the queue is full.
send :: proc "contextless" (queue: ^ring.Queue, record: ring.Record) -> bool {
	ring.push(queue, record) or_return
	if intrinsics.atomic_exchange(&queue.reader_waits, 0) != 0 {
		word_wake(&queue.write, WAKE_ALL)
	}
	return true
}

// receive reads a record from a queue, and wakes the writer if it waits
// for room.
receive :: proc "contextless" (queue: ^ring.Queue) -> (record: ring.Record, ok: bool) {
	record = ring.pop(queue) or_return
	if intrinsics.atomic_exchange(&queue.writer_waits, 0) != 0 {
		word_wake(&queue.read, WAKE_ALL)
	}
	return record, true
}
