package kernel

import "base:intrinsics"
import op "contract:operation"

// The virtual memory of a program (docs/ARCHITECTURE.md, "The virtual
// memory of a program"): commit and decommit the pages of an uncommitted
// object, and change the protection of pages. The caller holds the program
// lock of the program.

// object_only_here says if a memory object is named only by this program,
// with one mapping at most: its pages have page table entries only in this
// program. It gives that mapping, or nil when it has none. The references of the object are the handles and
// the mappings of all programs; under the program lock the handles and the
// mappings of this program do not change, and another program that names
// the object holds a reference.
object_only_here :: proc "contextless" (program: ^Program, region_index: u32) -> (found: ^Mapping, alone: bool) {
	own: u32
	mappings: u32
	for &mapping in program.mappings {
		if mapping.page_count != 0 && mapping.region == region_index {
			mappings += 1
			found = &mapping
		}
	}
	for slot in program.handles {
		if slot.kind == .Memory && slot.object == region_index {
			own += 1
		}
	}
	// At most one mapping: the decommit of an object that this program holds
	// with no mapping has no entry to clear.
	if mappings > 1 || intrinsics.atomic_load(&regions[region_index].references) != own + mappings {
		return nil, false
	}
	return found, true
}

// ranges_valid says if a table of page ranges is in an object of page_count
// pages, in increasing order, with no overlap.
ranges_valid :: proc "contextless" (ranges: []op.Page_Range, page_count: u64) -> bool {
	end: u64
	for range in ranges {
		if range.page_count == 0 || range.first >= page_count || range.page_count > page_count - range.first || range.first < end {
			return false
		}
		end = range.first + range.page_count
	}
	return true
}

// table_pages gives the pages of a table of ranges, at most the limit plus
// one: a table above op.RANGE_TABLE_PAGE_LIMIT is refused (the
// sections of one call walk each page with interrupts off).
table_pages :: proc "contextless" (counts: []u64) -> (sum: u64) {
	for count in counts {
		sum += min(count, op.RANGE_TABLE_PAGE_LIMIT + 1)
		if sum > op.RANGE_TABLE_PAGE_LIMIT {
			return op.RANGE_TABLE_PAGE_LIMIT + 1
		}
	}
	return sum
}

// memory_commit commits, or decommits, the pages of the ranges of an
// uncommitted object. It gives the pages that changed.
//
// Commit: one section of the region lock and the frame lock for the table:
// the budget of the object pays one page for each page that was not
// committed, reserved_pages grows by as much, the bits are set. A budget
// that cannot pay the table changes nothing.
//
// Decommit: the object must be named only by this program, with one
// mapping. First, under the region lock, the present entries of the pages
// are cleared and each processor that uses the page table of the program
// forgets them (one processor_sync for the table): no processor can reach a
// frame of the table after. Then, in one section of the frame lock and the
// cache lock of this processor: each frame goes to the frame cache, each
// committed page with no frame leaves reserved_pages, the budget receives
// one page for each page, the slots keep only their protection. The program
// lock keeps the faults of the program out between the two steps (a fault
// takes it).
memory_commit :: proc "contextless" (program: ^Program, region_index: u32, ranges: []op.Page_Range, decommit: bool) -> (changed: u64, status: op.Status) {
	region := &regions[region_index]
	if !region.uncommitted {
		return 0, .Bad_Operation
	}
	if !ranges_valid(ranges, region.page_count) {
		return 0, .Bad_Address
	}
	region_lock := &region_locks[region_index]
	if !decommit {
		lock_take(region_lock, .Region)
		defer lock_free(region_lock, .Region)
		needed: u64
		for range in ranges {
			for page in range.first ..< range.first + range.page_count {
				needed += 1 - intrinsics.atomic_load(region_slot(region, page)) & SLOT_COMMITTED
			}
		}
		lock_take(&frame_lock, .Frame)
		defer lock_free(&frame_lock, .Frame)
		budget := &budgets[region.budget]
		if !budget.live || budget.amounts.pages < needed {
			return 0, .No_Budget
		}
		budget.amounts.pages -= needed
		reserved_pages += needed
		region.committed += needed
		for range in ranges {
			for page in range.first ..< range.first + range.page_count {
				slot := region_slot(region, page)
				intrinsics.atomic_store(slot, intrinsics.atomic_load(slot) | SLOT_COMMITTED)
			}
		}
		return needed, .Ok
	}
	mapping, alone := object_only_here(program, region_index)
	if !alone {
		return 0, .Bad_State
	}
	lock_take(region_lock, .Region)
	defer lock_free(region_lock, .Region)
	self := processor_self()
	for range in ranges {
		for page in range.first ..< range.first + range.page_count {
			if mapping == nil || page < mapping.first || page - mapping.first >= mapping.page_count {
				continue // Not in the mapping: no entry.
			}
			address := mapping.address + (page - mapping.first) * PAGE_SIZE
			if entry := page_entry(program.table, address); entry != nil && entry^ & PAGE_PRESENT != 0 {
				entry^ = 0
				mapping.present_page_count -= 1
				if self.table == program.table {
					page_flush(address)
				}
			}
		}
	}
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(program.table))
	// A thread of the program that waits on a word of a page whose frame
	// returns wakes now, before the frame can serve another program: its
	// wait names the frame, so a later wake through a new frame of the page
	// would not reach it, and a wake by the next user of the frame would.
	// Only this program names the object, and the program lock keeps its
	// threads from a new wait meanwhile. It runs again and reads its words.
	waiters_on_frames_wake(program, region, ranges)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	cache := &self.frame_cache
	lock_take(&cache.lock, .Cache)
	defer lock_free(&cache.lock, .Cache)
	for range in ranges {
		for page in range.first ..< range.first + range.page_count {
			slot := region_slot(region, page)
			value := intrinsics.atomic_load(slot)
			if value & SLOT_COMMITTED == 0 {
				continue
			}
			if frame := value & PAGE_ADDRESS; frame != 0 {
				cache_put_held(cache, frame)
				region.present -= 1
			} else {
				reserved_pages -= 1
			}
			intrinsics.atomic_store(slot, value & (SLOT_STATE &~ SLOT_COMMITTED))
			changed += 1
		}
	}
	budgets[region.budget].amounts.pages += changed
	region.committed -= changed
	return changed, .Ok
}

