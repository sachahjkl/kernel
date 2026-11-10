package system

import "base:intrinsics"

// A lock: one thread holds it at a time. The zero value is a free lock.
// It is one word of memory. A thread enters the kernel only to wait for a
// lock that another thread holds, and to wake a thread that waits.
// A lock in shared memory works between two programs.
Lock :: struct {
	state: u32, // 0: free. 1: held. 2: held, and a thread can wait.
	waits: u32, // The times that a thread waited. For measures only.
}

lock :: proc "contextless" (the_lock: ^Lock) {
	if _, ok := intrinsics.atomic_compare_exchange_strong(&the_lock.state, 0, 1); ok {
		return
	}
	for intrinsics.atomic_exchange(&the_lock.state, 2) != 0 {
		intrinsics.atomic_add(&the_lock.waits, 1)
		word_wait(&the_lock.state, 2)
	}
}

unlock :: proc "contextless" (the_lock: ^Lock) {
	if intrinsics.atomic_exchange(&the_lock.state, 0) == 2 {
		word_wake(&the_lock.state, 1)
	}
}
