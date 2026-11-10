package kernel

import "base:intrinsics"
import op "operation"

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
log_serial_only: bool // The kernel reports its own fault: it can be without the kernel lock.

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
log_in :: proc "contextless" (channel: string, level: op.Log_Level, parts: ..Log_Part) {
	buffer: [352]u8
	count := 0
	put :: proc "contextless" (buffer: []u8, count: ^int, bytes: []u8) {
		for b in bytes {
			if count^ < len(buffer) {
				buffer[count^] = b
				count^ += 1
			}
		}
	}
	for part in parts {
		switch value in part {
		case string:
			put(buffer[:], &count, transmute([]u8)value)
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
			put(buffer[:], &count, digits[len(digits) - digit_count:])
		case Hex:
			digits: [16]u8
			alphabet := HEX_DIGITS
			for i in 0 ..< 16 {
				digits[i] = alphabet[(u64(value) >> uint(60 - 4 * i)) & 0xF]
			}
			put(buffer[:], &count, digits[:])
		}
	}
	log_bytes(buffer[:count])
	log_bytes({'\r', '\n'})
	name := KERNEL_NAME
	log_record(0, 0, name[:], transmute([]u8)channel, level, buffer[:count])
}

// log_record adds a text to the memory object of the log: one record, or
// more if the text is long. The caller holds the kernel lock.
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