// waiters_on_frames_wake wakes each thread of a program that has a word
// in a frame of the pages of the ranges of a memory object: a thread that
// waits, or one that registered its words and does not wait yet. A decommit
// and a revocation call it before the frames leave the program. The caller
// holds the program lock of the program, so the words of its threads do
// not grow meanwhile. A thread with more words than this table holds wakes
// anyway: a wake that was not needed is allowed (the thread reads its words
// again).
//
// The cost: the words (at most 256) are sorted once; then the slots of the
// pages are read in order, with one binary search for each slot that has a
// frame, and the walk ends when each word is matched or when it has seen
// each frame of the object (`present`). So an object of 1 GiB with few
// frames is not walked to its end, unless its last page has a frame: then
// one pass over its 262 144 slots, 2 MiB read in order.
WAITING_WORD_CAPACITY :: 256

waiters_on_frames_wake :: proc "contextless" (program: ^Program, region: ^Region, ranges: []op.Page_Range) {
	Waiting_Word :: struct {
		page:   u64, // The frame of the word.
		thread: u32,
	}
	words: [WAITING_WORD_CAPACITY]Waiting_Word
	count := 0
	index := index_of_program(program)
	for &thread, slot in threads[1:] {
		if thread.program != index || thread.word_count == 0 {
			continue
		}
		if count + int(thread.word_count) > WAITING_WORD_CAPACITY {
			thread_words_wake(&thread)
			continue
		}
		for word in thread.words[:thread.word_count] {
			words[count] = {page = word &~ (PAGE_SIZE - 1), thread = u32(slot + 1)}
			count += 1
		}
	}
	if count == 0 {
		return
	}
	for at in 1 ..< count {
		for back := at; back > 0 && words[back - 1].page > words[back].page; back -= 1 {
			words[back - 1], words[back] = words[back], words[back - 1]
		}
	}
	remaining := count
	frames_seen: u64
	frames := intrinsics.atomic_load(&region.present)
	for range in ranges {
		for page in range.first ..< range.first + range.page_count {
			frame := region.contiguous ? region.physical + page * PAGE_SIZE : intrinsics.atomic_load(region_slot(region, page)) & PAGE_ADDRESS
			if frame == 0 {
				continue
			}
			frames_seen += 1
			low, high := 0, count
			for low < high {
				middle := (low + high) / 2
				if words[middle].page < frame {
					low = middle + 1
				} else {
					high = middle
				}
			}
			for at := low; at < count && words[at].page == frame; at += 1 {
				if words[at].thread != 0 {
					thread_words_wake(&threads[words[at].thread])
					words[at].thread = 0
					remaining -= 1
				}
			}
			if remaining == 0 || !region.contiguous && frames_seen >= frames {
				return
			}
		}
	}
}


