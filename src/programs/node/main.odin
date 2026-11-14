// One node of the `rings` demonstration (package relay). It has four memory
// objects and no other handle: it cannot draw, and it cannot see the other
// nodes. It communicates only through its rings.
//
// **What it is for.** It shows that a program with no grant but four memory
// objects is still useful, and still contained: it passes records from the
// ring before it to the ring after it, and it can do nothing else. The
// program `rings` starts six nodes in a circle from the boot image and
// draws what each one holds.
//
// **Start**: `rings` starts it from the boot image and gives it its four
// handles. It is not named in `grants_of`: a start by the root service does
// not give it these handles, so it has no use there.
//
// **Its context**, as the package relay names the places:
//
// - `GRANT_BEFORE`, `GRANT_AFTER`: the ring that it reads, the ring that it
//   writes;
// - `GRANT_CONTROL`: a ring from `rings`, which can put a record in the
//   circle;
// - `GRANT_STATE`: a shared page where the node says what it holds, since
//   when, and if the ring after it is full;
// - `VALUE_WORK_TIME`: the milliseconds that it holds each record.
//
// It writes nothing on the log and has no window.
package node

import "modus:support/relay"
import "modus:contract/ring"
import "modus:support/system"

// The entry of a node: it maps its four memory objects, then passes records
// for ever.
//
// A memory object that does not map stops it with the code 1. Each turn:
//
// 1. a record that it held for its work time goes to the ring after it; a
//    full ring refuses it, and the node keeps it and marks itself blocked;
// 2. with no record held, it takes one from the control ring first, then
//    from the ring before it, adds one to its count of hops, and holds it;
// 3. it waits for one thing only: a record, the end of its work, or room
//    in the ring after it.
//
// A node never stops by itself: `rings` stops it.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	memory: [4]system.Handle
	address: [4]rawptr
	for &item, role in memory {
		item = ctx.handles[role]
		status: system.Status
		if address[role], status = system.memory_map(item); status != .Ok {
			system.stop(1)
		}
	}
	before, _ := ring.open(address[relay.GRANT_BEFORE], ring.PAGE_COUNT)
	after, _ := ring.open(address[relay.GRANT_AFTER], ring.PAGE_COUNT)
	control, _ := ring.open(address[relay.GRANT_CONTROL], ring.PAGE_COUNT)
	state := (^relay.State)(address[relay.GRANT_STATE])
	work_time := ctx.values[relay.VALUE_WORK_TIME]

	record: ring.Record
	for {
		now := system.time()
		if state.holding != 0 && now >= state.release {
			// A full ring refuses the record: the node keeps it, and waits
			// for room in the ring.
			if system.send(&after.commands, record) {
				state.holding, state.blocked = 0, 0
				state.passed += 1
			} else {
				state.blocked = 1
			}
		}
		if state.holding == 0 {
			taken, ok := system.receive(&control.commands)
			if !ok {
				taken, ok = system.receive(&before.commands)
			}
			if ok && taken.kind == relay.RECORD {
				record = taken
				record.values[1] += 1
				state.color = u32(record.values[0])
				state.since, state.release = now, now + work_time
				state.holding = 1
			}
		}
		// The node waits for one thing: a record, the end of its work, or
		// room in the ring after it.
		wait: system.Wait
		if state.holding == 0 {
			system.wait_records(&wait, &control.commands)
			system.wait_records(&wait, &before.commands)
		} else if state.blocked != 0 {
			system.wait_room(&wait, &after.commands)
		}
		system.wait_end(&wait, state.holding != 0 && state.blocked == 0 ? state.release : system.WAIT_FOREVER)
	}
}
