package kernel

import "base:intrinsics"
import "contract:cut_mark"
import op "contract:operation"

// The serial port is the log of the kernel. It is the only device that the
// kernel has code for, apart from the processor and its interrupt controller.

SERIAL_PORT :: 0x3F8
DEBUG_EXIT_PORT :: 0xF4 // The isa-debug-exit device of QEMU: a write ends the machine.

foreign _ {
	port_write_8 :: proc "c" (port: u16, value: u8) ---
	port_read_8 :: proc "c" (port: u16) -> u8 ---
	processor_stop :: proc "c" () -> ! ---
}

serial_start :: proc "contextless" () {
	port_write_8(SERIAL_PORT + 1, 0x00) // no interrupts
	port_write_8(SERIAL_PORT + 3, 0x80) // set the divisor
	port_write_8(SERIAL_PORT + 0, 0x01) // 115200 baud
	port_write_8(SERIAL_PORT + 1, 0x00)
	port_write_8(SERIAL_PORT + 3, 0x03) // 8 bits, no parity, one stop bit
	port_write_8(SERIAL_PORT + 2, 0xC7) // queues on
}

log_bytes :: proc "contextless" (bytes: []u8) {
	for b in bytes {
		for port_read_8(SERIAL_PORT + 5) & 0x20 == 0 {}
		port_write_8(SERIAL_PORT, b)
	}
}

// The log (operation.Log_Record). Each record goes to two places: the
// serial port, as one line of text, and the memory object of the log,
// that programs with the grant read.
Hex :: distinct u64

Log_Part :: union {
	string,
	u64,
	Hex,
}

log_head: ^op.Log_Head // nil before log_start.
log_records: [^]op.Log_Record
log_serial_only: bool // The kernel reports its own fault: it takes no lock, and writes the serial port only.
// The log lock protects the serial port, the records of the log and their
// counter (docs/ARCHITECTURE.md, "Locks of the kernel").
log_lock: Lock

// The processor that reports a fault of the kernel: its identifier plus one,
// or 0 when no processor reports.
log_fault_reporter: u32

// FAULT_REPORT_WAIT_MILLISECONDS: how long the reporter waits for a line
// that another processor writes. The longest line is a Log operation of
// 4096 bytes, about 360 ms at 115200 baud.
FAULT_REPORT_WAIT_MILLISECONDS :: 1000

// The count of the reports that began: 1 is a report; 2 or more is a fault
// inside the report of a fault.
log_fault_report_depth: u32

// fault_report_begin makes this processor the only writer of the serial
// port, before the kernel reports its own fault. The report takes no lock,
// because the processor can hold any lock, and it reads nothing through
// the gs register: a fault of the kernel can arrive with the gs of a
// program, and a read through it would be a second fault, with no end.
// Without this procedure, the report and a line that another processor
// writes arrive as mixed bytes, and nobody can read the fault.
//   - A second processor that has a fault of its own stops: one report.
//   - A processor that starts a line after this stops in log_take.
//   - A processor that is in the middle of a line ends it: the reporter
//     waits until the log lock has no holder and no waiter, a bounded time.
//     When the reporter holds the log lock itself, or when the wait ends by
//     its bound, the report starts on a new line and says so.
//   - A fault inside the report: one fixed line, and the machine stops.
fault_report_begin :: proc "contextless" () {
	if !lock_ready {
		// One processor, with no record yet: nobody else writes.
		intrinsics.atomic_store(&log_serial_only, true)
		return
	}
	identifier := apic_id()
	self := identifier + 1
	if _, first := intrinsics.atomic_compare_exchange_strong(&log_fault_reporter, 0, self); !first {
		if intrinsics.atomic_load(&log_fault_reporter) != self {
			processor_stop()
		}
	}
	intrinsics.atomic_store(&log_serial_only, true)
	if intrinsics.atomic_add(&log_fault_report_depth, 1) != 0 {
		log_bytes(transmute([]u8)string("\r\nkernel: a fault inside the report of a fault of the kernel\r\n"))
		machine_stop(2)
	}
	// The record of this processor, by its identifier and not by gs.
	holds_the_log_lock := false
	for cpu in processors[:min(processor_count, PROCESSOR_CAPACITY)] {
		if cpu != nil && cpu.apic_id == identifier {
			holds_the_log_lock = cpu.held[.Log] != 0
		}
	}
	line_is_whole := false
	if !holds_the_log_lock {
		limit := cycles_now() + cycle_frequency / 1000 * FAULT_REPORT_WAIT_MILLISECONDS
		for {
			if intrinsics.atomic_load(&log_lock.serving) == intrinsics.atomic_load(&log_lock.next) {
				line_is_whole = true
				break
			}
			// Before the timer is measured the frequency is 0: no wait.
			if cycles_now() >= limit {
				break
			}
			intrinsics.cpu_relax()
		}
	}
	if !line_is_whole {
		log_bytes(transmute([]u8)string("\r\nkernel: the line above is cut: the report of a fault of the kernel starts here\r\n"))
	}
}

