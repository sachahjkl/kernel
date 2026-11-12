// The system library: what a program uses to talk to the kernel and to other
// programs. It is compiled into each program. It allocates no hidden memory.
package system

import "contract:errors"
import op "contract:operation"
import "contract:ring"
import "base:intrinsics"

Handle :: op.Handle
Status :: op.Status
Right :: op.Right
Rights :: op.Rights
Budget_Amounts :: op.Budget_Amounts
Context :: op.Context
PAGE_SIZE :: op.PAGE_SIZE
WAIT_FOREVER :: op.WAIT_FOREVER

foreign _ {
	system_enter :: proc "c" (wait: u64) -> u64 ---
	// thread_record gives the thread record of the thread that runs: the
	// kernel keeps its address in the gs register.
	thread_record :: proc "c" () -> ^op.Thread_Record ---
	port_write_8 :: proc "c" (port: u16, value: u8) ---
	port_read_8 :: proc "c" (port: u16) -> u8 ---
	port_write_32 :: proc "c" (port: u16, value: u32) ---
	port_read_32 :: proc "c" (port: u16) -> u32 ---
	// export_call calls an export with the call form (docs/MODULE_CONTRACT.md,
	// section 4). It loads the 6 integer registers and the 8 float registers
	// from the two arrays, calls address, and writes the results: the two
	// integer results, then the two float results.
	export_call :: proc "c" (address: uintptr, integers: ^[CALL_INTEGERS]u64, floats: ^[CALL_FLOATS]u64, results: ^[CALL_RESULTS]u64) ---
}

CALL_INTEGERS :: 6
CALL_FLOATS :: 8
CALL_RESULTS :: 4

// kernel_ring gives the kernel ring of the thread that runs: it is after the
// thread record.
kernel_ring :: #force_inline proc "contextless" () -> ring.Ring {
	kernel, _ := ring.open(rawptr(uintptr(thread_record()) + PAGE_SIZE), ring.PAGE_COUNT)
	return kernel
}

// entered counts the kernel entries of this program that go through this
// library: a program measures its own cost with no grant to inspect.
entered: u64

// kernel_entries gives the kernel entries of this program, as this library
// counted them.
kernel_entries :: proc "contextless" () -> u64 {
	return intrinsics.atomic_load(&entered)
}

// enter is the kernel entry of this library: it counts it.
enter :: #force_inline proc "contextless" (wait: u64) -> u64 {
	intrinsics.atomic_add(&entered, 1)
	return system_enter(wait)
}

// call executes one kernel operation and gives its results and its status.
// When the status is not Ok, the results are zero.
call :: proc "contextless" (operation: op.Operation, values: ..u64) -> (results: [7]u64, status: Status) {
	return call_with_error(nil, operation, ..values)
}

// call_with_error executes one kernel operation, as call. When the status is
// not Ok and error is not nil, the error record of the failure is written at
// error (docs/MODULE_CONTRACT.md, section 8): the kernel gives it in the
// values of the completion record. The caller owns the record; no global
// state keeps the last error. A call that succeeds does not write it.
// The wrappers below take the same `error` as their last parameter.
call_with_error :: proc "contextless" (error: ^errors.Error_Record, operation: op.Operation, values: ..u64) -> (results: [7]u64, status: Status) {
	command := ring.Record {
		kind = u32(operation),
	}
	for value, index in values {
		command.values[index] = value
	}
	kernel := kernel_ring()
	ring.push(&kernel.commands, command)
	enter(0)
	completion, ok := ring.pop(&kernel.completions)
	if !ok {
		return {}, .Bad_Operation
	}
	if completion.kind != u32(Status.Ok) {
		if error != nil {
			error^ = transmute(errors.Error_Record)completion.values
		}
		return {}, Status(completion.kind)
	}
	return completion.values, .Ok
}

// time gives the milliseconds since boot. It reads the time page: it does
// not enter the kernel.
time :: proc "contextless" () -> u64 {
	record := (^op.Time_Record)(uintptr(op.TIME_ADDRESS))
	return intrinsics.volatile_load(&record.milliseconds)
}

// cycle_frequency gives the cycles of the cycle counter in one second. It
// reads the time page: it does not enter the kernel.
cycle_frequency :: proc "contextless" () -> u64 {
	record := (^op.Time_Record)(uintptr(op.TIME_ADDRESS))
	return record.cycle_frequency
}

