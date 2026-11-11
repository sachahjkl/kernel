package kernel

import "base:intrinsics"
import op "contract:operation"

// The word wait (docs/ARCHITECTURE.md, "Locks of the kernel", "The word
// wait"). A thread that waits on a word has an entry in the bucket of the
// word: the physical address of the word chooses the bucket. The wait lock
// of a bucket protects its list of entries. Entry n of thread t is number
// t * WORD_WAIT_CAPACITY + n: its word is threads[t].words[n]. Thread 0 does
// not exist, so 0 is no entry.
//
// An entry has the wait serial of its thread at the time of the
// registration. The serial changes when the wait ends: an entry with an
// old serial is a leftover, and a waker does not count it.

WAIT_BUCKETS :: 64

Wait_Bucket :: struct #align (64) {
	lock: Lock,
	head: u32,
}

Wait_Link :: struct {
	next, previous: u32,
	serial:         u32,
}

wait_buckets: [WAIT_BUCKETS]Wait_Bucket
wait_links: [THREAD_TABLE_CAPACITY * op.WORD_WAIT_CAPACITY]Wait_Link

wait_bucket :: #force_inline proc "contextless" (word: u64) -> ^Wait_Bucket {
	return &wait_buckets[((word >> 2) * 0x9E37_79B9_7F4A_7C15) >> 58]
}

// wait_register adds the next word of the wait of a thread, if it holds
// the value: the comparison and the entry are one section of the wait lock.
// false: the word does not hold the value, and the thread does not wait.
// The caller makes sure that the page of the word stays (the program lock
// of the program, or the kernel lock).
wait_register :: proc "contextless" (thread: ^Thread, word: u64, value: u32) -> bool {
	index := thread_index(thread) * op.WORD_WAIT_CAPACITY + thread.word_count
	thread.words[thread.word_count] = word
	thread.word_count += 1
	bucket := wait_bucket(word)
	lock_take(&bucket.lock, .Wait)
	held := intrinsics.atomic_load(direct(word, u32)) == value
	link := &wait_links[index]
	link^ = {next = bucket.head, serial = intrinsics.atomic_load(&thread.wait_serial)}
	if bucket.head != 0 {
		wait_links[bucket.head].previous = index
	}
	bucket.head = index
	lock_free(&bucket.lock, .Wait)
	return held
}

// wait_unregister removes all the entries of a thread. The thread does not
// run on another processor: its processor calls this, or the thread ended.
wait_unregister :: proc "contextless" (thread: ^Thread) {
	first := thread_index(thread) * op.WORD_WAIT_CAPACITY
	for n in 0 ..< thread.word_count {
		index := first + n
		bucket := wait_bucket(thread.words[n])
		lock_take(&bucket.lock, .Wait)
		link := &wait_links[index]
		if link.previous != 0 {
			wait_links[link.previous].next = link.next
		} else {
			bucket.head = link.next
		}
		if link.next != 0 {
			wait_links[link.next].previous = link.previous
		}
		link^ = {}
		lock_free(&bucket.lock, .Wait)
	}
	thread.word_count = 0
}

// word_wake ends the wait of at most count threads that wait on a word. A
// thread that still registers its words in its own entry counts too: it
// does not wait, and reads its words again.
word_wake :: proc "contextless" (word: u64, count: u64) -> (woken: u64) {
	bucket := wait_bucket(word)
	lock_take(&bucket.lock, .Wait)
	for index := bucket.head; index != 0 && woken < count; index = wait_links[index].next {
		thread := &threads[index / op.WORD_WAIT_CAPACITY]
		if thread.words[index % op.WORD_WAIT_CAPACITY] == word && wait_entry_wake(thread, wait_links[index].serial) {
			woken += 1
		}
	}
	lock_free(&bucket.lock, .Wait)
	return woken
}

// wait_entry_wake ends the wait of a thread for one of its entries. true:
// the thread waited, or registers and will not wait.
@(private = "file")
wait_entry_wake :: proc "contextless" (thread: ^Thread, serial: u32) -> bool {
	home := run_lock(thread)
	counted, queued, preempts := false, false, false
	switch {
	case thread.wait_serial != serial:
	// A leftover of a wait that ended.
	case thread.state == .Waiting:
		queued, preempts = thread_ready_held(thread)
		counted = true
	case thread.state == .Ready && !thread.woken:
		thread.woken = true
		counted = true
	}
	run_unlock(home)
	if queued {
		kick(home, preempts)
	}
	return counted
}

// thread_words_wake ends the wait of a thread for its words, whatever its
// serial: a thread that waits becomes ready; a thread that registered its
// words and does not wait yet gets `woken`, and its wait_end does not wait.
// For a thread whose words name a frame that leaves its program (a
// decommit, a revocation): the caller holds the program lock of the thread,
// so no word is added meanwhile (a word is registered in the kernel entry,
// under that lock). The words can still be dropped at the start of the next
// entry of the thread (wait_begin), with no program lock: then the caller
// reads a word list that is ending, and at worst wakes a thread that waits
// no more, which only reads its words again. A thread that registers again
// later does it under the program lock, after the frames left, and finds
// the page not committed.
thread_words_wake :: proc "contextless" (thread: ^Thread) {
	home := run_lock(thread)
	queued, preempts := false, false
	switch {
	case thread.state == .Waiting:
		queued, preempts = thread_ready_held(thread)
	case thread.state == .Ready:
		thread.woken = true
	}
	run_unlock(home)
	if queued {
		kick(home, preempts)
	}
}

// wait_begin starts the registration of a kernel entry: the entries of the
// last wait leave the table.
wait_begin :: proc "contextless" (thread: ^Thread) {
	wait_unregister(thread)
	thread.woken = false
	thread.word_changed = false
}

// wait_end makes the thread wait, unless a word changed or a waker came
// during the registration. With no wait, the entries become leftovers.
wait_end :: proc "contextless" (thread: ^Thread, deadline: u64) {
	if deadline == 0 && thread.word_count == 0 {
		return // No wait and no entry: nothing for a waker to see.
	}
	home := run_lock(thread)
	if deadline != 0 && !thread.word_changed && !thread.woken {
		thread.state = .Waiting
		intrinsics.atomic_store(&thread.deadline, deadline)
	} else {
		intrinsics.atomic_add(&thread.wait_serial, 1)
	}
	run_unlock(home)
}
