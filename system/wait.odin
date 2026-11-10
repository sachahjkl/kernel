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
	other_flags: [op.WORD_WAIT_CAPACITY]^u32, // A queue: the `waits` word of the other side.
	other_words: [op.WORD_WAIT_CAPACITY]^u32, // A queue: the counter that the other side waits on.
	count:   int,
	flag_count: int, // The words that have a flag: wait_end adds one word for each.
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
wait_word :: proc "contextless" (wait: ^Wait, word: ^u32, value: u32, flag: ^u32 = nil, other_flag: ^u32 = nil, other_word: ^u32 = nil) {
	if wait.count + wait.flag_count + (flag != nil ? 2 : 1) > len(wait.words) {
		wait.full = true
		return
	}
	if flag != nil {
		wait.flag_count += 1
	}
	wait.words[wait.count] = {address = u64(uintptr(word)), value = u64(value)}
	wait.flags[wait.count] = flag
	wait.other_flags[wait.count] = other_flag
	wait.other_words[wait.count] = other_word
	wait.count += 1
}

// wait_records adds a queue that this thread reads: the thread waits while
// the queue is empty.
wait_records :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	counters := queue.counters
	wait_word(wait, &counters.write, intrinsics.volatile_load(&counters.read), &counters.reader_waits, &counters.writer_waits, &counters.read)
}

// wait_room adds a queue that this thread writes: the thread waits while
// the queue is full. The reader wakes it when half of the queue is free.
wait_room :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	counters := queue.counters
	wait_word(wait, &counters.read, intrinsics.volatile_load(&counters.write) - ring.capacity(queue), &counters.writer_waits, &counters.reader_waits, &counters.write)
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
	// A `waits` word is also a word of the wait: the thread waits while it
	// is 1. The other side sets it to 0 before each wake. A late wake, for
	// a record that this thread already read, can set it to 0 before this
	// thread waits: the wait then ends at once, and no later wake is lost.
	total := wait.count
	for index in 0 ..< wait.count {
		if flag := wait.flags[index]; flag != nil {
			intrinsics.atomic_store(flag, 1)
			wait.words[total] = {address = u64(uintptr(flag)), value = 1}
			total += 1
		}
		// This thread does nothing with the queue while it waits. If the
		// other side waits for this thread, it must continue now: a writer
		// that waits for half of the queue, or a reader that was not told
		// of the last records (ring.push with no wake_reader).
		if other := wait.other_flags[index]; other != nil && intrinsics.atomic_exchange(other, 0) != 0 {
			word_wake(wait.other_words[index], WAKE_ALL)
		}
	}
	// The kernel reads each word again: a record that arrived before the
	// `waits` word was set ends the wait at once.
	kernel := kernel_ring()
	ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&wait.words)), 1 = u64(total)}})
	now := system_enter(max(deadline, 1))
	ring.pop(&kernel.completions)
	// The thread does not wait now: the other side does not need to wake it.
	for index in 0 ..< wait.count {
		if flag := wait.flags[index]; flag != nil {
			intrinsics.atomic_store(flag, 0)
		}
	}
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
	wake_reader(queue)
	return true
}

// wake_reader wakes the reader of a queue if it waits. A thread that
// writes several records with ring.push calls it one time after the last
// record: one complete store for the group, in place of one for each
// record.
wake_reader :: proc "contextless" (queue: ^ring.Queue) {
	// The count is complete in memory before this thread reads the `waits`
	// word. If not, this thread can read "no wait" while the reader reads
	// the old count, and the reader then waits with no wake.
	ring.complete(&queue.counters.write)
	if intrinsics.atomic_load(&queue.counters.reader_waits) != 0 && intrinsics.atomic_exchange(&queue.counters.reader_waits, 0) != 0 {
		word_wake(&queue.counters.write, WAKE_ALL)
	}
}

// receive reads a record from a queue. If the writer waits for room, it
// wakes the writer when half of the queue is free: the writer then writes
// many records for one kernel entry.
//
// A writer waits only while the queue is full. From a full queue, the count
// of records passes each number: the reader looks at the `waits` word only
// when half of the queue is free, and before it waits itself (wait_end).
receive :: proc "contextless" (queue: ^ring.Queue) -> (record: ring.Record, ok: bool) {
	record = ring.pop(queue) or_return
	if ring.count(queue) == ring.capacity(queue) / 2 {
		ring.complete(&queue.counters.read) // See wake_reader.
		if intrinsics.atomic_load(&queue.counters.writer_waits) != 0 && intrinsics.atomic_exchange(&queue.counters.writer_waits, 0) != 0 {
			word_wake(&queue.counters.read, WAKE_ALL)
		}
	}
	return record, true
}
