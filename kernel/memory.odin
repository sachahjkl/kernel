package kernel

import info "contract:boot_info"
import "base:intrinsics"

// K2, memory: the page frames, and the page tables of address spaces.

PAGE_SIZE :: info.PAGE_SIZE
PAGE_PRESENT :: u64(1) << 0
PAGE_WRITE :: u64(1) << 1
PAGE_USER :: u64(1) << 2
PAGE_NO_CACHE :: u64(1) << 4 | u64(1) << 3 // No cache, and each write goes to the device at once.
PAGE_NO_EXECUTE :: u64(1) << 63
PAGE_ADDRESS :: u64(0x000F_FFFF_FFFF_F000)

// One bit per page frame. 1: in use, or not memory.
// The frame lock protects frame_bits, frame_hint, free_frames,
// reserved_pages, the pages and `live` of each budget, the slots of the
// table of memory objects, and the budget that paid for each object
// (docs/ARCHITECTURE.md, "Locks of the kernel"). Each move of pages between
// a budget, the reserved pages and the frames is one section under it, so
// free_frames = pages of all budgets + reserved_pages when it is free.
frame_lock: Lock
frame_bits: []u64
frame_count: u64 // Read-only after boot.
frame_hint: u64
free_frames: u64
kernel_table: u64 // The top level page table that all address spaces share the upper half of.

direct :: #force_inline proc "contextless" (address: u64, $T: typeid) -> ^T {
	return (^T)(info.DIRECT_MAP_BASE + uintptr(address))
}

// physical_of gives the physical address of a pointer of the direct map.
physical_of :: #force_inline proc "contextless" (pointer: rawptr) -> u64 {
	return u64(uintptr(pointer) - info.DIRECT_MAP_BASE)
}

memory_start :: proc "contextless" (boot: ^info.Boot_Info) {
	ranges := info.physical_slice(boot.memory_ranges, boot.memory_range_count, info.Memory_Range)
	top: u64
	for range in ranges {
		if range.kind == .Free {
			top = max(top, range.start + range.page_count * PAGE_SIZE)
		}
	}
	frame_count = top / PAGE_SIZE
	words := (frame_count + 63) / 64
	bitmap_pages := (words * 8 + PAGE_SIZE - 1) / PAGE_SIZE
	bitmap_address: u64
	for range in ranges {
		if range.kind == .Free && range.page_count >= bitmap_pages && range.start >= 1 << 20 {
			bitmap_address = range.start
			break
		}
	}
	if bitmap_address == 0 {
		log("kernel: no memory for the page frame table")
		machine_stop(1)
	}
	frame_bits = ([^]u64)(direct(bitmap_address, u64))[:words]
	for &word in frame_bits {
		word = max(u64)
	}
	for range in ranges {
		if range.kind != .Free {
			continue
		}
		for page in 0 ..< range.page_count {
			address := range.start + page * PAGE_SIZE
			inside_bitmap := address >= bitmap_address && address < bitmap_address + bitmap_pages * PAGE_SIZE
			if address >= 1 << 20 && !inside_bitmap {
				frame_bits[address / PAGE_SIZE / 64] &~= 1 << (address / PAGE_SIZE % 64)
				free_frames += 1
			}
		}
	}

	// The kernel keeps the upper half of the page table of the boot program:
	// the direct map and the kernel itself. The lower half belongs to programs.
	kernel_table = frames_allocate(1)
	for i in 256 ..< 512 {
		direct(kernel_table, [512]u64)[i] = direct(boot.page_table, [512]u64)[i]
	}
	control_register_3_write(kernel_table)
	paging_start(boot)
	log_start()
}

frame_used :: #force_inline proc "contextless" (frame: u64) -> bool {
	return frame_bits[frame / 64] >> (frame % 64) & 1 != 0
}

// frames_allocate gives count page frames in one block, filled with zero.
// It gives 0 when there is no such block.
frames_allocate :: proc "contextless" (count: u64) -> u64 {
	lock_take(&frame_lock, .Frame)
	first := frames_take(count)
	lock_free(&frame_lock, .Frame)
	frames_zero(first, count)
	return first
}