// protection_bits gives the bits of the mappings of a protection.
protection_bits :: proc "contextless" (mapping: ^Mapping, flags: op.Map_Flags) -> u64 {
	if .No_Access in flags {
		return 0
	}
	bits := PAGE_PRESENT | PAGE_USER | mapping.limit_bits & PAGE_NO_CACHE
	if .Write in flags {
		bits |= PAGE_WRITE
	}
	if .Execute not_in flags {
		bits |= PAGE_NO_EXECUTE
	}
	return bits
}

// protect_check finds the mapping of each range and checks what the
// protection asks, before any change: a table is done whole or not at all.
// A range covers the pages of one mapping of this program; Write needs a
// mapping made with Write, Execute one made with Execute; a part of a
// mapping needs an object with a frame list named only by this program.
protect_check :: proc "contextless" (program: ^Program, ranges: []op.Address_Range, flags: op.Map_Flags) -> (mappings: [op.RANGE_TABLE_CAPACITY]u8, status: op.Status) {
	if .Write in flags && .Execute in flags || .No_Access in flags && flags != {.No_Access} {
		return mappings, .Bad_Operation
	}
	for range, index in ranges {
		address, count := range.address, range.page_count
		if address % PAGE_SIZE != 0 || count == 0 || address >= USER_END || count > (USER_END - address) / PAGE_SIZE {
			return mappings, .Bad_Address
		}
		found := -1
		for &mapping, slot in program.mappings {
			if mapping.page_count != 0 && address >= mapping.address && (address - mapping.address) / PAGE_SIZE + count <= mapping.page_count {
				found = slot
				break
			}
		}
		if found < 0 {
			return mappings, .Bad_Address
		}
		mapping := &program.mappings[found]
		if mapping.address >= op.THREAD_AREA_BASE {
			return mappings, .Bad_Address // The thread areas and the time page keep their protection.
		}
		// More than the handle permitted when the program mapped the object.
		if .Write in flags && mapping.limit_bits & PAGE_WRITE == 0 || .Execute in flags && mapping.limit_bits & PAGE_NO_EXECUTE != 0 {
			return mappings, .Bad_Operation
		}
		whole := address == mapping.address && count == mapping.page_count
		// A part takes away from the protection of its mapping now: it
		// cannot get more than it (a part that asked for more
		// changed nothing and succeeded).
		if !whole && .No_Access not_in flags && (mapping.bits == 0 || .Write in flags && mapping.bits & PAGE_WRITE == 0 || .Execute in flags && mapping.bits & PAGE_NO_EXECUTE != 0) {
			return mappings, .Bad_Operation
		}
		if !whole {
			if regions[mapping.region].contiguous {
				return mappings, .Bad_Address // Device memory, large pages: the protection is of the whole mapping.
			}
			if _, alone := object_only_here(program, mapping.region); !alone {
				return mappings, .Bad_State
			}
		}
		mappings[index] = u8(found)
	}
	// One table that names one mapping whole and in part: the parts are
	// checked against the protection before the change of the whole:
	// refused.
	for range, index in ranges {
		mapping := &program.mappings[mappings[index]]
		whole := range.address == mapping.address && range.page_count == mapping.page_count
		for other, other_index in ranges {
			if other_index != index && mappings[other_index] == mappings[index] && whole != (other.address == mapping.address && other.page_count == mapping.page_count) {
				return mappings, .Bad_Operation
			}
		}
	}
	return mappings, .Ok
}

// protect_entries_change gives the present entries of pages of a mapping
// the protection of their mapping and of their slot. One table of the last
// level at a time; a range with no table is skipped; the walk ends when it
// has seen each present entry of the mapping (the entries that are not
// present take their protection at their first use, in page_give).
protect_entries_change :: proc "contextless" (program: ^Program, mapping: ^Mapping, region: ^Region, first, count: u64, self: ^Processor) {
	seen: u64
	present := mapping.present_page_count
	for page := first; page < first + count && seen < present; {
		address := mapping.address + page * PAGE_SIZE
		run := min(512 - (address >> 12 & 511), first + count - page)
		if entry := page_entry(program.table, address); entry != nil {
			entries := ([^]u64)(entry)
			for at in 0 ..< run {
				if entries[at] & PAGE_PRESENT == 0 {
					continue
				}
				seen += 1
				bits := page_bits(mapping, region_page_state(region, mapping.first + page + at))
				if bits == 0 {
					entries[at] = 0
					mapping.present_page_count -= 1
				} else {
					entries[at] = entries[at] & PAGE_ADDRESS | bits
				}
				if self.table == program.table {
					page_flush(address + at * PAGE_SIZE)
				}
			}
		}
		page += run
	}
}

