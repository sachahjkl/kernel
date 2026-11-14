// A demonstration of communication between programs: a ring is the one way
// that programs communicate, and a program reaches only the rings that it
// was given.
//
// Each square is a program with its own address space. Each line between two
// squares is a ring: two pages of shared memory. A small colored square is a
// record. A node takes a record from the ring before it, works on it for
// some time, and puts it in the ring after it. No record goes through the
// kernel: the kernel only wakes a program that waits.
//
// This program starts the nodes and gives each one its rings. It maps the
// same rings, so the picture is the real content of the queues.
//
//   left button on a node, or a: add a record
//   right button on a node, or 1 to 6: stop the program, or start it again
//
// A stopped node takes no record: the records wait in the ring before it.
// A ring holds 32 records. When it is full, the node before keeps its
// record and waits.
//
// **What it is for.** It makes the base interface of the kernel visible:
// six isolated programs in a circle, each with four memory objects and no
// other handle. The picture is not a model: it is the content of the real
// queues, which this program maps too. A stopped node shows that the others
// go on, and that its records wait for it in its ring.
//
// **Start**: `start("rings")` in the console, or the bar of the desktop. It
// starts its six nodes from the boot image (the module `node`), each with
// its own work time: 260, 420, 180, 700, 240 and 340 ms. Its budget has room
// for seven programs: itself and the six nodes.
//
// **Grants**, as the root service gives them:
//
// - **Image**: the boot image, read-only, to start the nodes from it.
//
// **What a reader sees**: the circle of nodes, the records in each ring, the
// record that each node holds, and its work time. The log has "rings: ok, 6
// programs, 6 rings, 5 records", "rings: node N stopped" or "started" after
// a key, "rings: node N stopped alone" when the kernel stopped it, and
// "rings: node N does not run: M records wait in the ring before it".
package rings

import "support:display"
import "support:graphics"
import "support:interface"
import op "contract:operation"
import "support:relay"
import "contract:ring"
import "support:random"
import "support:system"

WIDTH :: 720
HEIGHT :: 540
NODE_SIZE :: 92
FRAME_TIME :: 33
START_RECORDS :: 5
CELL :: 8 // The side of a record in the picture.
SHOWN_RECORDS :: 9 // Records of a ring that the picture shows as squares.

COLOR_RING :: 0x3A4654
COLOR_NODE :: 0x1B2530
COLOR_BLOCKED :: 0xF0A040
COLOR_STOPPED :: 0xD05050

Node :: struct {
	program:        system.Handle, // 0: the program does not run.
	after_memory:   system.Handle, // The ring from this node to the next one.
	after:          ring.Ring,
	control_memory: system.Handle,
	control:        ring.Ring,
	state_memory:   system.Handle,
	state:          ^relay.State,
	waiting_logged: bool,
}

nodes: [relay.NODE_COUNT]Node
prepared: system.Prepared_Modules // The shared code of the nodes.
image: []u8
added: int

// The center of each node, and the time that it keeps a record.
@(rodata)
centers := [relay.NODE_COUNT][2]int{{360, 84}, {540, 180}, {540, 356}, {360, 452}, {180, 356}, {180, 180}}
@(rodata)
work_times := [relay.NODE_COUNT]u64{260, 420, 180, 700, 240, 340}
@(rodata)
record_colors := [?]graphics.Color{0x58B8F0, 0xF0C050, 0xE06890, 0x70D890, 0xB088F0, 0xF08850, 0x60D8D0, 0xD8D860}

fail :: proc "contextless" (text: string) -> ! {
	system.log("rings: ", text)
	system.stop(1)
}