// frames_zero fills frames with zero. The caller took them: no other
// processor uses them, and the frame lock need not be held.
frames_zero :: proc "contextless" (first: u64, count: u64) {
	if first != 0 {
		intrinsics.mem_zero(direct(first, u8), int(count * PAGE_SIZE))
	}
}

// frames_take takes count page frames in one block, not zero. 0: no such
// block. The caller holds the frame lock.
frames_take :: proc "contextless" (count: u64) -> u64 {
	if count == 0 || count > free_frames {
		return 0
	}
	for pass in 0 ..< 2 {
		start := pass == 0 ? frame_hint : 0
		run: u64
		for frame := start; frame < frame_count; frame += 1 {
			if frame % 64 == 0 && run == 0 && frame_bits[frame / 64] == max(u64) {
				frame += 63
				continue
			}
			if frame_used(frame) {
				run = 0
				continue
			}
			run += 1
			if run == count {
				first := frame + 1 - count
				for f in first ..= frame {
					frame_bits[f / 64] |= 1 << (f % 64)
				}
				free_frames -= count
				frame_hint = frame + 1
				return first * PAGE_SIZE
			}
		}
	}
	return 0
}

// frames_take_aligned takes count page frames in one block whose first
// frame is a multiple of alignment frames (a large page: 512), not zero.
// 0: no such block. The caller holds the frame lock.
frames_take_aligned :: proc "contextless" (count: u64, alignment: u64) -> u64 {
	if alignment <= 1 {
		return frames_take(count)
	}
	if count == 0 || count > free_frames {
		return 0
	}
	first := u64(0)
	search: for first + count <= frame_count {
		for frame in first ..< first + count {
			if frame_used(frame) {
				// The next candidate is the multiple of the alignment above
				// the used frame, not the next multiple only.
				first = (frame / alignment + 1) * alignment
				continue search
			}
		}
		for frame in first ..< first + count {
			frame_bits[frame / 64] |= 1 << (frame % 64)
		}
		free_frames -= count
		return first * PAGE_SIZE
	}
	return 0
}

// frames_free gives frames back.
frames_free :: proc "contextless" (address: u64, count: u64) {
	lock_take(&frame_lock, .Frame)
	frames_free_held(address, count)
	lock_free(&frame_lock, .Frame)
}

// frames_free_held gives frames back. The caller holds the frame lock.
frames_free_held :: proc "contextless" (address: u64, count: u64) {
	first := address / PAGE_SIZE
	for f in first ..< first + count {
		frame_bits[f / 64] &~= 1 << (f % 64)
	}
	free_frames += count
	frame_hint = min(frame_hint, first)
}

// The frame cache of each processor (docs/ARCHITECTURE.md, "Locks of the
// kernel", "The frame caches"). Each processor keeps a stack of at most
// FRAME_CACHE_CAPACITY free frames in its processor record, under its cache
// lock (after the frame lock in the lock order). A frame of a stack has its
// bit set in frame_bits and is not in free_frames: it is free, and the
// report adds it.
//
// The invariant, when the frame lock and the cache locks are free:
//   free_frames + the frames of all stacks
//     = the pages of all budgets + reserved_pages - the taken of all stacks.
// A take from a stack moves 1 from its frames to its taken, in one section
// of its cache lock: the sum frames + taken of a stack does not change.
// That sum changes only under the frame lock and the cache lock together
// (a batch, a give back, a fold of taken, a drain). So a reader that holds
// the frame lock reads each stack under its cache lock, one after the
// other, and gets the exact difference free - reserved (the invariant)
// while the other processors take. The free pages alone and the reserved
// pages alone are not values of one instant: a take from a stack after
// the reader read it is in neither sum, a take before is in both.
//
// taken folds into reserved_pages only at a refill and at a drain: a
// processor that frees as much as it takes never refills, and its taken
// grows with no end. That is harmless: the report and the check subtract
// it, and a u64 does not wrap in the life of a machine.
//
// A take that cannot fail (a reserved page, a list page, a page table) or
// a contiguous object, with no free frame in the frame table, drains all
// the stacks under the frame lock and takes again (caches_drain). A drain
// always gets each stack: no processor waits for the frame lock while it
// holds a cache lock (the order is frame, then cache). So no take fails
// while frames sit in a stack.
//
// Frames on a stack are not zero: a page gets its zeros when it takes its
// frame, after the locks (region_frame), as before the caches.

