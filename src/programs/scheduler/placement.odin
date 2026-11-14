// The placement of a thread on the processors (docs/SCHEDULING.md, "The
// placement of a thread"): the cases of the program `scheduler`.
//
// Each condition is a value that the kernel gives: a status, an error
// record, a placement that `Thread_Control` reads, the home and the
// processor of a thread in the thread report. No case measures a share, a
// wait or a duration. A time in a case only ends a hang.
//
// A set of processors is a `u64`: bit n is the processor n. The cases
// write sets of the 4 processors of the machine test; a case that needs
// more processors than the machine has says so and checks nothing.
package scheduler

import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:support/system"

PLACEMENT_SAMPLES :: 50 // Reports of one thread, after the first one that shows it inside its set.
PLACEMENT_LIMIT_ROUNDS :: 1000
APART_SAMPLES :: 200 // Reports of the two groups of spinners.
APART_GROUP :: 3 // Spinners in each group.
BLOCKERS :: 5 // Threads that make one queue the busiest: more than the load of each other queue.

// every_processor gives the set of all the processors of the machine.
every_processor :: proc "contextless" (processors: u64) -> u64 {
	return processors >= 64 ? max(u64) : (u64(1) << processors) - 1
}

// placement_holds says if a record of the thread report shows a thread
// inside a set: its home is in the set, and no processor outside the set
// runs it.
placement_holds :: proc "contextless" (item: ^op.Thread_Report, set: u64) -> bool {
	return set & (u64(1) << item.home) != 0 && (item.processor == 0 || set & (u64(1) << (item.processor - 1)) != 0)
}

// placement_is says if a read of the placement of a thread gives a set and
// a limit.
placement_is :: proc "contextless" (thread: system.Handle, number: u64, processors, processors_limit: u64) -> bool {
	placement, status := system.thread_placement_read(thread, number)
	return status == .Ok && placement.processors == processors && placement.processors_limit == processors_limit
}

// refusal_recorded says if an error record is the record of a refused
// write of a placement: the part, the refused set, and the set that it
// had to stay inside.
refusal_recorded :: proc "contextless" (error: ^errors.Error_Record, part: op.Thread_Write_Refusal, refused, most: u64) -> bool {
	return error.kind == i64(errors.Kind.Bad_Value) && u64(error.value) == refused && u64(error.limit) == most && error.found == i64(part)
}

verdict_of :: proc "contextless" (as_it_must: bool) -> string {
	return as_it_must ? ": as it must" : ": WRONG"
}

// placement_settles waits until the thread report shows a thread of this
// program inside a set, then takes PLACEMENT_SAMPLES more reports and
// counts those that show it outside. A thread that ran on a processor
// outside the set leaves it at the end of its turn at the latest, so the
// wait is for a state of the kernel; its bound only ends a hang. must_run:
// the thread can run, and the case waits until the kernel counted one more
// tick of its run after the first report inside, so that the samples are
// of a thread that runs. settled: a report showed it inside (and it ran).
placement_settles :: proc "contextless" (number: u32, set: u64, must_run: bool) -> (settled: bool, outside: u64) {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	ran_at_first: u64
	for !settled {
		item := thread_item(number)
		if item == nil || system.time() >= deadline {
			return false, 0
		}
		if placement_holds(item, set) {
			settled, ran_at_first = true, item.run_time
		} else {
			system.sleep(system.time() + 1)
		}
	}
	for _ in 0 ..< PLACEMENT_SAMPLES {
		system.sleep(system.time() + 1)
		item := thread_item(number)
		if item == nil {
			return false, outside
		}
		outside += u64(!placement_holds(item, set))
	}
	for ran := !must_run; !ran; {
		item := thread_item(number)
		if item == nil || system.time() >= deadline {
			return false, outside
		}
		outside += u64(!placement_holds(item, set))
		ran = item.run_time > ran_at_first
		if !ran {
			system.sleep(system.time() + 1)
		}
	}
	return true, outside
}

// 1. A thread narrows its own set.

Own_Placement :: struct {
	processor: u32, // The one processor that the thread keeps.
	first:     op.Thread_Placement, // What it read first.
	second:    op.Thread_Placement, // What it read after its write.
	read, write, again: system.Status,
	samples:   u64,
	outside:   u64, // Samples where its home or its processor was another one.
}

own_placement: Own_Placement

// The thread reads its placement, keeps one processor, and reads its own
// record in the thread report: at the first return of its write it is on
// that processor, because its own turn ended in that kernel entry. Each
// later sample is taken after the kernel counted one more tick of its run.
own_placement_run :: proc "c" (parameter: rawptr) -> ! {
	result := &own_placement
	number := system.thread_record().number
	result.first, result.read = system.thread_placement_read(0, number)
	result.write = system.thread_placement_write(0, number, {processors = u64(1) << result.processor})
	result.second, result.again = system.thread_placement_read(0, number)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	ran: u64
	for result.samples < PLACEMENT_SAMPLES && system.time() < deadline {
		item := thread_item(u32(number))
		if item == nil {
			break
		}
		if result.samples != 0 && item.run_time == ran {
			continue
		}
		ran = item.run_time
		result.samples += 1
		result.outside += u64(item.home != result.processor || item.processor != result.processor + 1)
	}
	system.thread_stop()
}

