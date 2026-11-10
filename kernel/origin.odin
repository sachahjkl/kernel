package kernel

import "base:intrinsics"

// The origin tree: what came from which handle (property 13).
//
// A holding is a handle or a mapping of a program. The origin of a holding
// is the handle that it came from:
//   a handle that Handle_Give made: the handle that was given;
//   a mapping that Memory_Map made: the memory handle that was mapped.
// A holding that the kernel made, or the handle of a new object, has no
// origin. When a handle closes, what came from it now comes from its own
// origin: a program that closes a handle does not hide what it passed on.
// Handle_Revoke ends each holding that came from a handle.
//
// The tree is one flat table of links. Holding number = program slot * 256
// + n. n < 128: handle slot n. n >= 128: mapping slot n - 128. 0: none.
// Each change is a constant number of writes: a holding is in the list of
// the holdings of its origin, with a link in each direction.
HOLDINGS_PER_PROGRAM :: 256
#assert(HANDLE_CAPACITY == 128 && MAPPING_CAPACITY == 128)
#assert(PROGRAM_CAPACITY * HOLDINGS_PER_PROGRAM <= 65536)

Holding :: u16

Origin_Link :: struct {
	origin:   Holding,
	first:    Holding, // The first holding that came from this one.
	next:     Holding, // In the list of the holdings of `origin`.
	previous: Holding,
}

// The origin lock protects `origins`, `origin_changes` and `revoking`. The
// link of a holding changes under the origin lock; a path that ends a
// holding also holds the program lock of the holder.
origin_lock: Lock
origins: [PROGRAM_CAPACITY * HOLDINGS_PER_PROGRAM]Origin_Link
origin_changes: u64 // Detaches since boot: a revocation sees that another processor changed the tree.
revoking: bool // A revocation lists and ends holdings: a path with no control lock adds none.
revoke_lost: u64 // Bit n: Handle_Revoke ended a holding of program n. Control lock.
#assert(PROGRAM_CAPACITY <= 64)

holding_of_handle :: proc "contextless" (program: ^Program, slot: ^Handle_Slot) -> Holding {
	return Holding(intrinsics.ptr_sub(program, &programs[0])) << 8 | Holding(intrinsics.ptr_sub(slot, &program.handles[0]))
}

holding_of_mapping :: proc "contextless" (program: ^Program, mapping: ^Mapping) -> Holding {
	return Holding(intrinsics.ptr_sub(program, &programs[0])) << 8 | Holding(HANDLE_CAPACITY + intrinsics.ptr_sub(mapping, &program.mappings[0]))
}

// origin_attach says that a holding came from a handle. The holding is in
// no list. false: a revocation runs and the caller has no control lock;
// nothing changed, and the caller runs again with the control lock.
origin_attach :: proc "contextless" (holding: Holding, origin: Holding) -> bool {
	if origin == 0 {
		return true // The link of a holding that ends is zero: it stays so.
	}
	lock_take(&origin_lock, .Origin)
	defer lock_free(&origin_lock, .Origin)
	if revoking && !processor_self().control {
		return false
	}
	link := &origins[holding]
	link.origin, link.previous = origin, 0
	link.next = origins[origin].first
	if link.next != 0 {
		origins[link.next].previous = holding
	}
	origins[origin].first = holding
	return true
}

// origin_detach takes a holding that ends out of the tree. What came from
// it now comes from its origin. The caller holds the program lock of the
// holder: then a link that is zero stays zero (only that program adds a
// holding below this one, and a holding with no origin gets none), and the
// origin lock is not needed.
origin_detach :: proc "contextless" (holding: Holding) {
	link := &origins[holding]
	if intrinsics.atomic_load(&link.first) == 0 && intrinsics.atomic_load(&link.origin) == 0 {
		return
	}
	lock_take(&origin_lock, .Origin)
	defer lock_free(&origin_lock, .Origin)
	origin_changes += 1
	for child := link.first; child != 0; {
		next := origins[child].next
		reattach(child, link.origin)
		child = next
	}
	if link.previous != 0 {
		origins[link.previous].next = link.next
	} else if link.origin != 0 {
		origins[link.origin].first = link.next
	}
	if link.next != 0 {
		origins[link.next].previous = link.previous
	}
	link^ = {}
}

// reattach moves a holding to the list of another origin. The caller holds
// the origin lock.
@(private = "file")
reattach :: proc "contextless" (holding: Holding, origin: Holding) {
	link := &origins[holding]
	link.origin, link.previous, link.next = origin, 0, 0
	if origin == 0 {
		return
	}
	link.next = origins[origin].first
	if link.next != 0 {
		origins[link.next].previous = holding
	}
	origins[origin].first = holding
}

// origin_next gives the holding after `holding` in the holdings that came
// from `top`, each one after its origin. 0: no more.
origin_next :: proc "contextless" (top: Holding, holding: Holding) -> Holding {
	if origins[holding].first != 0 {
		return origins[holding].first
	}
	for at := holding; at != top && at != 0; at = origins[at].origin {
		if origins[at].next != 0 {
			return origins[at].next
		}
	}
	return 0
}