// protect_walk_count gives what a protection change of a range costs, for
// the limit of one call: the entries that the kernel changes. A large page
// is one entry. A whole mapping of 4 KiB pages changes only its present
// entries, and its walk ends at the last of them (protect_entries_change),
// so it counts its present pages: a mapping of 1 GiB of an object that
// several programs name can change its protection whole, as long as it has
// at most RANGE_TABLE_PAGE_LIMIT pages with a frame. A part counts each of
// its pages: its marks are written in each slot.
protect_walk_count :: proc "contextless" (mapping: ^Mapping, range: op.Address_Range) -> u64 {
	whole := range.address == mapping.address && range.page_count == mapping.page_count
	switch {
	case mapping.large:
		return range.page_count / op.LARGE_PAGE_PAGES
	case whole && intrinsics.atomic_load(&regions[mapping.region].marked_pages) == 0:
		return mapping.present_page_count
	}
	return range.page_count
}

// memory_protect changes the protection of the pages of the ranges, then
// makes each processor that uses the page table of the program forget the
// old translations: one processor_sync for the table.
memory_protect :: proc "contextless" (program: ^Program, ranges: []op.Address_Range, flags: op.Map_Flags) -> (changed: u64, status: op.Status) {
	places := protect_check(program, ranges, flags) or_return
	walked: u64
	for range, index in ranges {
		walked += protect_walk_count(&program.mappings[places[index]], range)
	}
	if walked > op.RANGE_TABLE_PAGE_LIMIT {
		return 0, .Bad_Operation
	}
	self := processor_self()
	for range, index in ranges {
		mapping := &program.mappings[places[index]]
		region_index := mapping.region
		region := &regions[region_index]
		first := (range.address - mapping.address) / PAGE_SIZE
		count := range.page_count
		mapping.protected = true
		if first == 0 && count == mapping.page_count {
			mapping.bits = protection_bits(mapping, flags)
		}
		// The protection of each page of a part, in its slot, as marks that
		// take away from the protection of the mapping now: a part that gets
		// the protection of its mapping has no mark. A whole mapping loses
		// the marks of its pages. While an object has marks it is not mapped
		// again and not given: the marks are of the object, so
		// they would reach another mapping.
		whole := first == 0 && count == mapping.page_count
		if !region.contiguous && (!whole || intrinsics.atomic_load(&region.marked_pages) != 0) {
			marks: u64
			if !whole {
				if .No_Access in flags {
					marks = SLOT_NO_ACCESS
				} else {
					marks |= .Write not_in flags && mapping.bits & PAGE_WRITE != 0 ? SLOT_DENY_WRITE : 0
					marks |= .Execute not_in flags && mapping.bits & PAGE_NO_EXECUTE == 0 ? SLOT_DENY_EXECUTE : 0
				}
			}
			lock := &region_locks[region_index]
			lock_take(lock, .Region)
			for page in mapping.first + first ..< mapping.first + first + count {
				slot := region_slot(region, page)
				value := intrinsics.atomic_load(slot)
				old := value & SLOT_MARKS
				intrinsics.atomic_store(slot, value &~ SLOT_MARKS | marks)
				if old != 0 && marks == 0 {
					intrinsics.atomic_sub(&region.marked_pages, 1)
				} else if old == 0 && marks != 0 {
					intrinsics.atomic_add(&region.marked_pages, 1)
				}
			}
			lock_free(lock, .Region)
		}
		// The entries that exist take the new protection.
		if mapping.large {
			for part in 0 ..< mapping.page_count / op.LARGE_PAGE_PAGES {
				address := mapping.address + part * LARGE_PAGE_SIZE
				entry := page_directory_entry(program.table, address)
				if entry == nil {
					continue
				}
				present := entry^ & PAGE_PRESENT != 0
				frame := region.physical + (mapping.first + part * op.LARGE_PAGE_PAGES) * PAGE_SIZE
				entry^ = mapping.bits == 0 ? 0 : frame | mapping.bits | PAGE_LARGE
				if present && mapping.bits == 0 {
					mapping.present_page_count -= op.LARGE_PAGE_PAGES
				} else if !present && mapping.bits != 0 {
					mapping.present_page_count += op.LARGE_PAGE_PAGES
				}
				if self.table == program.table {
					page_flush(address)
				}
			}
			changed += count
			continue
		}
		protect_entries_change(program, mapping, region, first, count, self)
		changed += count
	}
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(program.table))
	return changed, .Ok
}