// nanoseconds gives the nanoseconds since boot, from the cycle counter and
// the two constants of the time page: it does not enter the kernel, and it
// does not wait for a tick. The same time 0 as time().
nanoseconds :: proc "contextless" () -> u64 {
	record := (^op.Time_Record)(uintptr(op.TIME_ADDRESS))
	passed := cycles() - record.cycle_start
	frequency := max(record.cycle_frequency, 1)
	// The seconds and the rest are divided apart: no product overflows.
	return passed / frequency * 1_000_000_000 + passed % frequency * 1_000_000_000 / frequency
}

// time_entered gives the milliseconds since boot with a kernel entry. The
// kernel also does the commands in the kernel ring of the thread.
time_entered :: proc "contextless" () -> u64 {
	return enter(0)
}

// sleep stops the thread until the time is deadline. It gives the time.
sleep :: proc "contextless" (deadline: u64) -> u64 {
	return enter(max(deadline, 1))
}

stop :: proc "contextless" (code: u32 = 0) -> ! {
	call(.Program_Stop, 0, u64(code))
	for {}
}

// context_record gives the context of this program: it is at a fixed address.
context_record :: #force_inline proc "contextless" () -> ^Context {
	return (^Context)(uintptr(op.CONTEXT_ADDRESS))
}

// own_budget gives the budget that this program received when it started.
own_budget :: proc "contextless" () -> Handle {
	return context_record().handles[op.CONTEXT_BUDGET]
}

// budget_create moves amounts from a budget (0: the budget of this program)
// to a new budget.
budget_create :: proc "contextless" (amounts: Budget_Amounts, from: Handle = 0, error: ^errors.Error_Record = nil) -> (budget: Handle, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Budget_Create, u64(from == 0 ? own_budget() : from), amounts.pages, amounts.programs, amounts.threads, amounts.processor, amounts.log_records)
	return Handle(results[0]), status
}

// budget_read gives what a budget (0: the budget of this program) can still pay.
budget_read :: proc "contextless" (budget: Handle = 0, error: ^errors.Error_Record = nil) -> (amounts: Budget_Amounts, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Budget_Read, u64(budget == 0 ? own_budget() : budget))
	return {pages = results[0], programs = results[1], threads = results[2], processor = results[3], log_records = results[4]}, status
}

// budget_used gives the microseconds of processor time that a budget (0: the
// budget of this program) used since it was made, with the budgets that came
// from it, and the log records that the kernel refused.
budget_used :: proc "contextless" (budget: Handle = 0) -> (processor_time: u64, refused: u64) {
	results, _ := call(.Budget_Read, u64(budget == 0 ? own_budget() : budget))
	return results[5], results[6]
}

// memory_create makes a memory object. The budget (0: the budget of this
// program) pays for its pages now. Each page gets its page frame at its
// first use, or at creation with the flag Frames_Now.
memory_create :: proc "contextless" (page_count: u64, budget: Handle = 0, flags: op.Memory_Flags = {}, error: ^errors.Error_Record = nil) -> (memory: Handle, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Create, u64(budget == 0 ? own_budget() : budget), page_count, transmute(u64)flags)
	return Handle(results[0]), status
}

// memory_map maps a memory object in this program (program 0) or in another.
// address 0 lets the kernel choose. page_count 0 maps all pages from first.
memory_map :: proc "contextless" (memory: Handle, flags: op.Map_Flags = {.Write}, program: Handle = 0, address: u64 = 0, first: u64 = 0, page_count: u64 = 0, error: ^errors.Error_Record = nil) -> (result: rawptr, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Map, u64(memory), u64(program), address, transmute(u64)flags, first, page_count)
	return rawptr(uintptr(results[0])), status
}

memory_unmap :: proc "contextless" (address: rawptr, program: Handle = 0, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Memory_Unmap, u64(program), u64(uintptr(address)))
	return status
}

// memory_commit commits the pages of a table of ranges of an object made
// with the flag Uncommitted: the budget pays one page for each page that
// was not committed. The budget (0: the budget of this program) must be the
// budget of the object, with the right Commit or Spend. It gives the pages
// that changed. The ranges are in increasing order and do not overlap
// (op.RANGE_TABLE_CAPACITY ranges and op.RANGE_TABLE_PAGE_LIMIT pages at most).
memory_commit :: proc "contextless" (memory: Handle, ranges: []op.Page_Range, budget: Handle = 0, error: ^errors.Error_Record = nil) -> (changed: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Commit, u64(memory), u64(budget == 0 ? own_budget() : budget), u64(uintptr(raw_data(ranges))), u64(len(ranges)), 0)
	return results[0], status
}