// The test build checks the sums of the frames at each report and at each
// drain, and drains all the stacks at each 64th refill of a stack, so that
// the drain runs while the other processors take and put.
TEST_BUILD_CHECKS_FRAME_SUMS :: #config(TEST_BUILD_CHECKS_FRAME_SUMS, true)

// frame_reserved_take gives one page frame, not zero, for a reserved page:
// from the stack of this processor; an empty stack takes the frame from the
// frame table and a batch for the stack, in one section of the frame lock.
// The caller holds no frame lock and no cache lock. It runs only for a
// page on first use of a memory object of a program, so after the first
// processor has its record (processor_self): the first memory object that
// is not contiguous is made in root_start, after processor_start.
frame_reserved_take :: proc "contextless" () -> u64 {
	cache := &processor_self().frame_cache
	lock_take(&cache.lock, .Cache)
	if cache.count != 0 {
		cache.count -= 1
		frame := cache.frames[cache.count]
		cache.taken += 1
		lock_free(&cache.lock, .Cache)
		return frame
	}
	lock_free(&cache.lock, .Cache)
	lock_take(&frame_lock, .Frame)
	frame := frame_take_held()
	reserved_pages -= 1
	cache_refill_held(cache)
	lock_free(&frame_lock, .Frame)
	return frame
}

// frame_take_held gives one page frame, not zero, for a page that a budget
// reserved or paid. The kernel keeps the invariant above, so a frame
// exists in the frame table or in a stack: it cannot fail. The caller holds
// the frame lock and no cache lock.
frame_take_held :: proc "contextless" () -> u64 {
	frame := frames_take(1)
	if frame == 0 {
		caches_drain()
		frame = frames_take(1)
	}
	if frame == 0 {
		log("kernel: no page frame for a reserved page")
		machine_stop(1)
	}
	return frame
}

// cache_refill_held gives an empty stack a batch from the frame table, and
// subtracts its taken from reserved_pages. The caller holds the frame lock.
@(private = "file")
cache_refill_held :: proc "contextless" (cache: ^Frame_Cache) {
	when TEST_BUILD_CHECKS_FRAME_SUMS {
		// Only this processor writes refills: a read with no lock.
		if (cache.refills + 1) % 64 == 0 {
			caches_drain()
		}
	}
	lock_take(&cache.lock, .Cache)
	cache.refills += 1
	reserved_pages -= cache.taken
	cache.taken = 0
	taken_before := cache.count
	for cache.count < FRAME_CACHE_BATCH {
		frame := frames_take(1)
		if frame == 0 {
			break
		}
		cache.frames[cache.count] = frame
		cache.count += 1
	}
	if cache.count != taken_before {
		cache.batches_taken += 1
	}
	lock_free(&cache.lock, .Cache)
}

// cache_put_held puts a free frame on a stack; a full stack gives a batch
// back to the frame table first. The caller holds the frame lock and the
// cache lock of the stack.
cache_put_held :: proc "contextless" (cache: ^Frame_Cache, frame: u64) {
	if cache.count == FRAME_CACHE_CAPACITY {
		for _ in 0 ..< FRAME_CACHE_BATCH {
			cache.count -= 1
			frames_free_held(cache.frames[cache.count], 1)
		}
		cache.batches_given += 1
	}
	cache.frames[cache.count] = frame
	cache.count += 1
}

// caches_drain moves the frames of each stack to the frame table, and the
// taken of each stack to reserved_pages. The caller holds the frame lock
// and no cache lock.
caches_drain :: proc "contextless" () {
	for cpu in processors[:processor_count] {
		cache := &cpu.frame_cache
		lock_take(&cache.lock, .Cache)
		if cache.count != 0 {
			cache.drains += 1
		}
		for frame in cache.frames[:cache.count] {
			frames_free_held(frame, 1)
		}
		cache.count = 0
		reserved_pages -= cache.taken
		cache.taken = 0
		lock_free(&cache.lock, .Cache)
	}
	when TEST_BUILD_CHECKS_FRAME_SUMS {
		frames_check()
	}
}

