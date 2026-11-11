package compositor

import "contract:errors"
import "contract:isolated"
import "contract:pointer_pictures"
import "support:system"

// The compositor is also a service: its exports give the place of the
// pointer and the windows, as tables of records (property 19). The test
// tool reads them through the remote service before each press of the
// pointer, so that a press lands where the scenario wants it.
//
// The place of the pointer and the windows are facts of the screen of the
// person (property 20): the exports give them only to a caller that acts
// for the person. A Record result cannot refuse (docs/MODULE_CONTRACT.md,
// section 4: it has no error record), so pointer() is a Table of one row.

// The values of the context that name the file of this program: 0 to 3 are
// the screen (VALUE_WIDTH ...). The root service writes the same numbers.
VALUE_FILE_ADDRESS :: 4
VALUE_FILE_SIZE :: 5

// The place of the pointer: pointer().
Pointer :: struct {
	x:       i64, // From the left of the screen, in pixels.
	y:       i64, // From the top of the screen.
	buttons: i64, // Bit 0: the left button is down; bit 1: the right one; bit 2: the middle one.
	moves:   i64, // The pointer records that the input service sent since the start.
	keys:    i64, // The key records that the input service sent since the start: each press and each release is one.
	menu:    [16]u8, // The menu of the bar that is open: "programs", "windows", or empty.
	launcher: i64, // 1: the launcher is open, and it takes the keys.
	shape:    [32]u8, // The name of the pointer shape on the screen: "arrow", "move", "text", ... (docs/POINTERS.md).
}

// One row for each window, the front one first: windows().
Window :: struct {
	title:    [32]u8,
	x:        i64, // The place of the window with its frame and its title bar.
	y:        i64,
	width:    i64, // The size of the window with its frame and its title bar.
	height:   i64,
	order:    i64, // 0: the front window; 1: the one under it; ...
	focus:    i64, // 1: the window has the focus: the front one.
	keyboard: i64, // 1: the keys go to the window: the one with the focus, while the launcher is closed.
}

ERROR_PERSON :: -1

service: system.Service
pointer_moves: u64
key_records: u64

// service_start opens the service ring. The file of this program is at
// values 4 and 5, not at the places of a service that system.service_open
// reads (values 1 and 2 are the screen here): it reads a copy of the
// context with the two values at their places.
service_start :: proc "contextless" (ctx: ^system.Context) {
	copied := ctx^
	copied.values[system.GRANT_VALUE_FILE_ADDRESS] = ctx.values[VALUE_FILE_ADDRESS]
	copied.values[system.GRANT_VALUE_FILE_SIZE] = ctx.values[VALUE_FILE_SIZE]
	service, _ = system.service_open(&copied)
}

@(private = "file")
person :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_PERSON != 0
}

// pointer gives the place of the pointer on the screen, its buttons, the menu of the bar that is open, whether the launcher is open, and the name of the pointer shape, as one row. The result is 1, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the person).
@(export, link_name = "pointer")
pointer :: proc "c" (result: ^[]Pointer, error: ^errors.Error_Record) -> i64 {
	if !person() {
		return errors.fail(error, ERROR_PERSON, .No_Grant, .Person)
	}
	if len(result^) > 0 {
		result[0] = {x = i64(pointer_x), y = i64(pointer_y), buttons = i64(buttons), moves = i64(pointer_moves), keys = i64(key_records), launcher = launcher_open ? 1 : 0}
		copy(result[0].shape[:len(result[0].shape) - 1], pointer_pictures.SHAPE_NAMES[pointer_shape_under()])
		#partial switch menu_open {
		case .Programs:
			copy(result[0].menu[:], "programs")
		case .Windows:
			copy(result[0].menu[:], "windows")
		}
	}
	return 1
}

// windows gives one row for each window, the front one first: its title, its place and its size with the frame, its order from the front, whether it has the focus, and whether the keys go to it. The result is the count of rows, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the person).
@(export, link_name = "windows")
windows :: proc "c" (result: ^[]Window, error: ^errors.Error_Record) -> i64 {
	if !person() {
		return errors.fail(error, ERROR_PERSON, .No_Grant, .Person)
	}
	for position in 0 ..< order_count {
		row := order_count - 1 - position
		if row >= len(result^) {
			continue
		}
		client := &clients[order[position]]
		result[row] = {
			x        = i64(client.x),
			y        = i64(client.y),
			width    = i64(client.surface.width + 2 * BORDER),
			height   = i64(client.surface.height + TITLE_HEIGHT + BORDER),
			order    = i64(row),
			focus    = row == 0 ? 1 : 0,
			keyboard = row == 0 && !launcher_open ? 1 : 0,
		}
		copy(result[row].title[:len(result[row].title) - 1], system.name_of(client.title[:]))
	}
	return i64(order_count)
}