// origin_count gives the count of the holdings that came from a handle.
origin_count :: proc "contextless" (top: Holding) -> (count: u64) {
	lock_take(&origin_lock, .Origin)
	for at := origin_next(top, top); at != 0; at = origin_next(top, at) {
		count += 1
	}
	lock_free(&origin_lock, .Origin)
	return count
}

// A mapping in the program that revokes stays: a program does not remove
// its own memory when it takes back what it gave.
@(private = "file")
stays :: proc "contextless" (holding: Holding, caller: u32) -> bool {
	return u32(holding >> 8) == caller && holding & 0xFF >= HANDLE_CAPACITY
}

// holding_end closes a handle or removes a mapping, for Handle_Revoke. The
// caller holds the control lock. `changes` is origin_changes when the caller
// read the tree: if another processor changed the tree since, the holding
// can be another one now, and nothing ends (false, restart).
End :: enum {
	Ended, // The holding ended.
	Gone, // The holding was not there any more.
	Changed, // Another processor changed the tree: nothing ended.
}

@(private = "file")
holding_end :: proc "contextless" (holding: Holding, changes: u64) -> End {
	index := u32(holding >> 8)
	program := &programs[index]
	taken := program_lock(index)
	defer program_unlock(index, taken)
	lock_take(&origin_lock, .Origin)
	same := origin_changes == changes
	lock_free(&origin_lock, .Origin)
	if !same {
		return .Changed
	}
	n := holding & 0xFF
	if n < HANDLE_CAPACITY {
		slot := &program.handles[n]
		if slot.kind == .None {
			return .Gone
		}
		handle_close(program, slot)
	} else {
		mapping := &program.mappings[n - HANDLE_CAPACITY]
		if mapping.page_count == 0 {
			return .Gone
		}
		// Before the unmap: the unmap can end the memory object and free its
		// frames. A thread that waits on a word of it wakes; it runs again
		// after the unmap, under this program lock.
		region := &regions[mapping.region]
		for &thread in threads[1:] {
			if thread.program != index || intrinsics.atomic_load(&thread.state) != .Waiting {
				continue
			}
			for word in thread.words[:thread.word_count] {
				if region_has_frame(region, word &~ (PAGE_SIZE - 1)) {
					thread_wake(&thread)
					break
				}
			}
		}
		unmap(program, mapping)
	}
	revoke_lost |= 1 << index
	return .Ended
}

// revoke_under ends a holding and each holding that came from it, the last
// ones first. `changes` is origin_changes when the caller chose `top`: if
// another processor changed the tree since (a program closed a holding, and
// its slot can hold a new handle now), nothing more ends here, and the
// caller looks again from its own handle (restart). It does not loop for
// ever: during the revocation no holding is added to the tree, so each
// change removes one holding.
@(private = "file")
revoke_under :: proc "contextless" (top: Holding, caller: u32, changes: u64) -> (count: u64) {
	changes := changes
	cursor := top
	for {
		lock_take(&origin_lock, .Origin)
		if origin_changes != changes {
			lock_free(&origin_lock, .Origin)
			return count
		}
		for {
			child := origins[cursor].first
			for child != 0 && stays(child, caller) {
				child = origins[child].next
			}
			if child == 0 {
				break
			}
			cursor = child
		}
		origin := origins[cursor].origin
		last := cursor == top
		lock_free(&origin_lock, .Origin)
		if holding_end(cursor, changes) != .Ended {
			return count
		}
		count += 1
		changes += 1 // The end of this holding is one change: its detach.
		if last {
			return count
		}
		cursor = origin
	}
}

// revoke ends each holding that came from a handle: in one program
// (only != 0), or in each program. A holding that ends takes with it what
// came from it, in any program. The handle stays. The caller holds the
// control lock.
revoke :: proc "contextless" (top: Holding, caller: u32, only: u32) -> (count: u64) {
	revoke_lost = 0
	lock_take(&origin_lock, .Origin)
	revoking = true
	lock_free(&origin_lock, .Origin)
	for {
		found: Holding
		lock_take(&origin_lock, .Origin)
		for at := origin_next(top, top); at != 0; at = origin_next(top, at) {
			if !stays(at, caller) && (only == 0 || u32(at >> 8) == only) {
				found = at
				break
			}
		}
		changes := origin_changes
		lock_free(&origin_lock, .Origin)
		if found == 0 {
			break
		}
		count += revoke_under(found, caller, changes)
	}
	lock_take(&origin_lock, .Origin)
	revoking = false
	lock_free(&origin_lock, .Origin)
	// Each program that lost a holding gets an event.
	for index in 1 ..< u32(PROGRAM_CAPACITY) {
		if revoke_lost & (1 << index) != 0 && index != caller {
			program_event(index)
		}
	}
	return count
}
