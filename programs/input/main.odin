// The input service: the device service of the PS/2 keyboard and mouse
// (docs/ARCHITECTURE.md, U4). It has the ports of the controller and its two
// interrupts, and nothing else. It sends input records to the compositor.
package input

import "support:display"
import "contract:ring"
import "support:system"

// The context of this service.
GRANT_RING :: 0
GRANT_PORTS :: 1
GRANT_KEYBOARD_INTERRUPT :: 2
GRANT_MOUSE_INTERRUPT :: 3

PORT_DATA :: 0x60
PORT_STATUS :: 0x64
STATUS_OUTPUT_FULL :: 1 << 0
STATUS_INPUT_FULL :: 1 << 1
STATUS_MOUSE :: 1 << 5

// Scan code set 1, United States layout: the character of each key, without
// and with shift.
@(rodata)
characters := [2][0x3A]u8 {
	{0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8, '\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' '},
	{0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8, '\t', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0, 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' '},
}

SCAN_LEFT_SHIFT :: 0x2A
SCAN_RIGHT_SHIFT :: 0x36
SCAN_CONTROL :: 0x1D
SCAN_EXTENDED :: 0xE0

output: ring.Ring
output_memory: system.Handle
modifiers: u32
extended: bool
packet: [3]u8
packet_count: int

controller_wait_write :: proc "contextless" () {
	for _ in 0 ..< 100000 {
		if system.port_read_8(PORT_STATUS) & STATUS_INPUT_FULL == 0 {
			return
		}
	}
}

controller_read :: proc "contextless" () -> u8 {
	for _ in 0 ..< 100000 {
		if system.port_read_8(PORT_STATUS) & STATUS_OUTPUT_FULL != 0 {
			break
		}
	}
	return system.port_read_8(PORT_DATA)
}

controller_command :: proc "contextless" (command: u8) {
	controller_wait_write()
	system.port_write_8(PORT_STATUS, command)
}

controller_data :: proc "contextless" (value: u8) {
	controller_wait_write()
	system.port_write_8(PORT_DATA, value)
}

mouse_command :: proc "contextless" (command: u8) {
	controller_command(0xD4) // The next data byte goes to the mouse.
	controller_data(command)
	controller_read() // The mouse answers 0xFA.
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	output_memory = ctx.handles[GRANT_RING]
	status: system.Status
	if output, status = system.ring_open(output_memory); status != .Ok {
		system.log("input: no ring")
		system.stop(1)
	}

	for system.port_read_8(PORT_STATUS) & STATUS_OUTPUT_FULL != 0 {
		system.port_read_8(PORT_DATA)
	}
	controller_command(0xA8) // Enable the mouse port.
	controller_command(0x20) // Read the configuration.
	configuration := controller_read()
	configuration |= 0x03 // Both interrupts on.
	configuration &~= 0x20 // The mouse clock on.
	controller_command(0x60)
	controller_data(configuration)
	mouse_command(0xF6) // Default settings.
	mouse_command(0xF4) // Send motion.
	system.log("input: ok")

	for {
		// An interrupt of this program is an event.
		wait := system.wait_begin()
		for {
			state := system.port_read_8(PORT_STATUS)
			if state & STATUS_OUTPUT_FULL == 0 {
				break
			}
			value := system.port_read_8(PORT_DATA)
			if state & STATUS_MOUSE != 0 {
				mouse_byte(value)
			} else {
				keyboard_byte(value)
			}
		}
		system.wait_end(&wait)
	}
}

keyboard_byte :: proc "contextless" (value: u8) {
	if value == SCAN_EXTENDED {
		extended = true
		return
	}
	pressed := value & 0x80 == 0
	scan := value & 0x7F
	code := u32(scan)
	if extended {
		code |= display.KEY_EXTENDED
		extended = false
	}
	bit: u32
	switch code {
	case SCAN_LEFT_SHIFT, SCAN_RIGHT_SHIFT:
		bit = display.MODIFIER_SHIFT
	case SCAN_CONTROL, SCAN_CONTROL | display.KEY_EXTENDED:
		bit = display.MODIFIER_CONTROL
	}
	if bit != 0 {
		if pressed {
			modifiers |= bit
		} else {
			modifiers &~= bit
		}
	}
	character: u8
	if code < len(characters[0]) {
		character = characters[modifiers & display.MODIFIER_SHIFT][code]
	}
	system.send(&output.commands, ring.Record{kind = u32(display.Input.Key), values = {0 = u64(code), 1 = u64(character), 2 = u64(pressed), 3 = u64(modifiers)}})
}

mouse_byte :: proc "contextless" (value: u8) {
	if packet_count == 0 && value & 0x08 == 0 {
		return // Not the first byte of a packet.
	}
	packet[packet_count] = value
	packet_count += 1
	if packet_count < len(packet) {
		return
	}
	packet_count = 0
	motion_x := i64(packet[1]) - (packet[0] & 0x10 != 0 ? 256 : 0)
	motion_y := i64(packet[2]) - (packet[0] & 0x20 != 0 ? 256 : 0)
	system.send(&output.commands, ring.Record{kind = u32(display.Input.Pointer), values = {0 = u64(motion_x), 1 = u64(-motion_y), 2 = u64(packet[0] & 0x07)}})
}
