// The display protocol, and the code that a program uses to show a surface.
//
// A program and the compositor share one ring. The program sends command
// records; the compositor sends input as completion records. The pixels of
// the surface are memory that the program creates and grants to the
// compositor. No pixel goes through the ring or through the kernel.
package display

import "../graphics"
import "../ring"
import "../system"

Command :: enum u32 {
	None           = 0,
	Surface_Create = 1, // values: memory handle (in the compositor), width, height, title (4 values)
	Present        = 2, // The pixels of the surface changed.
}

Event_Kind :: enum u32 {
	None    = 0,
	Key     = 1, // values: code, character, 1 when pressed, modifiers
	Pointer = 2, // values: x, y in the surface (signed), buttons
}

// The ring between the root service and the compositor.
Control :: enum u32 {
	None          = 0,
	Client_Add    = 1, // root to compositor. values: ring memory handle (in the compositor)
	Client_Remove = 2, // root to compositor. values: the same handle
	Start         = 3, // compositor to root. values: name (4 values)
	Stop          = 4, // compositor to root. values: the handle of the client
}

// The ring from the input service to the compositor.
Input :: enum u32 {
	None    = 0,
	Key     = 1, // values: code, character, 1 when pressed, modifiers
	Pointer = 2, // values: x motion, y motion (signed), buttons
}

KEY_EXTENDED :: 0x100
KEY_ESCAPE :: 0x01
KEY_BACKSPACE :: 0x0E
KEY_ENTER :: 0x1C
KEY_UP :: KEY_EXTENDED | 0x48
KEY_DOWN :: KEY_EXTENDED | 0x50
KEY_LEFT :: KEY_EXTENDED | 0x4B
KEY_RIGHT :: KEY_EXTENDED | 0x4D

MODIFIER_SHIFT :: 1
MODIFIER_CONTROL :: 2

BUTTON_LEFT :: 1
BUTTON_RIGHT :: 2

SURFACE_LIMIT :: 2048 // The largest width and height.

Event :: struct {
	kind:      Event_Kind,
	code:      u32,
	character: u8,
	pressed:   bool,
	modifiers: u32,
	x, y:      int,
	buttons:   u32,
}

Window :: struct {
	ring_memory: system.Handle,
	ring:        ring.Ring,
	surface:     system.Handle,
	canvas:      graphics.Canvas,
}

// open creates a surface and shows it. The program draws in window.canvas,
// then calls present.
open :: proc "contextless" (ctx: ^system.Context, width, height: int, title: string) -> (window: Window, ok: bool) {
	window.ring_memory = ctx.handles[system.GRANT_DISPLAY]
	status: system.Status
	if window.ring, status = system.ring_open(window.ring_memory); status != .Ok {
		return {}, false
	}
	address: rawptr
	pages := (u64(width * height * size_of(graphics.Color)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	window.surface, status = system.memory_create(pages)
	if status != .Ok {
		return {}, false
	}
	address, status = system.memory_map(window.surface)
	if status != .Ok {
		return {}, false
	}
	window.canvas = {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = width}

	// The compositor maps the ring when the root service tells it of this
	// program. Until then, the grant has no receiver.
	granted: system.Handle
	for attempt in 0 ..< 200 {
		granted, status = system.give(window.ring_memory, window.surface, {.Read}) // The compositor reads the surface.
		if status == .Ok {
			break
		}
		system.sleep(system.time() + 5)
		_ = attempt
	}
	if status != .Ok {
		return {}, false
	}
	name := system.name_pack(title)
	command := ring.Record {
		kind = u32(Command.Surface_Create),
		values = {u64(granted), u64(width), u64(height), name[0], name[1], name[2], name[3]},
	}
	system.send(&window.ring.commands, command)
	return window, true
}

present :: proc "contextless" (window: ^Window) {
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Present)})
}

// wait stops the thread until the window has an input event, or until the
// time is deadline. It gives the time.
wait :: proc "contextless" (window: ^Window, deadline: u64 = system.WAIT_FOREVER) -> u64 {
	list: system.Wait
	wait_events(&list, window)
	return system.wait_end(&list, deadline)
}

// wait_events adds the input events of the window to a wait list.
wait_events :: proc "contextless" (list: ^system.Wait, window: ^Window) {
	system.wait_records(list, &window.ring.completions)
}

// next_event gives the next input event of the window, if there is one.
next_event :: proc "contextless" (window: ^Window) -> (event: Event, ok: bool) {
	record := system.receive(&window.ring.completions) or_return
	event.kind = Event_Kind(record.kind)
	#partial switch event.kind {
	case .Key:
		event.code = u32(record.values[0])
		event.character = u8(record.values[1])
		event.pressed = record.values[2] != 0
		event.modifiers = u32(record.values[3])
	case .Pointer:
		event.x = int(i64(record.values[0]))
		event.y = int(i64(record.values[1]))
		event.buttons = u32(record.values[2])
	}
	return event, true
}