// frames_counted gives the free pages and the reserved pages of the
// machine: the frame table and the stacks. The caller holds the frame lock,
// so the sums are exact (see above).
frames_counted :: proc "contextless" () -> (free: u64, reserved: u64) {
	free, reserved = free_frames, reserved_pages
	for cpu in processors[:processor_count] {
		cache := &cpu.frame_cache
		lock_take(&cache.lock, .Cache)
		free += u64(cache.count)
		reserved -= cache.taken
		lock_free(&cache.lock, .Cache)
	}
	when TEST_BUILD_CHECKS_FRAME_SUMS {
		frames_check()
	}
	return free, reserved
}

// frames_check stops the machine if the frames do not add up: the free bits
// of frame_bits are free_frames, each frame of a stack has its bit set, and
// the invariant above holds. The caller holds the frame lock.
frames_check :: proc "contextless" () {
	free_bits: u64
	for word in frame_bits {
		free_bits += 64 - u64(intrinsics.count_ones(word))
	}
	stacked, taken, budget_pages: u64
	marked := true
	for cpu in processors[:processor_count] {
		cache := &cpu.frame_cache
		lock_take(&cache.lock, .Cache)
		stacked += u64(cache.count)
		taken += cache.taken
		for frame in cache.frames[:cache.count] {
			marked &&= frame_used(frame / PAGE_SIZE)
		}
		lock_free(&cache.lock, .Cache)
	}
	for budget in budgets {
		budget_pages += budget.amounts.pages
	}
	if free_bits != free_frames || !marked || free_frames + stacked != budget_pages + reserved_pages - taken {
		fault_report_begin()
		log("kernel: the frames do not add up: free bits ", free_bits, ", free frames ", free_frames, ", in stacks ", stacked, ", marked ", u64(marked), ", budgets ", budget_pages, ", reserved ", reserved_pages, ", taken ", taken)
		machine_stop(3)
	}
}

// page_entry gives the entry of the last level table for an address, or
// nil when a table on the way is missing. It makes no table. A large page:
// the entry of the second level is the entry of the address (an object made
// Large_Pages).
page_entry :: proc "contextless" (table: u64, address: u64) -> ^u64 {
	current := table
	for level := uint(3); level >= 1; level -= 1 {
		entry := &direct(current, [512]u64)[address >> (12 + 9 * level) & 511]
		if level == 1 && entry^ & PAGE_LARGE != 0 {
			return entry
		}
		if entry^ & PAGE_PRESENT == 0 {
			return nil
		}
		current = entry^ & PAGE_ADDRESS
	}
	return &direct(current, [512]u64)[address >> 12 & 511]
}

// page_directory_entry gives the entry of the second level for an address
// aligned on 2 MiB, present or not: the place of a large page. nil: a table
// above it is missing. It makes no table.
page_directory_entry :: proc "contextless" (table: u64, address: u64) -> ^u64 {
	current := table
	for level := uint(3); level >= 2; level -= 1 {
		entry := &direct(current, [512]u64)[address >> (12 + 9 * level) & 511]
		if entry^ & PAGE_PRESENT == 0 {
			return nil
		}
		current = entry^ & PAGE_ADDRESS
	}
	return &direct(current, [512]u64)[address >> 21 & 511]
}

