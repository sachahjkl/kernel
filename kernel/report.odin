package kernel

import info "contract:boot_info"
import op "contract:operation"
import "base:intrinsics"

// The record of how the machine started (op.Boot_Report). The kernel reads
// the cycle counter of the processor at the end of each stage. The counter
// is 0 when the machine starts, so the first stage is the firmware.

Stage :: enum {
	Firmware,
	Boot_Program_Load,
	Boot_Program_Tables,
	Kernel_Memory,
	Kernel_Processor,
	Kernel_Processors,
	Kernel_Root,
}

@(rodata)
STAGE_NAMES := [Stage]string {
	.Firmware            = "firmware",
	.Boot_Program_Load   = "boot program: load the kernel, the boot image",
	.Boot_Program_Tables = "boot program: page tables, memory map, jump",
	.Kernel_Memory       = "kernel: page frames, kernel page table",
	.Kernel_Processor    = "kernel: first processor, timer",
	.Kernel_Processors   = "kernel: other processors",
	.Kernel_Root         = "kernel: root service",
}

stage_cycles: [Stage]u64 // The cycle counter at the end of each stage.
cycle_frequency: u64
boot_record: info.Boot_Info

cycles_now :: #force_inline proc "contextless" () -> u64 {
	return u64(intrinsics.read_cycle_counter())
}

// microseconds gives the time of a number of cycles. It is 0 before the
// kernel measured the cycle counter.
microseconds :: proc "contextless" (cycles: u64) -> u64 {
	per_microsecond := cycle_frequency / 1_000_000
	return per_microsecond == 0 ? 0 : cycles / per_microsecond
}

stage_end :: proc "contextless" (stage: Stage) {
	stage_cycles[stage] = cycles_now()
}

boot_report :: proc "contextless" (report: ^op.Boot_Report) {
	boot := &boot_record
	report^ = {
		time                = microseconds(cycles_now()),
		stage_count         = len(Stage),
		firmware_vendor     = boot.firmware_vendor,
		firmware_revision   = boot.firmware_revision,
		framebuffer_address = boot.framebuffer.address,
		framebuffer_width   = u64(boot.framebuffer.width),
		framebuffer_height  = u64(boot.framebuffer.height),
		framebuffer_line    = u64(boot.framebuffer.pixels_per_line),
		framebuffer_format  = u64(boot.framebuffer.format),
		kernel_size         = boot.kernel_size,
		kernel_file_size    = boot.kernel_file_size,
		boot_image_size     = boot.boot_image_size,
		direct_map_size     = boot.direct_map_size,
		acpi_root           = boot.acpi_root,
		cycle_frequency     = cycle_frequency,
		timer_frequency     = u64(timer_count) * 16 * TICKS_PER_SECOND,
	}
	start: u64
	for stage in Stage {
		item := &report.stages[stage]
		name := STAGE_NAMES[stage]
		intrinsics.mem_copy_non_overlapping(&item.name, raw_data(name), min(len(name), len(item.name) - 1))
		item.start = microseconds(start)
		item.duration = microseconds(stage_cycles[stage] - start)
		start = stage_cycles[stage]
	}
	for range in info.physical_slice(boot.memory_ranges, boot.memory_range_count, info.Memory_Range) {
		op.boot_range_add(report, range.start, range.page_count, u64(range.kind))
	}
}
