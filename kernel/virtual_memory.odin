package kernel

import "base:intrinsics"
import op "contract:operation"

// The virtual memory of a program (docs/ARCHITECTURE.md, "The virtual
// memory of a program"): commit and decommit the pages of an uncommitted
// object, and change the protection of pages. The caller holds the program
// lock of the program.

// object_only_here says if a memory object is named only by this program,
// with one mapping: its pages have page table entries only in this program.
// It gives that mapping. The references of the object are the handles and
// the mappings of all programs; under the program lock the handles and the
// mappings of this program do not change, and another program that names
// the object holds a reference.
object_only_here :: proc "contextless" (program: ^Program, region_index: u32) -> ^Mapping {
	own: u32
	found: ^Mapping
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
	if mappings != 1 || intrinsics.atomic_load(&regions[region_index].references) != own + mappings {
		return nil
	}
	return found
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
	mapping := object_only_here(program, region_index)
	if mapping == nil {
		return 0, .Bad_State
	}
	lock_take(region_lock, .Region)
	defer lock_free(region_lock, .Region)
	self := processor_self()
	for range in ranges {
		for page in range.first ..< range.first + range.page_count {
			if page < mapping.first || page - mapping.first >= mapping.page_count {
				continue // Not in the mapping: no entry.
			}
			address := mapping.address + (page - mapping.first) * PAGE_SIZE
			if entry := page_entry(program.table, address, false); entry != nil && entry^ & PAGE_PRESENT != 0 {
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
		if .Write in flags && mapping.limit_bits & PAGE_WRITE == 0 || .Execute in flags && mapping.limit_bits & PAGE_NO_EXECUTE != 0 {
			return mappings, .No_Right
		}
		whole := address == mapping.address && count == mapping.page_count
		if !whole {
			if regions[mapping.region].contiguous {
				return mappings, .Bad_Address // Device memory, large pages: the protection is of the whole mapping.
			}
			if object_only_here(program, mapping.region) == nil {
				return mappings, .Bad_State
			}
		}
		mappings[index] = u8(found)
	}
	return mappings, .Ok
}

// memory_protect changes the protection of the pages of the ranges, then
// makes each processor that uses the page table of the program forget the
// old translations: one processor_sync for the table.
memory_protect :: proc "contextless" (program: ^Program, ranges: []op.Address_Range, flags: op.Map_Flags) -> (changed: u64, status: op.Status) {
	places := protect_check(program, ranges, flags) or_return
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
		// The protection of each page of a part, in its slot; a whole
		// mapping of an object named only here loses the marks of parts.
		if !region.contiguous && (first != 0 || count != mapping.page_count || object_only_here(program, region_index) != nil) {
			marks: u64
			if first != 0 || count != mapping.page_count {
				if .No_Access in flags {
					marks = SLOT_NO_ACCESS
				} else {
					marks |= .Write in flags ? 0 : SLOT_DENY_WRITE
					marks |= .Execute in flags ? 0 : SLOT_DENY_EXECUTE
				}
			}
			lock := &region_locks[region_index]
			lock_take(lock, .Region)
			for page in mapping.first + first ..< mapping.first + first + count {
				slot := region_slot(region, page)
				value := intrinsics.atomic_load(slot)
				intrinsics.atomic_store(slot, value &~ (SLOT_DENY_WRITE | SLOT_DENY_EXECUTE | SLOT_NO_ACCESS) | marks)
			}
			lock_free(lock, .Region)
		}
		// The entries that exist take the new protection.
		if mapping.large {
			for part in 0 ..< mapping.page_count / op.LARGE_PAGE_PAGES {
				address := mapping.address + part * LARGE_PAGE_SIZE
				entry := page_directory_entry(program.table, address, false)
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
		for page in first ..< first + count {
			address := mapping.address + page * PAGE_SIZE
			entry := page_entry(program.table, address, false)
			if entry == nil || entry^ & PAGE_PRESENT == 0 {
				continue // A page with no entry takes its protection at its first use (page_give).
			}
			bits := page_bits(mapping, region_page_state(region, mapping.first + page))
			if bits == 0 {
				entry^ = 0
				mapping.present_page_count -= 1
			} else {
				entry^ = entry^ & PAGE_ADDRESS | bits
			}
			if self.table == program.table {
				page_flush(address)
			}
		}
		changed += count
	}
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(program.table))
	return changed, .Ok
}