// node_start starts the program of a node. The program receives the ring
// before it, the ring after it, its control ring and its state. A node that
// starts again has the same rings: the records that waited are still there.
node_start :: proc "contextless" (index: int) -> bool {
	node := &nodes[index]
	node.state^ = {}
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[relay.GRANT_BEFORE] = {nodes[(index + relay.NODE_COUNT - 1) % relay.NODE_COUNT].after_memory, {.Read, .Write}}
	grants[relay.GRANT_AFTER] = {node.after_memory, {.Read, .Write}}
	grants[relay.GRANT_CONTROL] = {node.control_memory, {.Read, .Write}}
	grants[relay.GRANT_STATE] = {node.state_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = {system.context_record().handles[op.CONTEXT_LOG], {.Write}}
	values[relay.VALUE_WORK_TIME] = work_times[index]
	name := [?]u8{'n', 'o', 'd', 'e', ' ', u8('1' + index)}
	status: system.Status
	node.program, status = system.program_start(system.image_find(image, "node"), string(name[:]), grants, random.values_with_seed(&program_generator, values), {pages = 256, programs = 1, threads = 1, processor = 200_000, log_records = 100}, nil, &prepared)
	node.waiting_logged = false
	return status == .Ok
}

// node_stop closes the handle of the program: the kernel stops it. The
// record that the node had is lost with the program.
node_stop :: proc "contextless" (index: int) {
	system.close(nodes[index].program)
	nodes[index].program = 0
	nodes[index].state^ = {}
}

toggle :: proc "contextless" (index: int) {
	if nodes[index].program != 0 {
		node_stop(index)
		system.log("rings: node ", u64(index + 1), " stopped")
	} else if node_start(index) {
		system.log("rings: node ", u64(index + 1), " started")
	}
}

// add gives a new record to a node, through its control ring.
add :: proc "contextless" (index: int) {
	node := &nodes[index]
	colors := record_colors
	if system.send(&node.control.commands, ring.Record{kind = relay.RECORD, values = {0 = u64(colors[added % len(colors)])}}) {
		added += 1
	}
}

// pending gives the records that wait in a queue. The other programs write
// the two counters: the result is never more than the capacity.
pending :: proc "contextless" (queue: ^ring.Queue) -> (first, count: u32) {
	return queue.counters.read, ring.count(queue)
}

// The drawing of the window with the interface package: the tables of the
// frame now and of the frame on the surface.
records_now, records_before: [384]interface.Draw_Record
text_now, text_before: [2048]u8
drawing: interface.Window_Drawing

// The random generator of this program (src/library/support/random).
program_generator: random.Generator

// The entry of rings: it makes the rings, starts the six nodes, puts five
// records in the circle, then draws and answers keys and clicks for ever.
//
// It takes its random generator: each node gets its seed from it. With no
// seed, no window, no boot image, no memory for the rings or a node that
// does not start, it stops (`fail`, or the code 1). Each turn of the loop
// takes the events, looks for a node that stopped (`watch`), draws the
// rings, and waits 33 ms or until the next event.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The random generator of this program, from the seed that its starter
	// gave: it gives the seed of each program that this one starts.
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("rings: no random seed in the context")
		system.stop(1)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "rings")
	if !ok {
		fail("no surface")
	}
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	} else {
		fail("no grant to read the boot image")
	}
	for &node in nodes {
		status: system.Status
		node.after_memory, node.after, status = system.ring_create()
		if status == .Ok {
			node.control_memory, node.control, status = system.ring_create()
		}
		if status == .Ok {
			node.state_memory, status = system.memory_create(1)
		}
		address: rawptr
		if status == .Ok {
			address, status = system.memory_map(node.state_memory)
		}
		if status != .Ok {
			fail("no memory for the rings")
		}
		node.state = (^relay.State)(address)
	}
	for index in 0 ..< relay.NODE_COUNT {
		if !node_start(index) {
			fail("cannot start a node")
		}
	}
	for index in 0 ..< START_RECORDS {
		add(index)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	system.log("rings: ok, ", u64(relay.NODE_COUNT), " programs, ", u64(relay.NODE_COUNT), " rings, ", u64(START_RECORDS), " records")

	buttons: u32
	for {
		for event in display.next_event(&window) {
			#partial switch event.kind {
			case .Key:
				if !event.pressed {
					continue
				}
				switch event.character {
				case '1' ..= '0' + relay.NODE_COUNT:
					toggle(int(event.character - '1'))
				case 'a':
					add(added % relay.NODE_COUNT)
				}
			case .Pointer:
				pressed := event.buttons & ~buttons
				buttons = event.buttons
				for center, index in centers {
					if abs(event.x - center.x) > NODE_SIZE / 2 || abs(event.y - center.y) > NODE_SIZE / 2 {
						continue
					}
					if pressed & display.BUTTON_LEFT != 0 {
						add(index)
					}
					if pressed & display.BUTTON_RIGHT != 0 {
						toggle(index)
					}
				}
			}
		}
		now := system.time()
		watch()
		frame := interface.window_frame_begin(&drawing, &window)
		draw(frame.table, now)
		interface.window_frame_end(&drawing, &frame, &window)
		display.wait(&window, now + FRAME_TIME)
	}
}

// watch finds a node that the kernel stopped, and writes on the log when all
// the records wait before a stopped node.
watch :: proc "contextless" () {
	total: u32
	for &node in nodes {
		_, count := pending(&node.after.commands)
		total += count + node.state.holding
	}
	for &node, index in nodes {
		if node.program != 0 {
			if state, _ := system.program_state(node.program); state == .Stopped {
				node_stop(index)
				system.log("rings: node ", u64(index + 1), " stopped alone")
			}
			continue
		}
		_, count := pending(&nodes[(index + relay.NODE_COUNT - 1) % relay.NODE_COUNT].after.commands)
		if count == total && total > 0 && !node.waiting_logged {
			node.waiting_logged = true
			system.log("rings: node ", u64(index + 1), " does not run: ", u64(total), " records wait in the ring before it")
		}
	}
}

