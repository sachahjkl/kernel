// One node of the `rings` demonstration (package relay). It has four memory
// objects and no other handle: it cannot draw, and it cannot see the other
// nodes. It communicates only through its rings.
package node

import "../../relay"
import "../../ring"
import "../../system"

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
