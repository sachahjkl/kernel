// A module of commands that tests the sandbox of an isolated call. A call
// to a module that is not trusted runs the module as its own program, and
// its arguments travel as records. Each export does what a module must not
// be able to do to its caller: read any address, take all the processor
// time, use a handle that it did not receive.
// The console calls it with isolate("probe"). Do not load it directly: then
// it runs with the memory and the handles of the console.
//
// **What it is for.** It shows the limits of a sandbox from the inside. A
// reader calls the exports one by one and sees that each harm stays in the
// sandboxed program: the console goes on, and the next call gets a new
// program with new data.
//
// **Example**, in the console:
//
// ```
// isolate("probe")        probe: 8 commands in a sandboxed program
// count() + count() * 10  21
// stop_machine(1)         2: the sandbox holds no handle
// peek(0)                 error: the program probe stopped: page fault
// count()                 1: a new program
// spin()                  Escape stops the call
// ```
package probe

import op "contract:operation"
import "support:system"
import "base:intrinsics"

// peek reads 8 bytes at an address. In a call host, the address space has
// only the module, the call ring and the call region.
//
// An address outside these stops the sandboxed program on a page fault; the console reports it, and its own
// memory is not reachable. After `load("probe")` the same call reads the memory of the console.
@(export, link_name = "peek")
peek :: proc "c" (address: i64) -> i64 {
	return intrinsics.volatile_load((^i64)(uintptr(address)))
}

calls: i64

// count gives the number of calls of count. The data of a module is private
// to the program that runs it.
//
// It starts at 1 in each new sandboxed program: a fault in an earlier call resets it.
@(export, link_name = "count")
count :: proc "c" () -> i64 {
	calls += 1
	return calls
}

// spin never returns.
//
// The console runs the line in its second thread, keeps the keys of the next line, and stops the call when the
// input presses Escape: "error: Escape stopped the call of spin". The sandbox has its own budget of processor
// time, so other programs go on.
@(export, link_name = "spin")
spin :: proc "c" () -> i64 {
	for {
		intrinsics.volatile_store(&calls, intrinsics.volatile_load(&calls) + 1)
	}
}

// stop_machine asks the kernel to stop the machine with a handle. The
// result is the status of the kernel operation.
//
// In a sandbox the handle names nothing: the result is 2, "no handle", for each value. The machine never stops
// through this export unless the caller loaded the module directly and passes the number of a handle of the
// machine that it holds.
@(export, link_name = "stop_machine")
stop_machine :: proc "c" (handle: i64) -> i64 {
	_, status := system.call(op.Operation.Machine_Stop, u64(handle), 0)
	return i64(status)
}

// checksum adds the bytes of a text. The bytes are in the call region.
@(export, link_name = "checksum")
checksum :: proc "c" (text: ^string) -> i64 {
	sum: i64
	for i in 0 ..< len(text) {
		sum += i64(text[i])
	}
	return sum
}

// shout gives a text in capital letters. In a call host, the buffer of the
// result is in the call region: the caller reads the text there.
@(export, link_name = "shout")
shout :: proc "c" (text: ^string, result: ^[]u8) -> i64 {
	for i in 0 ..< min(len(text), len(result)) {
		c := text[i]
		result[i] = c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c
	}
	return i64(len(text))
}

// lie writes no text, and gives a false count of bytes. The caller must not
// read more than its buffer.
//
// `lie(100000)` gives "error: the result of lie has 100000 bytes: it does not fit"; `length(lie(3))` gives 3:
// the console reads the bytes that the call region holds, never more.
@(export, link_name = "lie")
lie :: proc "c" (count: i64, result: ^[]u8) -> i64 {
	return count
}

// A text for log_long, filled at each call.
LONG_TEXT_LIMIT :: 2000
long_text: [LONG_TEXT_LIMIT]u8

// log_long writes one text of count bytes on the log (at most 2000): digits, then the words "the end of the long text". The log keeps a text whole: a text longer than its part of 512 bytes goes in several lines, never cut in silence. The result is the count of bytes of the text.
@(export, link_name = "log_long")
log_long :: proc "c" (count: i64) -> i64 {
	END :: " the end of the long text"
	size := int(clamp(count, len(END), LONG_TEXT_LIMIT))
	body := size - len(END)
	for index in 0 ..< body {
		long_text[index] = u8('0' + index % 10)
	}
	system.log(string(long_text[:body]), END)
	return i64(size)
}