draw :: proc "contextless" (table: ^interface.Draw_Table, now: u64) {
	interface.draw_text(table, 12, 8, "Each square is a program. Each line is a ring in shared memory.", graphics.COLOR_TEXT)
	interface.draw_text(table, 12, HEIGHT - 22, "left button or a: add a record    right button or 1-6: stop or start a program", graphics.COLOR_DIM)

	// The rings, under the nodes.
	for &node, index in nodes {
		from := centers[index]
		to := centers[(index + 1) % relay.NODE_COUNT]
		interface.draw_line(table, from.x, from.y, to.x, to.y, 2, COLOR_RING)
		first, count := pending(&node.after.commands)
		// The oldest record is next to the node that reads the ring.
		length := abs(to.x - from.x) + abs(to.y - from.y)
		for position in 0 ..< min(count, SHOWN_RECORDS) {
			record := node.after.commands.records[(first + position) & node.after.commands.mask]
			// 256 is the end of the line at the reader. The first square is
			// just out of the node.
			along := 256 - (NODE_SIZE / 2 + 10 + int(position) * (CELL + 3)) * 256 * 3 / (length * 2)
			x := from.x + (to.x - from.x) * along / 256
			y := from.y + (to.y - from.y) * along / 256
			interface.draw_rectangle(table, x - CELL / 2 - 1, y - CELL / 2 - 1, CELL + 2, CELL + 2, graphics.COLOR_BACKGROUND)
			interface.draw_rectangle(table, x - CELL / 2, y - CELL / 2, CELL, CELL, graphics.Color(record.values[0]) & 0xFFFFFF)
		}
		// The number of records in the ring, beside the middle of the line.
		middle_x := (from.x + to.x) / 2 + (to.y - from.y) / 7 - 20
		middle_y := (from.y + to.y) / 2 - (to.x - from.x) / 7 - 8
		color: graphics.Color = count == ring.CAPACITY ? COLOR_BLOCKED : graphics.COLOR_DIM
		x := interface.draw_unsigned(table, middle_x, middle_y, u64(count), color)
		interface.draw_text(table, x, middle_y, "/32", color)
	}

	for &node, index in nodes {
		center := centers[index]
		x, y := center.x - NODE_SIZE / 2, center.y - NODE_SIZE / 2
		state := node.state^ // One copy: the node writes this record.
		border: graphics.Color = graphics.COLOR_PROGRAM
		status := "waits"
		switch {
		case node.program == 0:
			border, status = COLOR_STOPPED, "stopped"
		case state.blocked != 0:
			border, status = COLOR_BLOCKED, "ring full"
		case state.holding != 0:
			status = "works"
		}
		interface.draw_rectangle(table, x, y, NODE_SIZE, NODE_SIZE, COLOR_NODE)
		interface.draw_outline(table, x, y, NODE_SIZE, NODE_SIZE, 2, border)
		after := interface.draw_text(table, x + 8, y + 6, "node ", graphics.COLOR_TEXT)
		interface.draw_unsigned(table, after, y + 6, u64(index + 1), graphics.COLOR_TEXT)
		interface.draw_text(table, x + 8, y + 24, status, border)
		if state.holding != 0 {
			// The record, and the part of the work that is done.
			interface.draw_rectangle(table, x + 8, y + 46, 14, 14, graphics.Color(state.color) & 0xFFFFFF)
			span := max(state.release - state.since, 1)
			done := min(now - min(state.since, now), span)
			interface.draw_rectangle(table, x + 28, y + 50, NODE_SIZE - 36, 6, COLOR_RING)
			interface.draw_rectangle(table, x + 28, y + 50, int(done * (NODE_SIZE - 36) / span), 6, graphics.Color(state.color) & 0xFFFFFF)
		}
		interface.draw_unsigned(table, x + 8, y + NODE_SIZE - 22, state.passed, graphics.COLOR_DIM)
		interface.draw_unsigned(table, x + NODE_SIZE - 8 - 5 * graphics.CELL_WIDTH, y + NODE_SIZE - 22, work_times[index], graphics.COLOR_DIM, 3)
		interface.draw_text(table, x + NODE_SIZE - 8 - 2 * graphics.CELL_WIDTH, y + NODE_SIZE - 22, "ms", graphics.COLOR_DIM)
	}
}
