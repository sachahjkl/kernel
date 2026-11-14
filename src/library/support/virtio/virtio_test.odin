#+build !freestanding
package virtio

import "core:testing"

// A device whose status is 0 finished its reset.
@(test)
reset_is_done_when_the_status_is_zero :: proc(t: ^testing.T) {
	registers: [64]u8
	device := Device{common = uintptr(&registers[0])}
	testing.expect(t, reset_done(&device))
}

// A device that keeps a status never finishes its reset: the wait ends
// after its count of reads, and start gives the error with no other write.
@(test)
reset_wait_ends_on_a_device_that_keeps_its_status :: proc(t: ^testing.T) {
	registers: [64]u8
	registers[COMMON_STATUS] = STATUS_ACKNOWLEDGE
	device := Device{common = uintptr(&registers[0])}
	testing.expect(t, !reset_done(&device))
	testing.expect_value(t, registers[COMMON_STATUS], u8(STATUS_ACKNOWLEDGE))
}

// start on registers of plain memory: the write of 0 reads back as 0, so
// the reset is done, and the registers have no virtio 1 bit.
@(test)
start_goes_past_a_reset_that_is_done :: proc(t: ^testing.T) {
	registers: [64]u8
	registers[COMMON_STATUS] = STATUS_DRIVER_OK
	device := Device{common = uintptr(&registers[0])}
	_, start_error := start(&device, 0)
	testing.expect_value(t, start_error, Start_Error.No_Version_1)
	testing.expect_value(t, registers[COMMON_STATUS], u8(STATUS_ACKNOWLEDGE | STATUS_DRIVER))
}
