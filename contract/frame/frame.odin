// The frame contract: what a program and a frame service agree on. A frame
// service is the device service of one network device. The first one drives
// a virtio network device (programs/frame); a driver of another device class
// serves the same contract.
//
// A frame is one Ethernet frame, from the destination address to the end of
// the data, with no check sequence: FRAME_LIMIT bytes at most. The client and
// the frame service share two memory objects:
//
//   the frame ring     a ring (package ring). One command record is one
//                      request: send a frame, or give a place for a frame
//                      that the device receives.
//   the frame region   memory of the client. The device reads and writes the
//                      bytes of the frames there, with no copy: a request
//                      names a place in the region, never an address.
//
// The client gives the frame region to the frame service with the command
// Attach: the handle goes through the memory of the frame ring (the kernel
// operation Handle_Give). The frame service proves that it came through the
// ring (Handle_State), as for a lent handle. The region is contiguous: the
// device uses one physical address for each place.
//
// Many requests are in flight at the same time. A Receive stays in flight
// until a frame arrives in its place: the client gives the places for the
// frames before they arrive (property 14), and the device drops a frame when
// no place waits. A completion record has the tag of its command. The frame
// service takes a command only when the completion queue has room for its
// completion: a client that does not read its completions stops the
// requests of its own ring, and nothing else. A client with a full command
// queue waits for room (back-pressure).
//
// The frame service does not read the frames: it checks no address and
// computes no check. The client builds and checks each frame.
//
// This package allocates no memory and calls no kernel operation.
package frame

FRAME_LIMIT :: 1514 // An Ethernet frame with 1500 bytes of data, with no check sequence.
FRAME_LEAST :: 60 // The device adds zero bytes to a shorter frame that it sends.
PLACE_SIZE :: 2048 // A Receive with less room than FRAME_LIMIT can lose a frame.
RING_CAPACITY :: 256 // The capacity of the frame ring.

// The role of the frame ring in the context of a frame service.
SERVICE_RING :: 0
// The role of the frame ring in the context of a client of a frame service.
GRANT_RING :: 6

Command :: enum u32 {
	None       = 0,
	// values[0]: the handle of the frame region, as the frame service names
	// it. A new Attach replaces the region of the one before: send it when no
	// request is in flight.
	Attach     = 1,
	// The completion: values[0] the hardware address of the device (6 bytes,
	// the first byte in the low bits), values[1] 1 if the link is up,
	// values[2] the most bytes of a frame, values[3] the most Receive in
	// flight, values[4] the most Send in flight.
	Info       = 2,
	// values[0]: the place of the frame in the frame region, in bytes.
	// values[1]: its count of bytes, from 14 to FRAME_LIMIT.
	Send       = 3,
	// values[0]: the place in the frame region, in bytes. values[1]: the room
	// there, in bytes. The completion comes when a frame arrives: values[0]
	// is its count of bytes.
	Receive    = 4,
	// The completion: values[0] the frames sent, values[1] the frames
	// received, values[2] the kernel entries of the frame service, values[3]
	// the interrupts that it received, values[4] the bytes sent, values[5]
	// the bytes received, all since it started.
	Statistics = 5,
}

// The status of a request: the kind of its completion record.
Status :: enum u32 {
	Ok           = 0,
	Bad_Command  = 1, // The command is not known, or a value is wrong.
	Out_Of_Range = 2, // A byte is not in the frame region.
	No_Region    = 3, // No frame region, or the handle did not come through the frame ring.
	Device_Error = 4, // The device reported an error.
	Too_Large    = 5, // A Send of more than FRAME_LIMIT bytes or of less than a header.
	Too_Many     = 6, // More Receive in flight than the device has places.
}

// hardware gives the 6 bytes of a hardware address in values[0] of Info.
hardware :: proc "contextless" (value: u64) -> (address: [6]u8) {
	for &byte, index in address {
		byte = u8(value >> (8 * uint(index)))
	}
	return address
}
