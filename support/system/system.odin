// The system library: what a program uses to talk to the kernel and to other
// programs. It is compiled into each program. It allocates no hidden memory.
package system

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

// call executes one kernel operation and gives its completion.
call :: proc "contextless" (operation: op.Operation, values: ..u64) -> (results: [7]u64, status: Status) {
	command := ring.Record {
		kind = u32(operation),
	}
	for value, index in values {
		command.values[index] = value
	}
	kernel := kernel_ring()
	ring.push(&kernel.commands, command)
	system_enter(0)
	completion, ok := ring.pop(&kernel.completions)
	if !ok {
		return {}, .Bad_Operation
	}
	return completion.values, Status(completion.kind)
}

// time gives the milliseconds since boot. It reads the time page: it does
// not enter the kernel.
time :: proc "contextless" () -> u64 {
	record := (^op.Time_Record)(uintptr(op.TIME_ADDRESS))
	return intrinsics.volatile_load(&record.milliseconds)
}

// time_entered gives the milliseconds since boot with a kernel entry. The
// kernel also does the commands in the kernel ring of the thread.
time_entered :: proc "contextless" () -> u64 {
	return system_enter(0)
}

// sleep stops the thread until the time is deadline. It gives the time.
sleep :: proc "contextless" (deadline: u64) -> u64 {
	return system_enter(max(deadline, 1))
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
budget_create :: proc "contextless" (amounts: Budget_Amounts, from: Handle = 0) -> (budget: Handle, status: Status) {
	results: [7]u64
	results, status = call(.Budget_Create, u64(from == 0 ? own_budget() : from), amounts.pages, amounts.programs, amounts.threads, amounts.processor, amounts.log_records)
	return Handle(results[0]), status
}

// budget_read gives what a budget (0: the budget of this program) can still pay.
budget_read :: proc "contextless" (budget: Handle = 0) -> (amounts: Budget_Amounts, status: Status) {
	results: [7]u64
	results, status = call(.Budget_Read, u64(budget == 0 ? own_budget() : budget))
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
// program) pays for its pages.
memory_create :: proc "contextless" (page_count: u64, budget: Handle = 0) -> (memory: Handle, status: Status) {
	results: [7]u64
	results, status = call(.Memory_Create, u64(budget == 0 ? own_budget() : budget), page_count)
	return Handle(results[0]), status
}

// memory_map maps a memory object in this program (program 0) or in another.
// address 0 lets the kernel choose. page_count 0 maps all pages from first.
memory_map :: proc "contextless" (memory: Handle, flags: op.Map_Flags = {.Write}, program: Handle = 0, address: u64 = 0, first: u64 = 0, page_count: u64 = 0) -> (result: rawptr, status: Status) {
	results: [7]u64
	results, status = call(.Memory_Map, u64(memory), u64(program), address, transmute(u64)flags, first, page_count)
	return rawptr(uintptr(results[0])), status
}

memory_unmap :: proc "contextless" (address: rawptr, program: Handle = 0) -> Status {
	_, status := call(.Memory_Unmap, u64(program), u64(uintptr(address)))
	return status
}

memory_size :: proc "contextless" (memory: Handle) -> u64 {
	results, _ := call(.Memory_Size, u64(memory))
	return results[0]
}

// give copies a handle to another program. target is a program handle, or a
// memory handle: then the other program that maps this memory receives it.
// With the target 0, the copy is in this program.
// The new handle has the rights of handle that are also in rights.
// The result is the handle in the table of that program.
give :: proc "contextless" (target: Handle, handle: Handle, rights: Rights) -> (result: Handle, status: Status) {
	results: [7]u64
	results, status = call(.Handle_Give, u64(target), u64(handle), u64(transmute(u32)rights))
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
handle_revoke :: proc "contextless" (handle: Handle, program: Handle = 0) -> (count: u64, status: Status) {
	results: [7]u64
	results, status = call(.Handle_Revoke, u64(handle), u64(program))
	return results[0], status
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
ring_open :: proc "contextless" (memory: Handle) -> (mapped: ring.Ring, status: Status) {
	page_count := memory_size(memory)
	if page_count < ring.PAGE_COUNT || page_count > ring.pages(ring.CAPACITY_LIMIT) {
		return {}, .Bad_Handle
	}
	address := memory_map(memory) or_return
	opened, ok := ring.open(address, page_count)
	if !ok {
		memory_unmap(address)
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

THREAD_STACK_PAGES :: 16

// thread_start starts a new thread of this program at entry. The threads of
// a program share all its memory and all its handles. The stack is new
// memory; the page under it has no memory.
// The entry never returns: it calls thread_stop. The budget (0: the budget
// of this program) pays for the thread and gives its processor time.
thread_start :: proc "contextless" (entry: proc "c" (parameter: rawptr) -> !, parameter: rawptr, stack_pages: u64 = THREAD_STACK_PAGES, budget: Handle = 0) -> (thread: Thread, status: Status) {
	memory := memory_create(stack_pages) or_return
	defer close(memory)
	thread.stack = memory_map(memory) or_return
	results: [7]u64
	results, status = call(.Thread_Create, u64(budget == 0 ? own_budget() : budget), u64(uintptr(rawptr(entry))), u64(uintptr(thread.stack)) + stack_pages * PAGE_SIZE, u64(uintptr(parameter)))
	if status != .Ok {
		memory_unmap(thread.stack)
		return {}, status
	}
	thread.handle = Handle(results[0])
	return thread, .Ok
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
