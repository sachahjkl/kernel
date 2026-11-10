// A module of commands that tests the sandbox of an isolated call
// (property 19). Each export does what a module must not be able to do to
// its caller: read any address, take all the processor time, use a handle
// that it did not receive.
// The console calls it with isolate("probe"). Do not load it directly: then
// it runs with the memory and the handles of the console.
package probe

import op "../../kernel/operation"
import "../../system"
import "base:intrinsics"

// peek reads 8 bytes at an address. In a call host, the address space has
// only the module, the call ring and the call region.
@(export, link_name = "peek")
peek :: proc "c" (address: i64) -> i64 {
	return intrinsics.volatile_load((^i64)(uintptr(address)))
}

calls: i64

// count gives the number of calls of count since the module started. The
// data of a module is private to the program that runs it.
@(export, link_name = "count")
count :: proc "c" () -> i64 {
	calls += 1
	return calls
}

// spin never returns.
@(export, link_name = "spin")
spin :: proc "c" () -> i64 {
	for {
		intrinsics.volatile_store(&calls, intrinsics.volatile_load(&calls) + 1)
	}
}

// stop_machine asks the kernel to stop the machine, with a handle number
// that the caller gives. The result is the status of the kernel operation.
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
