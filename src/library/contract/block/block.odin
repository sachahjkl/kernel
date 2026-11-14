// The block contract: what a program and a block service agree on. A block
// service is the device service of one disk. The first one drives a virtio
// block device (src/programs/block); a driver of another device class (NVMe)
// serves the same contract.
//
// A disk is a row of blocks of BLOCK_SIZE bytes, numbered from 0. The client
// and the block service share two memory objects:
//
//   the block ring    a ring (package ring). One command record is one
//                     request: read, write or flush of blocks.
//   the data region   memory of the client. The device reads and writes the
//                     bytes of the blocks there, with no copy: a request
//                     names a place in the region, never an address.
//
// The client gives the data region to the block service with the command
// Attach: the handle goes through the memory of the block ring (the kernel
// operation Handle_Give). The block service proves that it came through the
// ring (Handle_State), as for a lent handle.
//
// Many requests are in flight at the same time: the device does them in any
// order, and a completion record has the tag of its command. The block
// service takes a command only when the completion queue has room for its
// completion: a client that does not read its completions stops the
// requests of its own ring, and nothing else. A client with a full command
// queue waits for room (back-pressure).
//
// A write is in the memory of the device when its completion arrives. It is
// on the disk after a Flush that the client sent after that completion. The
// order of two requests in flight is not fixed: a client that needs an order
// waits for the completion of the first one.
//
// This package allocates no memory and calls no kernel operation.
package block

BLOCK_SIZE :: 4096 // The bytes of one block: the unit of each request.
RING_CAPACITY :: 256 // The capacity of the block ring.

// The role of the block ring in the context of a block service.
SERVICE_RING :: 0
// The role of the block ring in the context of a client of a block service.
GRANT_RING :: 6

// A command of a client, as the kind of a command record of the block ring.
Command :: enum u32 {
	None       = 0, // Not a command: Bad_Command.
	// values[0]: the handle of the data region, as the block service names
	// it. A new Attach replaces the region of the one before: send it when
	// no request is in flight.
	Attach     = 1,
	// The completion: values[0] the count of blocks of the disk, values[1]
	// the most blocks of one request, values[2] 1 if the disk keeps writes in
	// a cache that Flush empties.
	Info       = 2,
	// values[0]: the first block. values[1]: the count of blocks.
	// values[2]: the place in the data region, in bytes: a multiple of
	// BLOCK_SIZE.
	Read       = 3,
	Write      = 4, // The values of Read: the blocks are written from the data region.
	// The writes that completed before this command are on the disk when
	// its completion arrives.
	Flush      = 5,
	// The completion: values[0] the requests done, values[1] the blocks read
	// and written, values[2] the kernel entries of the block service, values[3]
	// the interrupts that it received, all since it started.
	Statistics = 6,
}

// The status of a request: the kind of its completion record. When it is
// not Ok, the values of the completion are an error record
// (errors.completion_record).
Status :: enum u32 {
	Ok           = 0, // The request is done: the values are its results.
	Bad_Command  = 1, // The command is not known, or a value is wrong.
	Out_Of_Range = 2, // A block is not on the disk, or a byte is not in the data region.
	No_Region    = 3, // No data region, or the handle did not come through the block ring.
	Device_Error = 4, // The device reported an error.
	Unsupported  = 5, // The device cannot do this request.
}

// The names of the commands and of their values, for the sentence of the
// error record of a completion (errors.completion_record).
@(rodata)
COMMAND_NAMES := [Command]string {
	.None = "None",
	.Attach = "Attach",
	.Info = "Info",
	.Read = "Read",
	.Write = "Write",
	.Flush = "Flush",
	.Statistics = "Statistics",
}

// command_name gives the name of a command from an error record, or "an
// unknown command" for a number out of `Command`.
command_name :: proc "contextless" (command: i64) -> string {
	return command >= 0 && command <= i64(max(Command)) ? COMMAND_NAMES[Command(command)] : "an unknown command"
}

// argument_name gives the name of a value of a command, from 1.
argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	if argument < 1 || argument > 7 {
		return ""
	}
	#partial switch Command(command) {
	case .Attach:
		names := [?]string{"region"}
		return argument <= len(names) ? names[argument - 1] : ""
	case .Read, .Write:
		names := [?]string{"first", "count", "place"}
		return argument <= len(names) ? names[argument - 1] : ""
	}
	return ""
}