placement_own :: proc "contextless" (processors: u64) -> bool {
	every := every_processor(processors)
	own_placement = {processor = u32(processors - 1)}
	thread, status := system.thread_start(own_placement_run, nil)
	if status != .Ok {
		return false
	}
	system.thread_wait(thread)
	result := &own_placement
	kept := u64(1) << result.processor
	first_right := result.read == .Ok && result.first.processors == every && result.first.processors_limit == every
	second_right := result.again == .Ok && result.second.processors == kept && result.second.processors_limit == every
	as_it_must := first_right && result.write == .Ok && second_right && result.samples == PLACEMENT_SAMPLES && result.outside == 0
	system.log("scheduler: a thread read its own placement: each of the ", processors, " processors in its set and in its limit: ", u64(first_right), "; its own write of the processor ", u64(result.processor), " alone: ", op.STATUS_NAMES[result.write], ", and it then read that processor alone, with the same limit: ", u64(second_right), "; in ", result.samples, " samples of its thread report, each after one more tick of its run, its home or its processor was another one ", result.outside, " times", verdict_of(as_it_must))
	return as_it_must
}

// 2. Each write of a placement that the kernel must refuse, on one spinner
// that runs and that the machine handle keeps on the processor 0.
placement_refusals :: proc "contextless" (processors: u64) -> bool {
	if processors < 2 || processors >= 64 {
		system.log("scheduler: the refused writes of a placement are not checked on a machine with ", processors, " processors: the case needs a processor that the thread does not have, and a processor that the machine does not have")
		return true
	}
	every := every_processor(processors)
	absent := u64(1) << processors // A processor that the machine does not have.
	if !spinners_start(0, 1, full_weight) {
		return false
	}
	numbers: [SPINNER_LIMIT]u64
	if !spinner_machine_numbers(0, 1, &numbers) {
		spinners_stop(0, 1)
		return false
	}
	spinner := spinner_threads[0].handle
	narrowed := system.thread_placement_write(machine, numbers[0], {processors = 0b01})
	unchanged := narrowed == .Ok && placement_is(spinner, 0, 0b01, every)
	rights_changed_nothing := narrowed == .Ok
	error: errors.Error_Record
	// The program side: a wider set, and a set with no processor of the
	// machine.
	wider := system.thread_placement_write(spinner, 0, {processors = 0b11}, &error)
	program_records := refusal_recorded(&error, .Processors, 0b11, 0b01)
	unchanged &&= placement_is(spinner, 0, 0b01, every)
	error = {}
	nowhere := system.thread_placement_write(spinner, 0, {processors = absent}, &error)
	program_records &&= refusal_recorded(&error, .Processors, absent, every)
	unchanged &&= placement_is(spinner, 0, 0b01, every)
	// The machine handle: a limit with no processor of the machine, and a
	// set with no processor inside its limit.
	error = {}
	no_limit := system.thread_placement_write(machine, numbers[0], {processors_limit = absent}, &error)
	machine_records := refusal_recorded(&error, .Processors_Limit, absent, every)
	unchanged &&= placement_is(spinner, 0, 0b01, every)
	error = {}
	outside_limit := system.thread_placement_write(machine, numbers[0], {processors = 0b10, processors_limit = 0b01}, &error)
	machine_records &&= refusal_recorded(&error, .Processors, 0b10, 0b01)
	unchanged &&= placement_is(spinner, 0, 0b01, every)
	// The machine with no right Schedule; the machine with Schedule and no
	// Inspect, which names no thread; a thread handle with Inspect and no
	// Control, which reads and does not write.
	no_schedule, no_inspect, blind_write, no_control := system.Status.Ok, system.Status.Ok, system.Status.Ok, system.Status.Ok
	reads := false
	if copy, status := system.give(0, machine, {.Inspect}); status == .Ok {
		no_schedule = system.thread_placement_write(copy, numbers[0], {})
		system.close(copy)
	}
	if copy, status := system.give(0, machine, {.Schedule}); status == .Ok {
		_, no_inspect = system.thread_placement_read(copy, numbers[0])
		blind_write = system.thread_placement_write(copy, numbers[0], {})
		system.close(copy)
	}
	if copy, status := system.give(0, spinner, {.Inspect}); status == .Ok {
		no_control = system.thread_placement_write(copy, 0, {processors = 0b01})
		reads = placement_is(copy, 0, 0b01, every)
		system.close(copy)
	}
	rights_changed_nothing &&= placement_is(spinner, 0, 0b01, every)
	// The spinner ends: its machine number names no thread.
	spinners_stop(0, 1)
	_, ended_read := system.thread_placement_read(machine, numbers[0])
	ended_write := system.thread_placement_write(machine, numbers[0], {})
	sets_right := wider == .Bad_Operation && nowhere == .Bad_Operation && program_records && no_limit == .Bad_Operation && outside_limit == .Bad_Operation && machine_records && unchanged
	rights_right := no_schedule == .No_Right && no_inspect == .No_Right && blind_write == .No_Right && no_control == .No_Right && reads && rights_changed_nothing
	rights_right &&= ended_read == .Bad_State && ended_write == .Bad_State
	// Two lines: one line of the log holds 512 bytes.
	system.log("scheduler: refused sets of a placement, on a spinner that the machine handle keeps on the processor 0: through its thread handle a wider set ", op.STATUS_NAMES[wider], " and a processor that the machine does not have ", op.STATUS_NAMES[nowhere], ", with their error records: ", u64(program_records), "; through the machine handle a limit of no processor of the machine ", op.STATUS_NAMES[no_limit], " and a set outside its limit ", op.STATUS_NAMES[outside_limit], ", with their error records: ", u64(machine_records), "; the placement stayed: ", u64(unchanged), verdict_of(sets_right))
	system.log("scheduler: the rights of a placement: the machine handle with no right Schedule ", op.STATUS_NAMES[no_schedule], "; a read and a write through the machine handle with Schedule and no Inspect ", op.STATUS_NAMES[no_inspect], " and ", op.STATUS_NAMES[blind_write], "; a thread handle with Inspect and no Control ", op.STATUS_NAMES[no_control], ", and it reads: ", u64(reads), "; the placement stayed: ", u64(rights_changed_nothing), "; a read and a write by the machine number of a thread that ended ", op.STATUS_NAMES[ended_read], " and ", op.STATUS_NAMES[ended_write], verdict_of(rights_right))
	return sets_right && rights_right
}