// memory_decommit takes back the committed pages of a table of ranges: the
// frames and the pages return to the budget at once; the addresses stay,
// and a page committed again is zero. The object must be mapped once, by
// this program only.
memory_decommit :: proc "contextless" (memory: Handle, ranges: []op.Page_Range, error: ^errors.Error_Record = nil) -> (changed: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Commit, u64(memory), 0, u64(uintptr(raw_data(ranges))), u64(len(ranges)), transmute(u64)op.Commit_Flags{.Decommit})
	return results[0], status
}

// memory_protect sets the protection of the pages of a table of ranges of
// addresses of this program: {} is read only, {.Write}, {.Execute}, or
// {.No_Access}. It can only take away what each mapping has.
memory_protect :: proc "contextless" (ranges: []op.Address_Range, flags: op.Map_Flags, error: ^errors.Error_Record = nil) -> (changed: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Protect, u64(uintptr(raw_data(ranges))), u64(len(ranges)), transmute(u64)flags)
	return results[0], status
}

// The fault ring (docs/ARCHITECTURE.md, "The fault ring").

// fault_handler_set makes a thread of this program its fault handler (0:
// the thread that calls it): the page faults of the other threads become
// records of the ring in the thread record of the handler, and each
// faulting thread waits for fault_answer.
fault_handler_set :: proc "contextless" (thread: Handle = 0, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Fault_Handler_Set, u64(thread), 0)
	return status
}

// fault_handler_end ends the delivery: a page fault stops the program again.
// If a thread waits for an answer, its record is lost with the ring: the
// program stops with STOP_CODE_FAULT_UNANSWERED. Answer first.
fault_handler_end :: proc "contextless" () -> Status {
	_, status := call(.Fault_Handler_Set, 0, 1)
	return status
}

// fault_answer answers for the thread of a record: Resume runs the faulting
// instruction again, Stop stops the program with the report of the fault.
fault_answer :: proc "contextless" (record: op.Fault_Record, answer: op.Fault_Answer_Kind, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Fault_Answer, record.thread, record.serial, u64(answer))
	return status
}

// fault_record_next gives the next record of the fault ring of the thread
// that calls it, its fault handler. It waits until one comes, or until the
// deadline (false).
fault_record_next :: proc "contextless" (deadline: u64 = WAIT_FOREVER) -> (record: op.Fault_Record, ok: bool) {
	own := thread_record()
	for {
		written := intrinsics.atomic_load(&own.fault_written)
		read := intrinsics.atomic_load(&own.fault_read)
		if written != read {
			record = own.fault_records[read % op.FAULT_RECORD_CAPACITY]
			// The place is free again for the kernel after this store.
			intrinsics.atomic_store(&own.fault_read, read + 1)
			return record, true
		}
		if word_wait(&own.fault_written, written, deadline) >= deadline {
			return {}, false
		}
	}
}

// memory_physical gives the physical address of the first page of a memory
// object: its pages follow each other. The machine handle needs the right
// Physical.
memory_physical :: proc "contextless" (machine: Handle, memory: Handle, error: ^errors.Error_Record = nil) -> (address: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Physical, u64(machine), u64(memory))
	return results[0], status
}

// memory_size gives the pages of a memory object, or 0 when the kernel
// refuses; then the error record is at error, if it is not nil.
memory_size :: proc "contextless" (memory: Handle, error: ^errors.Error_Record = nil) -> u64 {
	results, _ := call_with_error(error, .Memory_Size, u64(memory))
	return results[0]
}

// give copies a handle to another program. target is a program handle, or a
// memory handle: then the other program that maps this memory receives it.
// With the target 0, the copy is in this program.
// The new handle has the rights of handle that are also in rights.
// The result is the handle in the table of that program.
give :: proc "contextless" (target: Handle, handle: Handle, rights: Rights, error: ^errors.Error_Record = nil) -> (result: Handle, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Handle_Give, u64(target), u64(handle), u64(transmute(u32)rights))
	return Handle(results[0]), status
}

// handle_state gives the kind of the object of a handle, and the rights of
// the handle. kind is None when the number names no handle of this program.
// through says if the handle came through a memory object: another program
// gave it with this memory as the target of give.
handle_state :: proc "contextless" (handle: Handle, memory: Handle = 0) -> (kind: op.Object_Kind, rights: Rights, through: bool) {
	results, status := call(.Handle_State, u64(handle), u64(memory))
	if status != .Ok {
		return .None, {}, false
	}
	return op.Object_Kind(results[0]), transmute(Rights)u32(results[1]), results[2] != 0
}