// The held entries of the page tables of a program (docs/ARCHITECTURE.md,
// "The page tables of a program"). An entry is held while a mapping covers
// it: a page of a mapping, present or not, a large page, or an entry that
// names a table with held entries. A table with no held entry is freed at
// once, and the budget that paid for it gets its page back; the top table
// lives as long as the program.
//
// The count of the held entries of a table is in the entry that names the
// table, in the bits 52 to 62. The processor ignores those bits in an entry
// that names a table (the processor manual, Intel SDM volume 3A, the tables
// of the formats of the entries of 4-level paging), and the kernel keeps no
// record for each frame (a frame is one bit of frame_bits): so the count
// costs no memory, and it lives and ends with the table. The top table has
// no such entry and needs no count. An entry of a large page or of a page of
// 4 KiB never has a count.
//
// The count changes with an atomic addition: a processor that walks the
// table sets the bit Accessed of the same entry with a locked write, and a
// plain write of the kernel could undo it. The program lock orders the
// writers of the kernel.
TABLE_HELD_SHIFT :: 52
TABLE_HELD_ONE :: u64(1) << TABLE_HELD_SHIFT
TABLE_HELD_MASK :: u64(0x7FF) << TABLE_HELD_SHIFT
// The count never touches the address of the table or the bit No_Execute,
// and 512, the most entries of a table, fits.
#assert(TABLE_HELD_MASK & (PAGE_ADDRESS | PAGE_NO_EXECUTE) == 0)
#assert(512 * TABLE_HELD_ONE <= TABLE_HELD_MASK)

// table_held_count gives the count of the held entries of the table that an
// entry names.
table_held_count :: #force_inline proc "contextless" (entry: u64) -> u64 {
	return (entry & TABLE_HELD_MASK) >> TABLE_HELD_SHIFT
}

// The tables that left a page table of a program and wait for the
// shoot-down before their frames return (page_tables_free). They are linked
// through their first entry: a physical address on 4096 bytes has the bit
// Present clear, so a processor that still walks into such a table finds
// nothing present there.
Freed_Tables :: struct {
	first: u64,
	count: u64,
}

// tables_hold makes the tables that are missing on the way to the table
// whose entries index an address at the level below lowest_level (1: the
// table of the last level; 2: the table of the second level, for a large
// page), adds count held entries to that table with one addition, and gives
// the entry of the address: the first of the count entries, which the
// caller keeps inside that one table. The budget
// pays for each new table. nil: the budget has no page; a table made by this
// call goes to freed, and the caller frees it after its shoot-down. The
// caller holds the program lock.
@(private = "file")
tables_hold :: proc "contextless" (table: u64, address: u64, lowest_level: uint, count: u64, budget: ^u32, freed: ^Freed_Tables) -> ^u64 {
	current := table
	holder: ^u64 // The entry that names current; nil for the top table.
	for level := uint(3); level >= lowest_level; level -= 1 {
		entry := &direct(current, [512]u64)[address >> (12 + 9 * level) & 511]
		if entry^ & PAGE_LARGE != 0 {
			// map_region refused an overlap with the mapping of the large page.
			page_table_count_broken("a large page is where a table is held")
		}
		if entry^ & PAGE_PRESENT == 0 {
			child := frame_paid(budget)
			if child == 0 {
				// The table current can be one that this call made, with no
				// held entry: it leaves now.
				if holder != nil {
					page_entries_release(table, address, level + 1, 0, freed)
				}
				return nil
			}
			entry^ = child | PAGE_PRESENT | PAGE_WRITE | PAGE_USER
			if holder != nil {
				intrinsics.atomic_add(holder, TABLE_HELD_ONE)
			}
		}
		holder = entry
		current = entry^ & PAGE_ADDRESS
	}
	intrinsics.atomic_add(holder, count * TABLE_HELD_ONE)
	return &direct(current, [512]u64)[address >> (12 + 9 * (lowest_level - 1)) & 511]
}

// page_entry_hold gives the entry of the last level table for an address of
// a new mapping, and holds it and the count - 1 entries after it, in the
// same table: map_region makes each table of a mapping, so a page fault
// never needs a table. One addition for each table, not one for each page.
// nil: the budget has no page.
page_entry_hold :: proc "contextless" (table: u64, address: u64, count: u64, budget: ^u32, freed: ^Freed_Tables) -> ^u64 {
	if count == 0 || count > 512 - (address >> 12 & 511) {
		page_table_count_broken("a run of held entries passes the end of its table")
	}
	return tables_hold(table, address, 1, count, budget, freed)
}