// 3. The limit. The first thread of the program gets a limit through the
// machine handle, tries to leave it by its own writes and by a new thread,
// and gets each processor back at the end.

// A thread that the limited thread created: what it read of its own
// placement, the status of its own write of each processor, and its home
// in the thread report.
Limited_Placement_Child :: struct {
	every:     u64,
	placement: op.Thread_Placement,
	read:      system.Status,
	widen:     system.Status,
	home:      u32,
	reported:  bool,
}

limited_placement_child: Limited_Placement_Child

limited_placement_child_run :: proc "c" (parameter: rawptr) -> ! {
	child := &limited_placement_child
	number := system.thread_record().number
	child.placement, child.read = system.thread_placement_read(0, number)
	child.widen = system.thread_placement_write(0, number, {processors = child.every})
	if item := thread_item(u32(number)); item != nil {
		child.home, child.reported = item.home, true
	}
	system.thread_stop()
}

placement_limits :: proc "contextless" (processors: u64) -> bool {
	if processors < 4 {
		system.log("scheduler: the limit of a placement is not checked on a machine with ", processors, " processors: the case needs a limit of two processors and a processor outside it")
		return true
	}
	every := every_processor(processors)
	limit := every_processor(processors / 2) // The lower half of the processors.
	number := system.thread_record().number
	lowered := system.thread_placement_write(machine, self_machine_number, {processors_limit = limit})
	limited := placement_is(0, number, limit, limit)
	error: errors.Error_Record
	widen := system.thread_placement_write(0, number, {processors = every}, &error)
	record_right := refusal_recorded(&error, .Processors, every, limit)
	// The limit of the record of an own write is not read: the thread
	// keeps its limit, and the set 0 keeps its set.
	ignored := system.thread_placement_write(0, number, {processors_limit = every})
	kept := placement_is(0, number, limit, limit)
	first_right := lowered == .Ok && limited && widen == .Bad_Operation && record_right && ignored == .Ok && kept
	// One processor of the limit is accepted. The set of the limit and
	// each processor are refused then: a program only narrows. Only the
	// machine handle gives the set of the limit back.
	accepted, refused, machine_widened, wrong: u64
	for _ in 0 ..< PLACEMENT_LIMIT_ROUNDS {
		accepted += u64(system.thread_placement_write(0, number, {processors = 0b01}) == .Ok)
		refused += u64(system.thread_placement_write(0, number, {processors = limit}) == .Bad_Operation)
		refused += u64(system.thread_placement_write(0, number, {processors = every}) == .Bad_Operation)
		// The refused writes changed nothing: the set is still one processor.
		narrow_kept := placement_is(0, number, 0b01, limit)
		machine_widened += u64(system.thread_placement_write(machine, self_machine_number, {processors_limit = limit}) == .Ok)
		wrong += u64(!narrow_kept || !placement_is(0, number, limit, limit))
	}
	rounds_right := accepted == PLACEMENT_LIMIT_ROUNDS && refused == 2 * PLACEMENT_LIMIT_ROUNDS && machine_widened == PLACEMENT_LIMIT_ROUNDS && wrong == 0
	system.log("scheduler: the limit of the processors 0 to ", processors / 2 - 1, " written through the machine handle: the thread has that set: ", u64(limited), "; its own write of each processor ", op.STATUS_NAMES[widen], ", the error record has the set of the thread: ", u64(record_right), "; its own write of a wider limit changed nothing: ", u64(kept), verdict_of(first_right))
	system.log("scheduler: under that limit, ", u64(PLACEMENT_LIMIT_ROUNDS), " rounds of the own writes of the thread, of the processor 0, of the set of the limit and of each processor, then the limit again through the machine handle: ", accepted, " of its own accepted, ", refused, " refused, ", machine_widened, " widened by the machine handle, a wrong set or limit ", wrong, " times", verdict_of(rounds_right))

	// A new thread has the limit as its set and as its limit, and its
	// first queue is the queue of a processor of the limit.
	limited_placement_child = {every = every, read = .Bad_State, widen = .Ok}
	child, child_status := system.thread_start(limited_placement_child_run, nil)
	if child_status == .Ok {
		system.thread_wait(child)
	}
	result := &limited_placement_child
	inherited := child_status == .Ok && result.read == .Ok && result.placement.processors == limit && result.placement.processors_limit == limit
	home_inside := result.reported && limit & (u64(1) << result.home) != 0
	// The machine handle gives each processor back, on each path.
	widened := system.thread_placement_write(machine, self_machine_number, {})
	restored := widened == .Ok && placement_is(0, number, every, every)
	child_right := inherited && home_inside && result.widen == .Bad_Operation
	system.log("scheduler: under that limit: a new thread has the limit as its set and as its limit: ", u64(inherited), ", its home is a processor of the limit: ", u64(home_inside), ", and its own write of each processor ", op.STATUS_NAMES[result.widen], "; after the machine handle wrote the zero record the first thread has each processor in its set and in its limit: ", u64(restored), verdict_of(child_right && restored))
	return first_right && rounds_right && child_right && restored
}

