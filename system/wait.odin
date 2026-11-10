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
	words:   [op.WORD_WAIT_CAPACITY]op.Word,
	flags:   [op.WORD_WAIT_CAPACITY]^u32, // The `waits` word of a queue: wait_end sets it.
	readers: [op.WORD_WAIT_CAPACITY]^ring.Counters, // A queue that this thread reads.
	count:   int,
	full:    bool, // A word did not fit: the wait ends at once.
}

SPIN_COUNT :: 400 // The times that wait_spin reads the words: some microseconds.

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
wait_word :: proc "contextless" (wait: ^Wait, word: ^u32, value: u32, flag: ^u32 = nil, reader: ^ring.Counters = nil) {
	if wait.count == len(wait.words) {
		wait.full = true
		return
	}
	wait.words[wait.count] = {address = u64(uintptr(word)), value = u64(value)}
	wait.flags[wait.count] = flag
	wait.readers[wait.count] = reader
	wait.count += 1
}

// wait_records adds a queue that this thread reads: the thread waits while
// the queue is empty.
wait_records :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	counters := queue.counters
	wait_word(wait, &counters.write, intrinsics.volatile_load(&counters.read), &counters.reader_waits, counters)
}

// wait_room adds a queue that this thread writes: the thread waits while
// the queue is full. The reader wakes it when half of the queue is free.
wait_room :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	counters := queue.counters
	wait_word(wait, &counters.read, intrinsics.volatile_load(&counters.write) - ring.capacity(queue), &counters.writer_waits)
}

// wait_spin reads the words of the list for a short time, with no kernel
// entry. true: a word changed, the thread does not need to wait. Call it
// before wait_end when the other side answers in less time than a kernel
// entry takes: the other side then does not enter the kernel to wake this
// thread. With one processor it gives false at once.
wait_spin :: proc "contextless" (wait: ^Wait) -> bool {
	if wait.full {
		return true
	}
	if thread_record().processors < 2 {
		return false
	}
	for _ in 0 ..< SPIN_COUNT {
		for word in wait.words[:wait.count] {
			if intrinsics.volatile_load((^u32)(uintptr(word.address))) != u32(word.value) {
				return true
			}
		}
		intrinsics.cpu_relax()
	}
	return false
}

// wait_end stops the thread while each word holds its value, or until the
// time is deadline. It gives the time.
wait_end :: proc "contextless" (wait: ^Wait, deadline: u64 = WAIT_FOREVER) -> u64 {
	if wait.full {
		return time()
	}
	for index in 0 ..< wait.count {
		if flag := wait.flags[index]; flag != nil {
			intrinsics.atomic_store(flag, 1)
		}
		// This thread reads no record while it waits: a writer that waits
		// for half of the queue must continue now.
		if reader := wait.readers[index]; reader != nil && intrinsics.atomic_exchange(&reader.writer_waits, 0) != 0 {
			word_wake(&reader.read, WAKE_ALL)
		}
	}
	// The kernel reads each word again: a record that arrived before the
	// `waits` word was set ends the wait at once.
	kernel := kernel_ring()
	ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&wait.words)), 1 = u64(wait.count)}})
	now := system_enter(max(deadline, 1))
	ring.pop(&kernel.completions)
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
	if intrinsics.atomic_load(&queue.counters.reader_waits) != 0 && intrinsics.atomic_exchange(&queue.counters.reader_waits, 0) != 0 {
		word_wake(&queue.counters.write, WAKE_ALL)
	}
	return true
}

// receive reads a record from a queue. If the writer waits for room, it
// wakes the writer when half of the queue is free: the writer then writes
// many records for one kernel entry.
receive :: proc "contextless" (queue: ^ring.Queue) -> (record: ring.Record, ok: bool) {
	record = ring.pop(queue) or_return
	if intrinsics.atomic_load(&queue.counters.writer_waits) != 0 && ring.count(queue) <= ring.capacity(queue) / 2 && intrinsics.atomic_exchange(&queue.counters.writer_waits, 0) != 0 {
		word_wake(&queue.counters.read, WAKE_ALL)
	}
	return record, true
}