// page_directory_entry_hold gives the entry of the second level for an
// address aligned on 2 MiB of a new mapping of large pages, and holds it.
// nil: the budget has no page.
page_directory_entry_hold :: proc "contextless" (table: u64, address: u64, budget: ^u32, freed: ^Freed_Tables) -> ^u64 {
	entry := tables_hold(table, address, 2, 1, budget, freed)
	if entry != nil && entry^ & PAGE_PRESENT != 0 {
		// map_region refused an overlap: no mapping holds these 2 MiB.
		page_table_count_broken("the place of a large page is held")
	}
	return entry
}

// page_entries_release ends count held entries of one table: the table
// named by the entry of holder_level on the way to an address (1: the table
// of the last level; 2: the table of the second level, for a large page).
// The caller cleared those entries first. A table whose count falls to 0
// leaves its parent: its entry there becomes 0, the table goes to freed,
// and the parent loses one held entry, up to the top table, which never
// leaves. A count of 0 frees the table if it holds nothing (the undo of a
// hold). The cost when the table keeps held entries: one walk of the upper
// levels and one atomic subtraction. The caller holds the program lock, then
// makes the shoot-down, then calls page_tables_free.
page_entries_release :: proc "contextless" (table: u64, address: u64, holder_level: uint, count: u64, freed: ^Freed_Tables) {
	holders: [4]^u64
	current := table
	for level := uint(3); level >= holder_level; level -= 1 {
		entry := &direct(current, [512]u64)[address >> (12 + 9 * level) & 511]
		if entry^ & PAGE_PRESENT == 0 || entry^ & PAGE_LARGE != 0 {
			page_table_count_broken("a held entry has no table")
		}
		holders[level] = entry
		current = entry^ & PAGE_ADDRESS
	}
	released := count
	for level := holder_level; level <= 3; level += 1 {
		holder := holders[level]
		before := intrinsics.atomic_sub(holder, released * TABLE_HELD_ONE)
		held := table_held_count(before)
		if held < released {
			page_table_count_broken("a table releases more entries than it holds")
		}
		if held != released {
			return
		}
		emptied := before & PAGE_ADDRESS
		intrinsics.atomic_store(holder, 0)
		freed_tables_add(freed, emptied)
		released = 1
	}
}

// freed_tables_add links a table that left its page table. The test build
// checks the count: no entry of the table is present.
@(private = "file")
freed_tables_add :: proc "contextless" (freed: ^Freed_Tables, table: u64) {
	when TEST_BUILD_CHECKS_LOCK_ORDER {
		for entry in direct(table, [512]u64) {
			if entry & PAGE_PRESENT != 0 {
				page_table_count_broken("a table with no held entry has a present entry")
			}
		}
	}
	direct(table, [512]u64)[0] = freed.first
	freed.first = table
	freed.count += 1
}

// page_tables_free gives the frames of the freed tables back, and the
// budget of the program one page for each. The caller cleared the entries
// that named them, then made the shoot-down (processor_sync to each other
// processor whose table is this one: each reloads cr3).
//
// This processor reloads cr3 too, if it uses the table. The processor
// manual (Intel SDM volume 3A, "Invalidation of TLBs and Paging-Structure
// Caches") says that a processor can keep an entry of an upper level in its
// paging-structure caches, even when no page under it is present, and that
// such an entry stays until an invalidation that covers it. The flush of
// one page (invlpg) removes the translations of that page; the manual asks
// for it at least once for an entry of an upper level, and the kernel ran it
// only for the present pages: a mapping with no present page ran none. A
// write of cr3 removes every entry of the paging-structure caches of the
// address space, with no condition. It runs once for each release that
// freed a table, never for one that freed none. The caller holds the
// program lock.
page_tables_free :: proc "contextless" (table: u64, budget: ^u32, freed: ^Freed_Tables) {
	if freed.count == 0 {
		return
	}
	if self := processor_self(); intrinsics.atomic_load(&self.table) == table {
		control_register_3_write(table)
	}
	lock_take(&frame_lock, .Frame)
	for page := freed.first; page != 0; {
		next := direct(page, [512]u64)[0]
		frames_free_held(page, 1)
		page = next
	}
	budgets[budget^].amounts.pages += freed.count
	lock_free(&frame_lock, .Frame)
	freed^ = {}
}