// log_take takes the log lock, except before the first processor has its
// record, and when the kernel reports its own fault: then only the reporter
// writes, and each other processor stops here.
log_take :: proc "contextless" () -> bool {
	if intrinsics.atomic_load(&log_serial_only) {
		if lock_ready && intrinsics.atomic_load(&log_fault_reporter) != apic_id() + 1 {
			processor_stop()
		}
		return false
	}
	lock_take(&log_lock, .Log)
	if intrinsics.atomic_load(&log_serial_only) {
		// A report began between the look above and the take. The reporter
		// writes now, or waits for this lock: free it, so that it does not
		// wait for a processor that stops.
		lock_free(&log_lock, .Log)
		processor_stop()
	}
	return true
}

log_free :: proc "contextless" (taken: bool) {
	if taken {
		lock_free(&log_lock, .Log)
	}
}

@(private = "file")
HEX_DIGITS :: [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

@(rodata)
KERNEL_NAME := [6]u8{'k', 'e', 'r', 'n', 'e', 'l'}

// log_start makes the memory object of the log.
log_start :: proc "contextless" () {
	physical := frames_allocate(op.LOG_PAGES)
	if physical == 0 {
		return
	}
	intrinsics.mem_zero(direct(physical, u8), op.LOG_PAGES * PAGE_SIZE)
	head := direct(physical, op.Log_Head)
	head.capacity = op.LOG_RECORD_CAPACITY
	log_records = ([^]op.Log_Record)(direct(physical + size_of(op.Log_Head), op.Log_Record))
	log_head = head
}

// log writes one record of the kernel with no channel.
log :: proc "contextless" (parts: ..Log_Part) {
	log_in("", .Info, ..parts)
}

// log_in writes one record of the kernel. A part is a string, an integer
// (decimal), or a Hex.
//
// The text of one record of the kernel has at most 352 bytes: the stack of
// the kernel is small. A longer text ends with the cut mark and the count
// of the missing bytes (contract:cut_mark): never cut in silence.
log_in :: proc "contextless" (channel: string, level: op.Log_Level, parts: ..Log_Part) {
	buffer: [352]u8
	count := 0
	dropped := 0
	put :: proc "contextless" (buffer: []u8, count: ^int, dropped: ^int, bytes: []u8) {
		taken := copy(buffer[count^:], bytes)
		count^ += taken
		dropped^ += len(bytes) - taken
	}
	for part in parts {
		switch value in part {
		case string:
			put(buffer[:], &count, &dropped, transmute([]u8)value)
		case u64:
			digits: [20]u8
			digit_count := 0
			rest := value
			for {
				digits[len(digits) - 1 - digit_count] = u8('0' + rest % 10)
				digit_count += 1
				rest /= 10
				if rest == 0 {break}
			}
			put(buffer[:], &count, &dropped, digits[len(digits) - digit_count:])
		case Hex:
			digits: [16]u8
			alphabet := HEX_DIGITS
			for i in 0 ..< 16 {
				digits[i] = alphabet[(u64(value) >> uint(60 - 4 * i)) & 0xF]
			}
			put(buffer[:], &count, &dropped, digits[:])
		}
	}
	count, _, _ = cut_mark.apply(buffer[:], count, dropped)
	taken := log_take()
	log_bytes(buffer[:count])
	log_bytes({'\r', '\n'})
	name := KERNEL_NAME
	log_record(0, 0, name[:], transmute([]u8)channel, level, buffer[:count])
	log_free(taken)
}

// log_record adds a text to the memory object of the log: one record, or
// more if the text is long. The caller holds the log lock.
log_record :: proc "contextless" (program: u32, thread: u32, name: []u8, channel: []u8, level: op.Log_Level, text: []u8) {
	if log_head == nil || log_serial_only {
		return
	}
	rest := text
	for {
		part := rest[:min(len(rest), op.LOG_TEXT_CAPACITY)]
		rest = rest[len(part):]
		written := log_head.written
		record := &log_records[written % op.LOG_RECORD_CAPACITY]
		record^ = {
			sequence   = written,
			time       = microseconds(cycles_now()),
			program    = program,
			thread     = thread,
			level      = level,
			more       = u8(len(rest) != 0),
			text_count = u16(len(part)),
		}
		copy(record.name[:len(record.name) - 1], name)
		copy(record.channel[:], channel)
		copy(record.text[:], part)
		// The record is complete before a reader can see it.
		intrinsics.atomic_store(&log_head.written, written + 1)
		if len(rest) == 0 {
			break
		}
	}
	word_wake(physical_of(&log_head.written), max(u64))
}

// machine_stop ends the machine under QEMU, or halts the processor.
machine_stop :: proc "contextless" (code: u8) -> ! {
	// Each other processor stops at its next kernel entry.
	if processor_count > 1 {
		intrinsics.atomic_store(&machine_stopping, true)
		self := apic_id()
		for cpu in processors[:processor_count] {
			if cpu.apic_id != self {
				apic_send(cpu.apic_id, VECTOR_SYNC)
			}
		}
	}
	port_write_8(DEBUG_EXIT_PORT, code)
	processor_stop()
}
