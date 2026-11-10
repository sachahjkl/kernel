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
	cr3_write(kernel_table)
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

// page_entry gives the entry of the last level table for an address.
// With create, it makes the tables that are missing: the budget pays. The
// budget is the field of the program that names it: the frame lock reads it.
page_entry :: proc "contextless" (table: u64, address: u64, create: bool, budget: ^u32 = nil) -> ^u64 {
	current := table
	for level := uint(3); level >= 1; level -= 1 {
		entry := &direct(current, [512]u64)[address >> (12 + 9 * level) & 511]
		if entry^ & PAGE_PRESENT == 0 {
			if !create {
				return nil
			}
			child := frame_paid(budget)
			if child == 0 {
				return nil
			}
			entry^ = child | PAGE_PRESENT | PAGE_WRITE | PAGE_USER
		}
		current = entry^ & PAGE_ADDRESS
	}
	return &direct(current, [512]u64)[address >> 12 & 511]
}

// frame_paid takes one zero page frame that a budget pays for: a page
// table. 0: the budget has no page. The end of a budget changes the field
// under the frame lock (budget_release).
frame_paid :: proc "contextless" (budget_field: ^u32) -> u64 {
	lock_take(&frame_lock, .Frame)
	frame: u64
	budget := budget_field^
	if budgets[budget].live && budgets[budget].amounts.pages != 0 {
		frame = frames_take(1)
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

// address_space_free frees the tables of the program half, and the top
// table. The budget receives the pages.
address_space_free :: proc "contextless" (table: u64, budget: ^u32) {
	free_level :: proc "contextless" (table: u64, level: int, limit: int) -> (count: u64) {
		for i in 0 ..< limit {
			entry := direct(table, [512]u64)[i]
			if entry & PAGE_PRESENT != 0 && level > 1 {
				count += free_level(entry & PAGE_ADDRESS, level - 1, 512)
			}
		}
		frames_free_held(table, 1)
		return count + 1
	}
	lock_take(&frame_lock, .Frame)
	budgets[budget^].amounts.pages += free_level(table, 4, 256)
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
		entry := page_entry(program.table, page, false)
		if (entry == nil || entry^ & PAGE_PRESENT == 0) && page_give(program, page, write, false) {
			entry = page_entry(program.table, page, false)
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
