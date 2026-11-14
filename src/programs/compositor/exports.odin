package compositor

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/pointer_pictures"
import "modus:contract/ring"
import "modus:support/system"

// The compositor is also a service: its exports give the place of the
// pointer and the windows, as tables of records that a caller in another
// program reads with no code of the compositor. The test
// tool reads them through the remote service before each press of the
// pointer, so that a press lands where the scenario wants it.
//
// The place of the pointer and the windows are facts of the screen: another
// program must not learn where the input goes. The exports give them only
// to a caller that acts for the principal. A Record result has no error record, so it cannot
// refuse (docs/MODULE_CONTRACT.md, section 4): pointer() is a Table of one
// row.

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
	keys:    i64, // The key records that the input service sent since the start: each press and each release is one. The palette takes some of them, and a record goes to no window when none is open.
	keys_waiting: i64, // The key records that wait in the compositor for a window whose ring is full.
	keys_refused: i64, // The key records that the compositor lost since the start: the ring of the window and the queue of the compositor for it were full. 0 on a system that works.
	menu:    [16]u8, // The menu of the bar that is open: "programs", "windows", or empty.
	palette:  i64, // The state of the palette: 0 closed; 1 the search; 2 it asks for a second Enter; 3 it waits for its provider; 4 it shows a result; 5 it has the form of a command. Not 0: it takes the keys.
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
	keyboard: i64, // 1: the keys go to the window: the one with the focus, while the palette is closed.
	presents: i64, // The Present records that the program of the window sent since it created its surface.
	waits:    i64, // 1: a Present of the program changed a part of the screen, and no frame drew it yet.
	events_sent: i64, // The event records that the ring of the window took since the window opened: keys, pointer records, changes of the settings.
	events_unread: i64, // The event records in the ring that the program did not read yet. The program writes the count of its reads: it says this of itself.
	events_waiting: i64, // The event records that wait in the compositor, because the ring of the window is full.
	keys_refused: i64, // The key records of this window that the compositor lost: the ring and the queue were full.
}

// What the screen shows against what the compositor received: screen().
Screen :: struct {
	frames:   i64, // The frames that the compositor drew since the start.
	presents: i64, // The Present records of all the programs since the start.
	damage:   i64, // The damage rectangles that wait for the next frame.
	desktop:  i64, // 1: a change of the desktop itself waits for the next frame: the pointer, the bar, a menu, the palette, a window that appeared, moved or closed.
}

