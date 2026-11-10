package kernel

import info "../boot_info"
import "base:intrinsics"

// The interrupt controller of each processor (local APIC): the timer, and
// the interrupts that one processor sends to another. It also holds the
// search of the processors in the ACPI tables, and their start.
//
// The 16 device lines stay on the 8259, which interrupts the first
// processor. A device with more needs sends its interrupts to a local APIC
// by a message; no device does that yet.

MSR_APIC_BASE :: 0x1B
APIC_ID :: 0x20
APIC_PRIORITY :: 0x80
APIC_END :: 0xB0
APIC_SPURIOUS :: 0xF0
APIC_SEND_LOW :: 0x300
APIC_SEND_HIGH :: 0x310
APIC_TIMER :: 0x320
APIC_LINE_0 :: 0x350
APIC_ERROR :: 0x370
APIC_TIMER_START :: 0x380
APIC_TIMER_NOW :: 0x390
APIC_TIMER_DIVIDE :: 0x3E0
APIC_MASKED :: 1 << 16
APIC_PERIODIC :: 1 << 17

apic_msr: bool // The registers are model-specific registers (x2APIC), not memory.
apic_address: uintptr
timer_count: u32 // The counts of the timer in one tick.
direct_map_size: u64

apic_read :: proc "contextless" (register: u32) -> u32 {
	if apic_msr {
		return u32(msr_read(0x800 + register >> 4))
	}
	return intrinsics.volatile_load((^u32)(apic_address + uintptr(register)))
}

apic_write :: proc "contextless" (register: u32, value: u32) {
	if apic_msr {
		msr_write(0x800 + register >> 4, u64(value))
	} else {
		intrinsics.volatile_store((^u32)(apic_address + uintptr(register)), value)
	}
}

apic_id :: proc "contextless" () -> u32 {
	return apic_msr ? apic_read(APIC_ID) : apic_read(APIC_ID) >> 24
}

// apic_send sends an interrupt to the processor with this identifier.
// value is a vector, or a start command.
apic_send :: proc "contextless" (id: u32, value: u32) {
	if apic_msr {
		msr_write(0x800 + APIC_SEND_LOW >> 4, u64(id) << 32 | u64(value))
		return
	}
	apic_write(APIC_SEND_HIGH, id << 24)
	apic_write(APIC_SEND_LOW, value)
	for apic_read(APIC_SEND_LOW) & (1 << 12) != 0 {
		intrinsics.cpu_relax()
	}
}

// apic_start finds the registers. The first processor runs it once.
apic_start :: proc "contextless" () {
	base := msr_read(MSR_APIC_BASE)
	if base & (1 << 11) == 0 {
		base |= 1 << 11
		msr_write(MSR_APIC_BASE, base)
	}
	apic_msr = base & (1 << 10) != 0
	apic_address = info.DIRECT_MAP_BASE + uintptr(base & 0x000F_FFFF_FFFF_F000)
}

// apic_setup prepares the controller of the processor that runs it.
apic_setup :: proc "contextless" (cpu: ^Processor) {
	base := msr_read(MSR_APIC_BASE)
	if apic_msr && base & (1 << 10) == 0 {
		msr_write(MSR_APIC_BASE, base | 1 << 10 | 1 << 11)
	}
	apic_write(APIC_PRIORITY, 0)
	apic_write(APIC_SPURIOUS, 0x100 | VECTOR_SPURIOUS)
	apic_write(APIC_ERROR, APIC_MASKED)
	// The 8259 interrupts the first processor only.
	apic_write(APIC_LINE_0, cpu.index == 0 ? 0x700 : APIC_MASKED)
}

// pit_wait waits with the 8254 timer, channel 2. At most 50000 microseconds.
pit_wait :: proc "contextless" (microseconds: u64) {
	count := microseconds * 1193182 / 1_000_000
	port_write_8(0x61, port_read_8(0x61) &~ 3) // The gate is low: the count does not run.
	port_write_8(0x43, 0xB0) // Channel 2, one count, then the output goes high.
	port_write_8(0x42, u8(count))
	port_write_8(0x42, u8(count >> 8))
	port_write_8(0x61, port_read_8(0x61) &~ 2 | 1)
	for port_read_8(0x61) & 0x20 == 0 {
		intrinsics.cpu_relax()
	}
}

