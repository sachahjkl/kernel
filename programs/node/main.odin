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
	before := (^ring.Ring)(address[relay.GRANT_BEFORE])
	after := (^ring.Ring)(address[relay.GRANT_AFTER])
	control := (^ring.Ring)(address[relay.GRANT_CONTROL])
	state := (^relay.State)(address[relay.GRANT_STATE])
	work_time := ctx.values[relay.VALUE_WORK_TIME]

	record: ring.Record
	for {
		now := system.time()
		if state.holding != 0 && now >= state.release {
			// A full ring refuses the record: the node keeps it. The node
			// after wakes this node when it takes a record.
			if ring.push(&after.commands, record) {
				state.holding, state.blocked = 0, 0
				state.passed += 1
				system.wake(memory[relay.GRANT_AFTER])
			} else {
				state.blocked = 1
			}
		}
		if state.holding == 0 {
			taken, ok := ring.pop(&control.commands)
			if !ok {
				if taken, ok = ring.pop(&before.commands); ok {
					system.wake(memory[relay.GRANT_BEFORE])
				}
			}
			if ok && taken.kind == relay.RECORD {
				record = taken
				record.values[1] += 1
				state.color = u32(record.values[0])
				state.since, state.release = now, now + work_time
				state.holding = 1
			}
		}
		system.wait(state.holding != 0 && state.blocked == 0 ? state.release : system.WAIT_FOREVER)
	}
}