ERROR_ACTS_FOR_PRINCIPAL :: -1

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
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// pointer gives the place of the pointer on the screen, its buttons, the menu of the bar that is open, the state of the palette, and the name of the pointer shape, as one row. The result is 1, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
//
// **What it is for.** A caller that drives the desktop from outside, as
// the machine test does through the remote service, reads where the
// pointer is and what is open before it moves the pointer or presses a
// button. The row is the state after the input records that the compositor
// took before the call.
//
// **The row** (`Pointer`):
//
// - `x`, `y`: the place of the pointer, in pixels from the top left corner.
//   It is the point where a press acts: the hot spot of the picture.
// - `buttons`: bit 0 the left button, bit 1 the right one, bit 2 the
//   middle one.
// - `moves`, `keys`: the pointer records and the key records that the
//   input service sent since the start.
// - `keys_waiting`: the key records that wait in the compositor for a
//   window whose ring is full. They go to that window, in order, when it
//   reads.
// - `keys_refused`: the key records that the compositor lost since the
//   start, because the ring of a window and the queue of the compositor
//   for it were both full. It is 0 on a system that works; the log has a
//   line for each loss period.
// - `menu`: `programs`, `windows`, or empty.
// - `palette`: the state of the palette: 0 while it is closed; 1 while it
//   is open and the input searches; 2 while it asks for a second Enter; 3
//   while it waits for what its provider gives; 4 while it shows a result;
//   5 while its input band is the form of a command with parameters.
//   Open, it takes the keys.
// - `shape`: the name of the pointer shape on the screen (`arrow`, `move`,
//   `text`...; docs/POINTERS.md).
//
// **Grant**: the caller must **act for the principal**. A caller without
// it gets the error kind `No_Grant`, with the result -1: the place of the
// pointer tells where the input goes.
//
// ```
// connect("compositor")
// compositor.pointer()
// ```
@(export, link_name = "pointer")
pointer :: proc "c" (result: ^[]Pointer, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {x = i64(pointer_x), y = i64(pointer_y), buttons = i64(buttons), moves = i64(pointer_moves), keys = i64(key_records), keys_waiting = i64(keys_waiting_of_all_windows()), keys_refused = i64(key_records_refused), palette = i64(palette_panel.state)}
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

// windows gives one row for each window, the front one first: its title, its place and its size with the frame, its order from the front, whether it has the focus, and whether the keys go to it. The result is the count of rows, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
//
// **What it is for.** A caller finds a window by its title, then presses
// its title bar or its close button at a place that it computes from the
// row. The machine test does so before each drag.
//
// **A row** (`Window`):
//
// - `title`: the name of the program of the window.
// - `x`, `y`, `width`, `height`: the window with its frame and its title
//   bar, in pixels of the screen. The title bar is the top 24 pixels; the
//   close button is the square of 24 pixels at its right end.
// - `order`: 0 for the window in front, 1 for the one under it, and so on.
// - `focus`: 1 for the window in front.
// - `keyboard`: 1 when the keys go to the window: the window in front,
//   while the palette is closed.
// - `presents`: the `Present` records that the program of the window sent
//   since it created its surface.
// - `waits`: 1 while a `Present` of the program changed a part of the
//   screen and no frame drew it yet. 0: the screen shows the last picture
//   that the program sent before the call.
// - `events_sent`, `events_unread`: the event records that the ring of the
//   window took, and the ones in the ring that the program did not read
//   yet.
// - `events_waiting`: the event records that wait in the compositor while
//   the ring of the window is full (256 at most).
// - `keys_refused`: the key records of this window that were lost, because
//   256 records already waited.
//
// Only a program that created its surface has a window. If the table of
// the caller has fewer places than windows, the rows of the windows at the
// back are missing, and the result still gives the count of all windows.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// where(compositor.windows(), "focus", 1)
// ```
@(export, link_name = "windows")
windows :: proc "c" (result: ^[]Window, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	for position in 0 ..< order_count {
		row := order_count - 1 - position
		if row >= len(result^) {
			continue
		}
		client := &clients[order[position]]
		queue := &window_queues[order[position]]
		result[row] = {
			x        = i64(client.x),
			y        = i64(client.y),
			width    = i64(client.surface.width + 2 * BORDER),
			height   = i64(client.surface.height + TITLE_HEIGHT + BORDER),
			order    = i64(row),
			focus    = row == 0 ? 1 : 0,
			keyboard = row == 0 && !palette_is_open() ? 1 : 0,
			presents = i64(client.presents),
			waits    = client.present_waits ? 1 : 0,
			events_sent = i64(queue.delivered),
			events_unread = i64(ring.count(&client.ring.completions)),
			events_waiting = i64(queue.count + (queue.move_waits ? 1 : 0)),
			keys_refused = i64(queue.refused[.Key]),
		}
		copy(result[row].title[:len(result[row].title) - 1], system.name_of(client.title[:]))
	}
	return i64(order_count)
}

// screen gives the frames that the compositor drew, the Present records that it received, the damage rectangles that wait for the next frame, and whether a change of the desktop itself waits, as one row. The result is 1, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
//
// **What it is for.** A caller that takes a picture of the screen from
// outside, as the machine test does through the remote service, reads if
// the screen shows what the compositor received. The compositor draws a
// frame at most once in 16 ms: between a change and its frame, the screen
// shows the picture before.
//
// **The row** (`Screen`):
//
// - `frames`: the frames drawn since the start.
// - `presents`: the `Present` records of all the programs since the start.
// - `damage`: the damage rectangles that wait for the next frame, of the
//   desktop and of the programs.
// - `desktop`: 1 while a change of the desktop itself waits for the next
//   frame: the pointer, the bar, a menu, the palette, a window that
//   appeared, moved or closed. The `Present` of a program is not in it:
//   `windows()` gives it for each window, in `waits`.
//
// The row counts each record that a program sent before the call: the
// compositor reads the ring of each window before it answers. It does not
// say that a program sent its last picture: a program that still computes
// has sent nothing yet. The state of the threads of the program says that
// (`monitor.programs()`).
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("compositor")
// compositor.screen()
// ```
@(export, link_name = "screen")
screen_state :: proc "c" (result: ^[]Screen, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {frames = i64(frames), presents = i64(presents), damage = i64(damage_count), desktop = desktop_change_waits ? 1 : 0}
	}
	return 1
}
