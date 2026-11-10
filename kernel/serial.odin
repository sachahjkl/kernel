package kernel

import "base:intrinsics"

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

// log writes its parts on the serial port, then a line end.
// A part is a string, an integer (decimal), or a Hex.
Hex :: distinct u64

@(private = "file")
HEX_DIGITS :: [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

log :: proc "contextless" (parts: ..union {
		string,
		u64,
		Hex,
	}) {
	for part in parts {
		switch value in part {
		case string:
			log_bytes(transmute([]u8)value)
		case u64:
			digits: [20]u8
			count := 0
			rest := value
			for {
				digits[len(digits) - 1 - count] = u8('0' + rest % 10)
				count += 1
				rest /= 10
				if rest == 0 {break}
			}
			log_bytes(digits[len(digits) - count:])
		case Hex:
			digits: [16]u8
			alphabet := HEX_DIGITS
			for i in 0 ..< 16 {
				digits[i] = alphabet[(u64(value) >> uint(60 - 4 * i)) & 0xF]
			}
			log_bytes(digits[:])
		}
	}
	log_bytes({'\r', '\n'})
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
