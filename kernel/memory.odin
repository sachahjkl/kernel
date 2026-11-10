package kernel

import info "../boot_info"
import "base:intrinsics"

// K2, memory: the page frames, and the page tables of address spaces.

PAGE_SIZE :: info.PAGE_SIZE
PAGE_PRESENT :: u64(1) << 0
PAGE_WRITE :: u64(1) << 1
PAGE_USER :: u64(1) << 2
PAGE_NO_EXECUTE :: u64(1) << 63
PAGE_ADDRESS :: u64(0x000F_FFFF_FFFF_F000)

// One bit per page frame. 1: in use, or not memory.
frame_bits: []u64
frame_count: u64
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
}

frame_used :: #force_inline proc "contextless" (frame: u64) -> bool {
	return frame_bits[frame / 64] >> (frame % 64) & 1 != 0
}

// frames_allocate gives count page frames in one block, filled with zero.
// It gives 0 when there is no such block.
frames_allocate :: proc "contextless" (count: u64) -> u64 {
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
				intrinsics.mem_zero(direct(first * PAGE_SIZE, u8), int(count * PAGE_SIZE))
				return first * PAGE_SIZE
			}
		}
	}
	return 0
}

frames_free :: proc "contextless" (address: u64, count: u64) {
	first := address / PAGE_SIZE
	for f in first ..< first + count {
		frame_bits[f / 64] &~= 1 << (f % 64)
	}
	free_frames += count
	frame_hint = min(frame_hint, first)
}

// page_entry gives the entry of the last level table for an address.
// With create, it makes the tables that are missing: the budget pays.
page_entry :: proc "contextless" (table: u64, address: u64, create: bool, budget: u32 = 0) -> ^u64 {
	current := table
	for level := uint(3); level >= 1; level -= 1 {
		entry := &direct(current, [512]u64)[address >> (12 + 9 * level) & 511]
		if entry^ & PAGE_PRESENT == 0 {
			if !create {
				return nil
			}
			if !budgets[budget].live || budgets[budget].amounts.pages == 0 {
				return nil
			}
			child := frames_allocate(1)
			if child == 0 {
				return nil
			}
			budgets[budget].amounts.pages -= 1
			entry^ = child | PAGE_PRESENT | PAGE_WRITE | PAGE_USER
		}
		current = entry^ & PAGE_ADDRESS
	}
	return &direct(current, [512]u64)[address >> 12 & 511]
}

// address_space_create gives a top level table with the kernel half only.
address_space_create :: proc "contextless" () -> u64 {
	table := frames_allocate(1)
	if table != 0 {
		for i in 256 ..< 512 {
			direct(table, [512]u64)[i] = direct(kernel_table, [512]u64)[i]
		}
	}
	return table
}

// address_space_free frees the tables of the program half, and the top
// table. It gives the number of pages that it freed.
address_space_free :: proc "contextless" (table: u64) -> u64 {
	free_level :: proc "contextless" (table: u64, level: int, limit: int) -> (count: u64) {
		for i in 0 ..< limit {
			entry := direct(table, [512]u64)[i]
			if entry & PAGE_PRESENT != 0 && level > 1 {
				count += free_level(entry & PAGE_ADDRESS, level - 1, 512)
			}
		}
		frames_free(table, 1)
		return count + 1
	}
	return free_level(table, 4, 256)
}

// user_range says if a program can read (or write) all bytes of a range.
user_range :: proc "contextless" (table: u64, address: u64, size: u64, write: bool) -> bool {
	if size == 0 {
		return true
	}
	if address >= USER_END || size > USER_END - address {
		return false
	}
	for page := address &~ (PAGE_SIZE - 1); page < address + size; page += PAGE_SIZE {
		entry := page_entry(table, page, false)
		if entry == nil || entry^ & (PAGE_PRESENT | PAGE_USER) != PAGE_PRESENT | PAGE_USER {
			return false
		}
		if write && entry^ & PAGE_WRITE == 0 {
			return false
		}
	}
	return true
}