// timer_calibrate measures the timer of the processor against the 8254.
timer_calibrate :: proc "contextless" () {
	MEASURE_TICKS :: 10
	apic_write(APIC_TIMER_DIVIDE, 3) // Divide by 16.
	apic_write(APIC_TIMER, APIC_MASKED)
	apic_write(APIC_TIMER_START, max(u32))
	cycles := cycles_now()
	pit_wait(MEASURE_TICKS * 1_000_000 / TICKS_PER_SECOND)
	timer_count = (max(u32) - apic_read(APIC_TIMER_NOW)) / MEASURE_TICKS
	// The same wait measures the cycle counter: the boot record uses it.
	cycle_frequency = (cycles_now() - cycles) * TICKS_PER_SECOND / MEASURE_TICKS
	apic_write(APIC_TIMER_START, 0)
	if timer_count == 0 {
		log("kernel: the timer of the processor does not count")
		machine_stop(1)
	}
}

// timer_start starts the tick of the processor that runs it.
timer_start :: proc "contextless" () {
	apic_write(APIC_TIMER_DIVIDE, 3)
	apic_write(APIC_TIMER, VECTOR_TIMER | APIC_PERIODIC)
	apic_write(APIC_TIMER_START, timer_count)
}

// timer_pause stops, or continues, the tick of the processor that runs it.
// An idle processor needs no tick, except the first processor: it counts
// the time.
timer_pause :: proc "contextless" (pause: bool) {
	apic_write(APIC_TIMER, VECTOR_TIMER | APIC_PERIODIC | (pause ? APIC_MASKED : 0))
}

// acpi_bytes gives count bytes of physical memory, or nil if the direct
// map does not hold them.
@(private = "file")
acpi_bytes :: proc "contextless" (address: u64, count: u64) -> [^]u8 {
	if address == 0 || address + count > direct_map_size {
		return nil
	}
	return ([^]u8)(direct(address, u8))
}

@(private = "file")
load :: proc "contextless" (bytes: [^]u8, offset: u64, $T: typeid) -> T {
	return intrinsics.unaligned_load((^T)(&bytes[offset]))
}

ACPI_HEADER_SIZE :: 36

// acpi_table gives the ACPI table with this signature, and its size.
@(private = "file")
acpi_table :: proc "contextless" (root: u64, signature: string) -> (table: [^]u8, size: u64) {
	record := acpi_bytes(root, 36)
	if record == nil || string(record[:8]) != "RSD PTR " {
		return nil, 0
	}
	list_address := u64(load(record, 16, u32))
	entry_size := u64(4)
	if record[15] >= 2 && load(record, 24, u64) != 0 {
		list_address = load(record, 24, u64)
		entry_size = 8
	}
	list := acpi_bytes(list_address, ACPI_HEADER_SIZE)
	if list == nil {
		return nil, 0
	}
	list_size := u64(load(list, 4, u32))
	if acpi_bytes(list_address, list_size) == nil {
		return nil, 0
	}
	for offset := u64(ACPI_HEADER_SIZE); offset + entry_size <= list_size; offset += entry_size {
		address := entry_size == 8 ? load(list, offset, u64) : u64(load(list, offset, u32))
		table = acpi_bytes(address, ACPI_HEADER_SIZE)
		if table == nil || string(table[:4]) != signature {
			continue
		}
		size = u64(load(table, 4, u32))
		if acpi_bytes(address, size) != nil {
			return table, size
		}
	}
	return nil, 0
}

// processors_find reads the identifiers of the processors that the firmware
// lists as usable.
@(private = "file")
processors_find :: proc "contextless" (root: u64, ids: []u32) -> (count: int) {
	table, size := acpi_table(root, "APIC")
	if table == nil {
		return 0
	}
	for offset := u64(44); offset + 2 <= size; {
		kind := table[offset]
		length := u64(table[offset + 1])
		if length < 2 || offset + length > size {
			break
		}
		id: u32
		flags: u32
		switch {
		case kind == 0 && length >= 8:
			id = u32(table[offset + 3])
			flags = load(table, offset + 4, u32)
		case kind == 9 && length >= 16 && apic_msr:
			id = load(table, offset + 4, u32)
			flags = load(table, offset + 8, u32)
		}
		if flags & 1 != 0 && count < len(ids) {
			ids[count] = id
			count += 1
		}
		offset += length
	}
	return count
}