// 4. A set without the home of a thread, written through the machine
// handle, in each state of the thread.

// A thread that waits on a word, then spins.
Placement_Waiter :: struct {
	number: u32, // 1 + the number of its thread: it writes it when it starts. 0: not yet.
	word:   u32, // It waits while this is 0.
	stop:   u32,
}

placement_waiter: Placement_Waiter

placement_wait_run :: proc "c" (parameter: rawptr) -> ! {
	waiter := &placement_waiter
	intrinsics.atomic_store(&waiter.number, u32(system.thread_record().number) + 1)
	system.word_wake(&waiter.number)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for intrinsics.atomic_load(&waiter.word) == 0 && system.time() < deadline {
		system.word_wait(&waiter.word, 0, deadline)
	}
	for intrinsics.atomic_load(&waiter.stop) == 0 {
		intrinsics.cpu_relax()
	}
	system.thread_stop()
}

// set_without gives each processor of the machine but one.
set_without :: proc "contextless" (every: u64, processor: u32) -> u64 {
	return every &~ (u64(1) << processor)
}

// waiting_placed: a thread that waits gets a set without its home. The
// write changes its home at once: the next report has a home of the set,
// and the thread still waits. After its wake it runs inside the set.
waiting_placed :: proc "contextless" (every: u64) -> (moved_at_once: bool, settled: bool, outside: u64) {
	placement_waiter = {}
	thread, status := system.thread_start(placement_wait_run, nil)
	if status != .Ok {
		return
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for intrinsics.atomic_load(&placement_waiter.number) == 0 && system.time() < deadline {
		system.word_wait(&placement_waiter.number, 0, deadline)
	}
	number := intrinsics.atomic_load(&placement_waiter.number) - 1
	// The wait is for a state of the kernel: the thread waits, on no
	// processor.
	waits := false
	home: u32
	machine_number: u64
	for !waits && intrinsics.atomic_load(&placement_waiter.number) != 0 && system.time() < deadline {
		if item := thread_item(number); item != nil && item.state == .Waiting && item.processor == 0 {
			waits, home, machine_number = true, item.home, item.machine_number
		} else {
			system.sleep(system.time() + 1)
		}
	}
	set := set_without(every, home)
	if waits && system.thread_placement_write(machine, machine_number, {processors = set}) == .Ok {
		if item := thread_item(number); item != nil {
			moved_at_once = item.state == .Waiting && item.home != home && placement_holds(item, set)
		}
	}
	intrinsics.atomic_store(&placement_waiter.word, 1)
	system.word_wake(&placement_waiter.word)
	if moved_at_once {
		settled, outside = placement_settles(number, set, true)
	}
	intrinsics.atomic_store(&placement_waiter.stop, 1)
	system.thread_wait(thread)
	return
}

// held_placed: a spinner that a Stop holds gets a set without its home.
// The write changes its home at once, and it stays held, in no list.
// After the Resume it runs inside the set. The machine handle gives it
// each processor back at the end.
held_placed :: proc "contextless" (every: u64, spinner: int, machine_number: u64) -> (moved_at_once: bool, settled: bool, outside: u64) {
	thread := spinner_threads[spinner].handle
	number := intrinsics.atomic_load(&spinners[spinner].number) - 1
	if _, stop_status := system.call(.Thread_Control, u64(thread), 0, u64(op.Thread_Control_Command.Stop)); stop_status != .Ok {
		return
	}
	set: u64
	if item := thread_item(number); item != nil && item.processor == 0 && item.queued == 0 {
		home := item.home
		set = set_without(every, home)
		if system.thread_placement_write(machine, machine_number, {processors = set}) == .Ok {
			if after := thread_item(number); after != nil {
				moved_at_once = after.processor == 0 && after.queued == 0 && after.home != home && placement_holds(after, set)
			}
		}
	}
	_, resume_status := system.call(.Thread_Control, u64(thread), 0, u64(op.Thread_Control_Command.Resume))
	if moved_at_once && resume_status == .Ok {
		settled, outside = placement_settles(number, set, true)
	}
	widened := system.thread_placement_write(machine, machine_number, {})
	settled &&= widened == .Ok
	return
}

// listed_or_running_placed: a spinner that the thread report shows in a
// list (in_list), or on a processor, gets a set without its home. The
// state of the report is a help to aim, not a condition: the spinner can
// leave that state before the write. The condition holds for each state:
// a report shows the spinner inside the set, and no later report shows it
// outside. found: the report showed a spinner in the wanted state.
listed_or_running_placed :: proc "contextless" (every: u64, count: int, numbers: ^[SPINNER_LIMIT]u64, in_list: bool) -> (found: bool, settled: bool, outside: u64) {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	spinner: int
	home: u32
	for !found && system.time() < deadline {
		for index in 0 ..< count {
			item := thread_item(intrinsics.atomic_load(&spinners[index].number) - 1)
			if item == nil || found {
				continue
			}
			wanted := item.processor != 0
			if in_list {
				wanted = item.queued == 1 && item.processor == 0
			}
			if wanted {
				found, spinner, home = true, index, item.home
			}
		}
		if !found {
			system.sleep(system.time() + 1)
		}
	}
	if !found {
		return
	}
	set := set_without(every, home)
	if system.thread_placement_write(machine, numbers[spinner], {processors = set}) == .Ok {
		settled, outside = placement_settles(intrinsics.atomic_load(&spinners[spinner].number) - 1, set, true)
	}
	widened := system.thread_placement_write(machine, numbers[spinner], {})
	settled &&= widened == .Ok
	return
}

placement_states :: proc "contextless" (processors: u64) -> bool {
	if processors < 2 || processors + 1 > SPINNER_LIMIT {
		system.log("scheduler: a set without the home of a thread is not checked on a machine with ", processors, " processors: the case needs a second processor, and one spinner more than the processors")
		return true
	}
	every := every_processor(processors)
	waiting_moved, waiting_settled, waiting_outside := waiting_placed(every)
	// One spinner more than the processors: a queue has a thread in its
	// list.
	count := int(processors) + 1
	numbers: [SPINNER_LIMIT]u64
	started := spinners_start(0, count, full_weight) && spinner_machine_numbers(0, count, &numbers)
	held_moved, held_settled, listed_found, listed_settled, running_found, running_settled: bool
	held_outside, listed_outside, running_outside: u64
	if started {
		held_moved, held_settled, held_outside = held_placed(every, 0, numbers[0])
		listed_found, listed_settled, listed_outside = listed_or_running_placed(every, count, &numbers, true)
		running_found, running_settled, running_outside = listed_or_running_placed(every, count, &numbers, false)
	}
	spinners_stop(0, count)
	off_right := waiting_moved && waiting_settled && waiting_outside == 0
	off_right &&= started && held_moved && held_settled && held_outside == 0
	on_right := started && listed_found && listed_settled && listed_outside == 0 && running_found && running_settled && running_outside == 0
	as_it_must := off_right && on_right
	system.log("scheduler: a set without the home of a thread, written through the machine handle: a thread that waits has a home of the set in the next report: ", u64(waiting_moved), ", and after its wake it ran inside the set: ", u64(waiting_settled), ", outside in ", waiting_outside, " reports; a spinner that a Stop holds has a home of the set in the next report: ", u64(held_moved), ", and after the Resume it ran inside the set: ", u64(held_settled), ", outside in ", held_outside, " reports", verdict_of(off_right))
	system.log("scheduler: a set without the home of a spinner, written through the machine handle: a spinner in a list ran inside the set: ", u64(listed_settled), ", outside in ", listed_outside, " reports after the first one inside; a spinner on a processor ran inside the set: ", u64(running_settled), ", outside in ", running_outside, " reports after the first one inside", verdict_of(on_right))
	return as_it_must
}

// 5. Two groups of spinners whose limits share no processor. The first
// thread gets the limit of a group through the machine handle and creates
// the spinners of the group: each one gets that limit from its creator.
// Then no report shows a spinner with a home or a processor of the other
// group. The reports go on until each processor ran a spinner of its
// group, so the case cannot pass with spinners that do not run.
placement_apart :: proc "contextless" (processors: u64) -> bool {
	if processors < 2 {
		system.log("scheduler: two groups of spinners with no common processor are not checked on a machine with one processor")
		return true
	}
	every := every_processor(processors)
	lower := every_processor(processors / 2)
	sets := [2]u64{lower, every &~ lower}
	count := 2 * APART_GROUP
	started := self_machine_number != 0
	for group in 0 ..< 2 {
		started &&= system.thread_placement_write(machine, self_machine_number, {processors_limit = sets[group]}) == .Ok
		started &&= spinners_start(group * APART_GROUP, APART_GROUP, full_weight)
	}
	restored := system.thread_placement_write(machine, self_machine_number, {}) == .Ok
	numbers: [SPINNER_LIMIT]u64
	started &&= spinner_machine_numbers(0, count, &numbers)
	inherited := started
	for index in 0 ..< count {
		if started {
			inherited &&= placement_is(machine, numbers[index], sets[index / APART_GROUP], sets[index / APART_GROUP])
		}
	}
	seen, outside, samples: u64
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for started && (seen != every || samples < APART_SAMPLES) && system.time() < deadline {
		system.sleep(system.time() + 1)
		if !threads_of(self_slot, self_serial) {
			break
		}
		samples += 1
		for index in 0 ..< count {
			number := intrinsics.atomic_load(&spinners[index].number) - 1
			for &item in thread_table.threads[:min(thread_table.count, op.THREAD_REPORT_CAPACITY)] {
				if item.number != number || item.state == .Stopped {
					continue
				}
				outside += u64(!placement_holds(&item, sets[index / APART_GROUP]))
				if item.processor != 0 {
					seen |= u64(1) << (item.processor - 1)
				}
			}
		}
	}
	spinners_stop(0, count)
	as_it_must := started && restored && inherited && seen == every && samples >= APART_SAMPLES && outside == 0
	system.log("scheduler: two groups of ", u64(APART_GROUP), " spinners, each created under the limit of its group, the processors 0 to ", processors / 2 - 1, " and ", processors / 2, " to ", processors - 1, ": each spinner has that limit as its set and as its limit: ", u64(inherited), "; each of the ", processors, " processors ran a spinner of its group: ", u64(seen == every), "; in at least ", u64(APART_SAMPLES), " reports of the threads a spinner had a home or a processor of the other group ", outside, " times", verdict_of(as_it_must))
	system.log("scheduler: the two groups were read in ", samples, " reports (a measure)")
	return as_it_must
}

// 6. The balance is not blocked by a queue whose threads a processor
// cannot take. BLOCKERS threads stay in the queue of the processor 0 and
// make it the busiest: spinners that only the processor 0 can run, or
// threads of a budget with no processor time, which never run. Two
// spinners are in the queue of the processor 1; then they get each
// processor but the processor 0. A processor that looks for a thread
// finds none that it can take in the busiest queue; it must then take the
// spinner that waits in the queue of the processor 1. The condition is one
// report that shows the two spinners on two processors; the bound only
// ends a hang.
//
// The case must fail when the balance tries the busiest queue only, so no
// thread of this program names the queue of the processor 1 to another
// processor:
// - each other processor runs a spinner of its own (a pacer), so none is
//   idle when the two spinners get their processors: that write wakes no
//   idle processor with the queue of the processor 1 as a hint;
// - the two spinners do not get the processor 0, which can be idle;
// - the first thread stays on the processors of the pacers, so its wakes
//   name those queues only.
// A pacer ends a turn at each time slice, and its processor then looks
// for a thread with no hint: this is the pick that must pass the busiest
// queue. So the case needs no wake of the first thread. A thread of
// another program that wakes with the processor 1 as its home can still
// give that hint: the case cannot exclude it.
placement_balance_case :: proc "contextless" (processors: u64, by_budget: bool) -> bool {
	every := every_processor(processors)
	away := every &~ u64(0b11) // Not the processors 0 and 1.
	pacers := int(processors) - 2 // One for each processor of `away`.
	numbers: [SPINNER_LIMIT]u64
	blocked: [BLOCKERS]system.Thread
	budget: system.Handle
	first := 0 // The first of the two spinners; the pacers come after them.
	prepared := true
	if by_budget {
		// The new threads enter the queue of the processor that creates
		// them: the first thread is on the processor 0 after this write.
		prepared = system.thread_placement_write(machine, self_machine_number, {processors = 0b01}) == .Ok
		status: system.Status
		budget, status = system.budget_create({pages = 16 * BLOCKERS, threads = BLOCKERS})
		prepared &&= status == .Ok
		for &thread in blocked {
			if prepared {
				thread, status = system.thread_start(brief, nil, budget = budget)
				prepared &&= status == .Ok
			}
		}
		prepared &&= system.thread_placement_write(machine, self_machine_number, {processors = away}) == .Ok
	} else {
		first = BLOCKERS
		prepared = system.thread_placement_write(machine, self_machine_number, {processors = away}) == .Ok
	}
	count := first + 2 + pacers
	prepared &&= spinners_start(0, count, full_weight) && spinner_machine_numbers(0, count, &numbers)
	// The spinners that only the processor 0 can run, and one pacer on
	// each processor of `away`.
	for index in 0 ..< count {
		set := u64(0b01)
		if index >= first + 2 {
			set = u64(1) << u64(index - first)
		} else if index >= first {
			continue
		}
		if prepared {
			prepared = system.thread_placement_write(machine, numbers[index], {processors = set}) == .Ok
		}
		if prepared {
			prepared, _ = placement_settles(intrinsics.atomic_load(&spinners[index].number) - 1, set, false)
		}
	}
	// The two spinners: in the queue of the processor 1, then on each
	// processor but the processor 0.
	pair_numbers: [2]u32
	for side in 0 ..< 2 {
		if prepared {
			pair_numbers[side] = intrinsics.atomic_load(&spinners[first + side].number) - 1
			prepared = system.thread_placement_write(machine, numbers[first + side], {processors = 0b10}) == .Ok
		}
	}
	for side in 0 ..< 2 {
		if prepared {
			prepared, _ = placement_settles(pair_numbers[side], 0b10, false)
		}
	}
	for side in 0 ..< 2 {
		if prepared {
			prepared = system.thread_placement_write(machine, numbers[first + side], {processors = every &~ u64(0b01)}) == .Ok
		}
	}
	apart := false
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for prepared && !apart && system.time() < deadline {
		system.sleep(system.time() + 1)
		if !threads_of(self_slot, self_serial) {
			break
		}
		on: [2]u32
		for &item in thread_table.threads[:min(thread_table.count, op.THREAD_REPORT_CAPACITY)] {
			for side in 0 ..< 2 {
				if item.number == pair_numbers[side] && item.state != .Stopped {
					on[side] = item.processor
				}
			}
		}
		apart = on[0] != 0 && on[1] != 0 && on[0] != on[1]
	}
	spinners_stop(0, count)
	for thread in blocked {
		if thread.handle != 0 {
			system.thread_end(thread)
		}
	}
	if budget != 0 {
		system.close(budget)
	}
	restored := system.thread_placement_write(machine, self_machine_number, {}) == .Ok
	as_it_must := prepared && apart && restored
	if by_budget {
		system.log("scheduler: ", u64(BLOCKERS), " threads of a budget with no processor time, in the queue of the processor 0, make it the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to ", processors - 1, ": a report showed the two on two processors at one time: ", u64(apart), verdict_of(as_it_must))
	} else {
		system.log("scheduler: ", u64(BLOCKERS), " spinners that only the processor 0 can run make its queue the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to ", processors - 1, ": a report showed the two on two processors at one time: ", u64(apart), verdict_of(as_it_must))
	}
	return as_it_must
}

placement_balance :: proc "contextless" (processors: u64) -> bool {
	if processors < 4 || BLOCKERS + processors > SPINNER_LIMIT {
		system.log("scheduler: the balance past a queue of threads that a processor cannot take is not checked on a machine with ", processors, " processors: the case needs two processors for the two queues, two more for the first thread, and a spinner for each processor from 2, at most ", u64(SPINNER_LIMIT - BLOCKERS), " processors")
		return true
	}
	with_placements := placement_balance_case(processors, false)
	with_a_budget := placement_balance_case(processors, true)
	return with_placements && with_a_budget
}

// 6b. A set that gets a processor while its thread is in a list. Two
// spinners and the first thread are kept on the processor 0: one spinner
// runs, the other is in the list. The wakes of the first thread name no
// other processor. The machine handle gives the spinner of the list the
// processor 1 too. That write makes the processors look at the list, so
// the processor 1, when it is idle, takes the spinner: the condition is a
// report that shows it on the processor 1. The end of a turn wakes no
// processor, so without that look the spinner stays on the processor 0
// until a thread of another program makes the processor 1 pick.
//
// The report only aims: the spinner that it shows in the list can run
// when the write comes, and the write then wakes no processor. So a round
// that does not see the spinner on the processor 1 in WIDENED_REPORTS
// reports gives it the processor 0 alone again, and the next round aims
// again. The rounds are a measure; the hang bound ends them.
WIDENED_REPORTS :: 50

placement_widened :: proc "contextless" (processors: u64) -> bool {
	if processors < 2 {
		system.log("scheduler: a set that gets an idle processor is not checked on a machine with one processor")
		return true
	}
	numbers: [SPINNER_LIMIT]u64
	prepared := system.thread_placement_write(machine, self_machine_number, {processors = 0b01}) == .Ok
	prepared &&= spinners_start(0, 2, full_weight) && spinner_machine_numbers(0, 2, &numbers)
	for index in 0 ..< 2 {
		if prepared {
			prepared = system.thread_placement_write(machine, numbers[index], {processors = 0b01}) == .Ok
		}
		if prepared {
			prepared, _ = placement_settles(intrinsics.atomic_load(&spinners[index].number) - 1, 0b01, false)
		}
	}
	reached := false
	rounds: u64
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for prepared && !reached && system.time() < deadline {
		rounds += 1
		chosen := -1
		for chosen < 0 && system.time() < deadline {
			for index in 0 ..< 2 {
				item := thread_item(intrinsics.atomic_load(&spinners[index].number) - 1)
				if chosen < 0 && item != nil && item.queued == 1 && item.processor == 0 {
					chosen = index
				}
			}
			if chosen < 0 {
				system.sleep(system.time() + 1)
			}
		}
		if chosen < 0 {
			break
		}
		number := intrinsics.atomic_load(&spinners[chosen].number) - 1
		prepared = system.thread_placement_write(machine, numbers[chosen], {processors = 0b11}) == .Ok
		for seen := 0; prepared && !reached && seen < WIDENED_REPORTS; seen += 1 {
			item := thread_item(number)
			reached = item != nil && item.processor == 2
			if !reached {
				system.sleep(system.time() + 1)
			}
		}
		if prepared && !reached {
			prepared = system.thread_placement_write(machine, numbers[chosen], {processors = 0b01}) == .Ok
			if prepared {
				prepared, _ = placement_settles(number, 0b01, false)
			}
		}
	}
	spinners_stop(0, 2)
	restored := system.thread_placement_write(machine, self_machine_number, {}) == .Ok
	as_it_must := prepared && reached && restored
	system.log("scheduler: two spinners and the first thread kept on the processor 0; the spinner of the list got the processor 1 too through the machine handle: a report showed it on the processor 1: ", u64(reached), verdict_of(as_it_must))
	system.log("scheduler: the spinner was seen on the processor 1 in the round ", rounds, " (a measure)")
	return as_it_must
}

// 7. Writes of placements through the machine handle while the strategy
// changes CHANGES times: no thread is lost. The form of the stress case.
Placement_Writer :: struct {
	numbers:    [SPINNER_LIMIT]u64, // The machine numbers of the spinners.
	processors: u64,
	writes:     u64,
	refused:    u64,
}

placement_writer: Placement_Writer

// Each round gives each spinner one processor, or each processor: the
// spinner moves between the queues while the queues change their strategy.
placement_write_run :: proc "c" (parameter: rawptr) -> ! {
	writer := &placement_writer
	for round := u64(0); intrinsics.atomic_load(&changer.ended) == 0; round += 1 {
		for spinner in 0 ..< EQUAL_COUNT {
			placement: op.Thread_Placement // The zero record: each processor.
			if step := u64(spinner) + round; step % 3 != 0 {
				placement.processors = u64(1) << (step % writer.processors)
			}
			if system.thread_placement_write(machine, writer.numbers[spinner], placement) == .Ok {
				writer.writes += 1
			} else {
				writer.refused += 1
			}
		}
		// A pause, so that the writes fall at many moments of the changes.
		system.sleep(system.time() + 1)
	}
	system.thread_stop()
}

placement_changes :: proc "contextless" (processors: u64) -> bool {
	every := every_processor(processors)
	before, set_status := system.strategy_set(machine, .Eevdf)
	if set_status != .Ok {
		return false
	}
	placement_writer = {processors = processors}
	changer = {}
	started := spinners_start(0, EQUAL_COUNT, full_weight) && spinner_machine_numbers(0, EQUAL_COUNT, &placement_writer.numbers)
	changing, writing: system.Thread
	if started {
		status: system.Status
		changing, status = system.thread_start(change_run, nil)
		started = status == .Ok
	}
	if started {
		status: system.Status
		writing, status = system.thread_start(placement_write_run, nil)
		if status != .Ok {
			// The changer ends by itself after its changes.
			system.thread_wait(changing)
			started = false
		}
	}
	ran, placed := false, started
	if started {
		system.thread_wait(changing)
		system.thread_wait(writing)
		// The zero record, written last, gives each spinner each processor.
		placed = placement_writer.writes != 0 && placement_writer.refused == 0
		for spinner in 0 ..< EQUAL_COUNT {
			placed &&= system.thread_placement_write(machine, placement_writer.numbers[spinner], {}) == .Ok
			placed &&= placement_is(machine, placement_writer.numbers[spinner], every, every)
		}
		// After the last change, each spinner still runs: the wait is for
		// each count to grow, and the bound only ends a hang.
		first := spinner_counts(0, EQUAL_COUNT)
		for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; !ran && system.time() < deadline; {
			system.sleep(system.time() + 10)
			last := spinner_counts(0, EQUAL_COUNT)
			ran = true
			for spinner in 0 ..< EQUAL_COUNT {
				ran &&= last[spinner] > first[spinner]
			}
		}
	}
	spinners_stop(0, EQUAL_COUNT)
	system.strategy_set(machine, before)
	as_it_must := started && ran && placed && changer.changes == CHANGES && changer.refused == 0
	system.log("scheduler: writes of a placement through the machine handle while the strategy changed ", u64(CHANGES), " times: none was refused, each of the ", u64(EQUAL_COUNT), " spinners ran after them and has each processor again", verdict_of(as_it_must))
	system.log("scheduler: ", placement_writer.writes, " writes of a placement during ", changer.changes, " changes of strategy, ", placement_writer.refused, " refused (measures)")
	return as_it_must
}

// placement_cases runs the cases of the placement of a thread. Each case
// gives the first thread each processor back before it returns; the last
// read here says so. false: a case failed.
placement_cases :: proc "contextless" (processors: u64) -> bool {
	if self_machine_number == 0 {
		return false
	}
	// Each case runs, also after a case that failed: each one writes its
	// line.
	as_it_must := placement_own(processors)
	as_it_must = placement_refusals(processors) && as_it_must
	as_it_must = placement_limits(processors) && as_it_must
	as_it_must = placement_states(processors) && as_it_must
	as_it_must = placement_apart(processors) && as_it_must
	as_it_must = placement_balance(processors) && as_it_must
	as_it_must = placement_widened(processors) && as_it_must
	as_it_must = placement_changes(processors) && as_it_must
	every := every_processor(processors)
	return placement_is(0, system.thread_record().number, every, every) && as_it_must
}