// handle_revoke ends each handle and each mapping that came from a handle:
// in one program (a handle with the right Control), or in each program.
// The handle stays, and the mappings of this program stay. count is the
// count of holdings that ended.
handle_revoke :: proc "contextless" (handle: Handle, program: Handle = 0, error: ^errors.Error_Record = nil) -> (count: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Handle_Revoke, u64(handle), u64(program))
	return results[0], status
}

// region_refusal checks the handle of a data region that a client sent
// with the command Attach of a device ring (contract/block, contract/frame):
// memory, with Read and Write, that came through the ring. When it refuses,
// it gives the values of the error record of the completion.
region_refusal :: proc "contextless" (handle: Handle, ring_memory: Handle, command: u32) -> (values: [7]u64, refused: bool) {
	kind, rights, through := handle_state(handle, ring_memory)
	needed := Rights{.Read, .Write}
	switch {
	case kind != .Memory:
		return errors.ring_fail(command, .Handle_Kind, .None, 1, i64(handle), i64(op.Object_Kind.Memory), i64(kind)), true
	case !(needed <= rights):
		return errors.ring_fail(command, .Handle_Rights, .None, 1, i64(handle), i64(transmute(u32)needed), i64(transmute(u32)rights)), true
	case !through:
		return errors.ring_fail(command, .Absent, .Region, 1), true
	}
	return {}, false
}

// handle_holdings gives the count of the handles and the mappings that
// came from a handle, in each program.
handle_holdings :: proc "contextless" (handle: Handle) -> u64 {
	results, _ := call(.Handle_State, u64(handle), 0)
	return results[3]
}

// A handle that the caller of an export lends for the time of the call
// (module.Type.Handle). RIGHTS is what the export needs: the description of
// the export has it, and the caller lends no other right.
//   fill :: proc "c" (memory: system.Lent({.Read, .Write}), value: i64) -> i64
// In a register and in a record, it is the 32 bits of the handle.
Lent :: struct($RIGHTS: Rights) {
	handle: Handle,
}

close :: proc "contextless" (handle: Handle) {
	call(.Handle_Close, u64(handle))
}

// ring_create makes the memory of a ring and maps it in this program. The
// capacity is the count of records of each queue: a power of two, 32 or
// more. Choose it for the largest burst of the writer.
ring_create :: proc "contextless" (capacity: u32 = ring.CAPACITY) -> (memory: Handle, mapped: ring.Ring, status: Status) {
	if capacity < ring.CAPACITY || capacity > ring.CAPACITY_LIMIT || capacity & (capacity - 1) != 0 {
		return 0, {}, .Bad_Operation
	}
	memory = memory_create(ring.pages(capacity)) or_return
	mapped, status = ring_open(memory)
	if status != .Ok {
		close(memory)
		memory = 0
	}
	return memory, mapped, status
}

// ring_open maps the memory of a ring in this program. The capacity of the
// ring comes from the size of the memory, that the kernel gives.
// error: the record of a refusal, if the caller gives one. The argument 1
// is the memory.
ring_open :: proc "contextless" (memory: Handle, error: ^errors.Error_Record = nil) -> (mapped: ring.Ring, status: Status) {
	page_count := memory_size(memory, error)
	if page_count == 0 {
		return {}, .Bad_Handle // memory_size wrote the record of the kernel.
	}
	if page_count < ring.PAGE_COUNT || page_count > ring.pages(ring.CAPACITY_LIMIT) {
		errors.fail(error, 0, .Bad_Value, .Pages, 1, i64(page_count), i64(ring.pages(ring.CAPACITY_LIMIT)))
		return {}, .Bad_Handle
	}
	address := memory_map(memory, error = error) or_return
	opened, ok := ring.open(address, page_count)
	if !ok {
		memory_unmap(address)
		errors.fail(error, 0, .Malformed, .None, 1) // The header of the ring is not a header that ring.open takes.
		return {}, .Bad_Handle
	}
	return opened, .Ok
}

// ring_close unmaps a ring.
ring_close :: proc "contextless" (mapped: ^ring.Ring) {
	if mapped.head != nil {
		memory_unmap(mapped.head)
	}
	mapped^ = {}
}