// page_table_count_broken stops the machine: a count of held entries is not
// what the page table holds. Only the kernel writes the counts, so this is
// a mistake of the kernel.
page_table_count_broken :: proc "contextless" (what: string) -> ! {
	fault_report_begin()
	log("kernel: the page tables of a program do not keep their counts: ", what)
	machine_stop(3)
}

// frame_paid takes one zero page frame that a budget pays for: a page
// table. 0: the budget has no page. A page table that an unmap empties
// returns to the frame table, not to a reserve: a map, an unmap and a map at
// the same address take the frame again, with one section of the frame
// lock and one fill with zero, in the operation that already makes a
// shoot-down. The end of a budget changes the field
// under the frame lock (budget_release).
frame_paid :: proc "contextless" (budget_field: ^u32) -> u64 {
	lock_take(&frame_lock, .Frame)
	frame: u64
	budget := budget_field^
	if budgets[budget].live && budgets[budget].amounts.pages != 0 {
		frame = frames_take(1)
		if frame == 0 {
			caches_drain()
			frame = frames_take(1)
		}
		if frame != 0 {
			budgets[budget].amounts.pages -= 1
		}
	}
	lock_free(&frame_lock, .Frame)
	frames_zero(frame, 1)
	return frame
}

// address_space_create gives a top level table with the kernel half only.
// The budget pays for it. 0: the budget has no page.
address_space_create :: proc "contextless" (budget: ^u32) -> u64 {
	table := frame_paid(budget)
	if table != 0 {
		for i in 256 ..< 512 {
			direct(table, [512]u64)[i] = direct(kernel_table, [512]u64)[i]
		}
	}
	return table
}

// address_space_free frees the top table of a program with no mapping. The
// budget receives the page. Each unmap freed the tables below that it
// emptied, so no entry of the program half of the top table is present: a
// table there would be a page that no count names, and the machine stops.
// Only the bit Present counts: an entry that is not present names no table,
// whatever its other bits hold.
address_space_free :: proc "contextless" (table: u64, budget: ^u32) {
	for entry in direct(table, [512]u64)^[:256] {
		if entry & PAGE_PRESENT != 0 {
			page_table_count_broken("a table outlived the mappings of its program")
		}
	}
	lock_take(&frame_lock, .Frame)
	frames_free_held(table, 1)
	budgets[budget^].amounts.pages += 1
	lock_free(&frame_lock, .Frame)
}

// user_range says if a program can read (or write) all bytes of a range.
// It makes each page of the range present: a page on first use gets its
// frame now, so the copy that follows does not fault in the kernel.
user_range :: proc "contextless" (program: ^Program, address: u64, size: u64, write: bool) -> bool {
	if size == 0 {
		return true
	}
	if address >= USER_END || size > USER_END - address {
		return false
	}
	for page := address &~ (PAGE_SIZE - 1); page < address + size; page += PAGE_SIZE {
		entry := page_entry(program.table, page)
		if (entry == nil || entry^ & PAGE_PRESENT == 0) && page_give(program, page, write, false) {
			entry = page_entry(program.table, page)
		}
		if entry == nil || entry^ & (PAGE_PRESENT | PAGE_USER) != PAGE_PRESENT | PAGE_USER {
			return false
		}
		if write && entry^ & PAGE_WRITE == 0 {
			return false
		}
	}
	return true
}

// device_range says if a range of physical addresses can be device memory:
// no page of it is memory that the firmware gave as free or as loaded.
device_range :: proc "contextless" (start: u64, page_count: u64) -> bool {
	if page_count == 0 || start % PAGE_SIZE != 0 || start >> 52 != 0 || page_count > (u64(1) << 52 - start) / PAGE_SIZE {
		return false
	}
	end := start + page_count * PAGE_SIZE
	for range in info.physical_slice(boot_record.memory_ranges, boot_record.memory_range_count, info.Memory_Range) {
		if range.kind == .Reserved {
			continue
		}
		range_end := range.start + range.page_count * PAGE_SIZE
		if start < range_end && range.start < end {
			return false
		}
	}
	return true
}