// The parameters at the end of the start code: see processor.asm.
Ap_Parameters :: struct {
	table:     u32,
	cr0:       u32,
	efer:      u32,
	mxcsr:     u32,
	stack:     u64,
	parameter: u64,
	entry:     u64,
}

AP_BASE :: 0x8000
started_count: u32
first_cr4: u64

foreign _ {
	ap_start_begin: u8
	ap_start_end: u8
}

// processors_start starts each other processor. The first processor runs
// it once, with the kernel lock: a new processor waits for the lock, then
// looks for a thread.
processors_start :: proc "contextless" (boot: ^info.Boot_Info) {
	direct_map_size = boot.direct_map_size
	ids: [PROCESSOR_CAPACITY]u32
	count := processors_find(boot.acpi_root, ids[:])
	if count <= 1 {
		return
	}
	// The start code runs at a fixed page of the first MiB. The kernel
	// keeps the first MiB out of the page frames that it gives.
	page_free := false
	for range in info.physical_slice(boot.memory_ranges, boot.memory_range_count, info.Memory_Range) {
		if range.kind == .Free && range.start <= AP_BASE && AP_BASE + PAGE_SIZE <= range.start + range.page_count * PAGE_SIZE {
			page_free = true
		}
	}
	// A processor starts with 32-bit addresses. Its first page table maps
	// the low addresses to the same physical addresses.
	table := frames_allocate(1)
	if !page_free || table == 0 || table >= 1 << 32 {
		log("kernel: cannot start the other processors: no low memory for the start code")
		if table != 0 {
			frames_free(table, 1)
		}
		return
	}
	direct(table, [512]u64)^ = direct(kernel_table, [512]u64)^
	direct(table, [512]u64)[0] = direct(table, [512]u64)[(u64(info.DIRECT_MAP_BASE) >> 39) & 511]

	code_size := int(uintptr(&ap_start_end) - uintptr(&ap_start_begin))
	code := ([^]u8)(direct(AP_BASE, u8))
	intrinsics.mem_copy_non_overlapping(code, &ap_start_begin, code_size)
	parameters := (^Ap_Parameters)(&code[code_size - size_of(Ap_Parameters)])
	parameters.table = u32(table)
	parameters.cr0 = u32(cr0_read())
	parameters.efer = u32(msr_read(0xC000_0080)) &~ (1 << 10) // Not the bit "long mode is active": the processor sets it.
	parameters.entry = u64(uintptr(rawptr(processor_entry)))
	first_cr4 = cr4_read()

	self := apic_id()
	for id in ids[:count] {
		if id == self || processor_count == PROCESSOR_CAPACITY {
			continue
		}
		cpu := processor_create(processor_count, id)
		if cpu == nil {
			break
		}
		parameters.stack = cpu.stack_top
		parameters.parameter = u64(uintptr(cpu))
		before := intrinsics.atomic_load(&started_count)
		apic_send(id, 0x4500) // Reset.
		pit_wait(10_000)
		started := false
		start: for _ in 0 ..< 2 {
			apic_send(id, 0x4600 | AP_BASE >> 12) // Start at the page.
			for _ in 0 ..< 100 {
				pit_wait(1_000)
				if intrinsics.atomic_load(&started_count) != before {
					started = true
					break start
				}
			}
		}
		if !started {
			log("kernel: the processor ", u64(id), " did not start")
			apic_send(id, 0x4500) // It stays in reset: its record ends.
			pit_wait(10_000)
			frames_free(physical_of(cpu), (size_of(Processor) + PAGE_SIZE - 1) / PAGE_SIZE)
			continue
		}
		processors[processor_count] = cpu
		processor_count += 1
	}
	frames_free(table, 1)
}

// processor_entry is where each other processor arrives from the start code.
processor_entry :: proc "c" (cpu: ^Processor) -> ! {
	cr3_write(kernel_table)
	cr4_write(first_cr4)
	processor_setup(cpu)
	timer_start()
	intrinsics.atomic_add(&started_count, 1)
	lock_acquire(cpu)
	schedule()
}