// shared_create makes the memory of a shared queue and maps it in this
// program. The capacity is a power of two, 64 or more.
shared_create :: proc "contextless" (capacity: u32 = ring.SHARED_CAPACITY) -> (memory: Handle, mapped: ring.Shared, status: Status) {
	if capacity < ring.SHARED_CAPACITY || capacity > ring.SHARED_CAPACITY_LIMIT || capacity & (capacity - 1) != 0 {
		return 0, {}, .Bad_Operation
	}
	memory = memory_create(ring.shared_pages(capacity)) or_return
	mapped, status = shared_open(memory)
	if status != .Ok {
		close(memory)
		memory = 0
	}
	return memory, mapped, status
}

// shared_open maps the memory of a shared queue in this program. The
// capacity comes from the size of the memory, that the kernel gives.
shared_open :: proc "contextless" (memory: Handle) -> (mapped: ring.Shared, status: Status) {
	page_count := memory_size(memory)
	if page_count > ring.shared_pages(ring.SHARED_CAPACITY_LIMIT) {
		return {}, .Bad_Handle
	}
	address := memory_map(memory) or_return
	opened, ok := ring.shared_open(address, page_count)
	if !ok {
		memory_unmap(address)
		return {}, .Bad_Handle
	}
	return opened, .Ok
}

// shared_close unmaps a shared queue.
shared_close :: proc "contextless" (mapped: ^ring.Shared) {
	if mapped.head != nil {
		memory_unmap(mapped.head)
	}
	mapped^ = {}
}

// A thread of this program, and the memory of its stack.
Thread :: struct {
	handle: Handle,
	stack:  rawptr,
}

// A thread that calls the module cryptography or draws random bytes needs
// 24 KiB of stack at least: the 16 KiB that erase_stack_below_the_caller
// erases below its frame, and its frames (runtime/memory.asm). With less, the
// thread stops at the guard page under its stack, and no other memory is
// written.
THREAD_STACK_PAGES :: 16

// thread_start starts a new thread of this program at entry. The threads of
// a program share all its memory and all its handles. The stack is new
// memory; the page under it has no memory.
// The entry never returns: it calls thread_stop. The budget (0: the budget
// of this program) pays for the thread and gives its processor time. The
// weight (1 to op.WEIGHT_FULL, 0: the full weight) and the request in
// microseconds (0: op.REQUEST_DEFAULT) are for the scheduling strategies
// that use them (docs/SCHEDULING.md).
thread_start :: proc "contextless" (entry: proc "c" (parameter: rawptr) -> !, parameter: rawptr, stack_pages: u64 = THREAD_STACK_PAGES, budget: Handle = 0, weight: u64 = 0, request: u64 = 0, error: ^errors.Error_Record = nil) -> (thread: Thread, status: Status) {
	memory := memory_create(stack_pages, 0, {}, error) or_return
	defer close(memory)
	thread.stack = memory_map(memory, error = error) or_return
	results: [7]u64
	results, status = call_with_error(error, .Thread_Create, u64(budget == 0 ? own_budget() : budget), u64(uintptr(rawptr(entry))), u64(uintptr(thread.stack)) + stack_pages * PAGE_SIZE, u64(uintptr(parameter)), weight, request)
	if status != .Ok {
		memory_unmap(thread.stack)
		return {}, status
	}
	thread.handle = Handle(results[0])
	return thread, .Ok
}

// strategy_set changes the scheduling strategy of the machine while it
// runs, and gives the strategy before. The machine handle needs the right
// Schedule.
strategy_set :: proc "contextless" (machine: Handle, strategy: op.Strategy, error: ^errors.Error_Record = nil) -> (before: op.Strategy, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Strategy_Set, u64(machine), u64(strategy))
	return op.Strategy(results[0]), status
}

// thread_stop ends the thread that calls it.
thread_stop :: proc "contextless" () -> ! {
	call(.Thread_Stop, 0)
	for {}
}

// thread_stopped says if a thread ended.
thread_stopped :: proc "contextless" (thread: Thread) -> bool {
	results, status := call(.Thread_State, u64(thread.handle))
	return status != .Ok || op.Program_State(results[0]) == .Stopped
}

// thread_end stops a thread if it runs, then frees its stack and its handle.
thread_end :: proc "contextless" (thread: Thread) {
	call(.Thread_Stop, u64(thread.handle))
	memory_unmap(thread.stack)
	close(thread.handle)
}

// thread_wait waits until a thread ends by itself, then frees its stack and
// its handle. The end of a thread is an event for the other threads.
thread_wait :: proc "contextless" (thread: Thread) {
	for {
		wait := wait_begin()
		if thread_stopped(thread) {
			break
		}
		wait_end(&wait)
	}
	thread_end(thread)
}
