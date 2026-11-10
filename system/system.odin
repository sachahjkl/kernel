// The system library: what a program uses to talk to the kernel and to other
// programs. It is compiled into each program. It allocates no hidden memory.
package system

import op "../kernel/operation"
import "../ring"

Handle :: op.Handle
Status :: op.Status
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

kernel_ring :: #force_inline proc "contextless" () -> ^ring.Ring {
	return (^ring.Ring)(uintptr(thread_record()) + PAGE_SIZE)
}

// call executes one kernel operation and gives its completion.
call :: proc "contextless" (operation: op.Operation, values: ..u64) -> (results: [7]u64, status: Status) {
	command := ring.Record {
		kind = u32(operation),
	}
	for value, index in values {
		command.values[index] = value
	}
	ring.push(&kernel_ring().commands, command)
	system_enter(0)
	completion, ok := ring.pop(&kernel_ring().completions)
	if !ok {
		return {}, .Bad_Operation
	}
	return completion.values, Status(completion.kind)
}

// time gives the milliseconds since boot.
time :: proc "contextless" () -> u64 {
	return system_enter(0)
}

// wait stops the thread until another thread or an interrupt wakes it, or
// until the time is deadline. It gives the time. A wake can be for another
// thread of the program: read the queues, then wait again.
wait :: proc "contextless" (deadline: u64 = WAIT_FOREVER) -> u64 {
	return system_enter(max(deadline, 1))
}

stop :: proc "contextless" (code: u32 = 0) -> ! {
	call(.Program_Stop, 0, u64(code))
	for {}
}

memory_create :: proc "contextless" (page_count: u64) -> (memory: Handle, status: Status) {
	results: [7]u64
	results, status = call(.Memory_Create, page_count)
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
// The result is the handle in the table of that program.
give :: proc "contextless" (target: Handle, handle: Handle) -> (result: Handle, status: Status) {
	results: [7]u64
	results, status = call(.Handle_Give, u64(target), u64(handle))
	return Handle(results[0]), status
}

close :: proc "contextless" (handle: Handle) {
	call(.Handle_Close, u64(handle))
}

// wake wakes the other threads of all programs that map this memory: the
// other side of a ring.
wake :: proc "contextless" (memory: Handle) {
	call(.Wake, u64(memory))
}

// ring_create makes the memory of a ring and maps it in this program.
ring_create :: proc "contextless" () -> (memory: Handle, mapped: ^ring.Ring, status: Status) {
	memory = memory_create(ring.PAGE_COUNT) or_return
	address := memory_map(memory) or_return
	return memory, (^ring.Ring)(address), .Ok
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
// The entry never returns: it calls thread_stop.
thread_start :: proc "contextless" (entry: proc "c" (parameter: rawptr) -> !, parameter: rawptr, stack_pages: u64 = THREAD_STACK_PAGES) -> (thread: Thread, status: Status) {
	memory := memory_create(stack_pages) or_return
	defer close(memory)
	thread.stack = memory_map(memory) or_return
	results: [7]u64
	results, status = call(.Thread_Create, u64(uintptr(rawptr(entry))), u64(uintptr(thread.stack)) + stack_pages * PAGE_SIZE, u64(uintptr(parameter)))
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
// its handle. The kernel wakes the threads of a program when one of them ends.
thread_wait :: proc "contextless" (thread: Thread) {
	for !thread_stopped(thread) {
		wait()
	}
	thread_end(thread)
}
