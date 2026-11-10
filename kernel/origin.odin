package kernel

import "base:intrinsics"
import "contract:errors"

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

origins: [PROGRAM_CAPACITY * HOLDINGS_PER_PROGRAM]Origin_Link
program_stops: u64 // The stops of programs: a stop ends many holdings.
revoke_lost: u64 // Bit n: Handle_Revoke ended a holding of program n.
#assert(PROGRAM_CAPACITY <= 64)

holding_of_handle :: proc "contextless" (program: ^Program, slot: ^Handle_Slot) -> Holding {
	return Holding(intrinsics.ptr_sub(program, &programs[0])) << 8 | Holding(intrinsics.ptr_sub(slot, &program.handles[0]))
}

holding_of_mapping :: proc "contextless" (program: ^Program, mapping: ^Mapping) -> Holding {
	return Holding(intrinsics.ptr_sub(program, &programs[0])) << 8 | Holding(HANDLE_CAPACITY + intrinsics.ptr_sub(mapping, &program.mappings[0]))
}

// origin_attach says that a holding came from a handle. The holding is in
// no list.
origin_attach :: proc "contextless" (holding: Holding, origin: Holding) {
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

// origin_detach takes a holding that ends out of the tree. What came from
// it now comes from its origin.
origin_detach :: proc "contextless" (holding: Holding) {
	link := &origins[holding]
	for child := link.first; child != 0; {
		next := origins[child].next
		origin_attach(child, link.origin)
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
	for at := origin_next(top, top); at != 0; at = origin_next(top, at) {
		count += 1
	}
	return count
}

// A mapping in the program that revokes stays: a program does not remove
// its own memory when it takes back what it gave.
@(private = "file")
stays :: proc "contextless" (holding: Holding, caller: u32) -> bool {
	return u32(holding >> 8) == caller && holding & 0xFF >= HANDLE_CAPACITY
}

// holding_end closes a handle or removes a mapping, for Handle_Revoke. A
// thread that waits on a word of the memory wakes: it does not wait for a
// wake that cannot come.
@(private = "file")
holding_end :: proc "contextless" (holding: Holding) -> bool {
	index := u32(holding >> 8)
	program := &programs[index]
	n := holding & 0xFF
	if n < HANDLE_CAPACITY {
		slot := &program.handles[n]
		if slot.kind == .None {
			return false
		}
		handle_close(program, slot)
		slot.ended = u8(errors.End.Revoked)
	} else {
		mapping := &program.mappings[n - HANDLE_CAPACITY]
		if mapping.page_count == 0 {
			return false
		}
		// Before the unmap: the unmap can end the memory object and free its
		// frames. A thread that becomes ready runs after the kernel lock is
		// free, so after the unmap.
		region := &regions[mapping.region]
		for &thread in threads[1:] {
			if thread.program != index || thread.state != .Waiting {
				continue
			}
			for word in thread.words[:thread.word_count] {
				if region_has_frame(region, word &~ (PAGE_SIZE - 1)) {
					thread_ready(&thread)
					break
				}
			}
		}
		unmap(program, mapping)
	}
	revoke_lost |= 1 << index
	return true
}

// revoke_under ends a holding and each holding that came from it, the last
// ones first. A close can stop a program, and that stop ends holdings
// anywhere in the tree: then the walk starts again from the top.
@(private = "file")
revoke_under :: proc "contextless" (top: Holding, caller: u32) -> (count: u64) {
	cursor := top
	for {
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
		stops := program_stops
		if holding_end(cursor) {
			count += 1
		}
		if last {
			return count
		}
		cursor = stops == program_stops ? origin : top
	}
}

// revoke ends each holding that came from a handle: in one program
// (only != 0), or in each program. A holding that ends takes with it what
// came from it, in any program. The handle stays.
revoke :: proc "contextless" (top: Holding, caller: u32, only: u32) -> (count: u64) {
	revoke_lost = 0
	for {
		found: Holding
		for at := origin_next(top, top); at != 0; at = origin_next(top, at) {
			if !stays(at, caller) && (only == 0 || u32(at >> 8) == only) {
				found = at
				break
			}
		}
		if found == 0 {
			break
		}
		count += revoke_under(found, caller)
	}
	// Each program that lost a holding gets an event.
	for index in 1 ..< u32(PROGRAM_CAPACITY) {
		if revoke_lost & (1 << index) != 0 && index != caller {
			program_event(index)
		}
	}
	return count
}
