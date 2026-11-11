#+build !freestanding
package sample

import "base:intrinsics"
import "contract:errors"
import "core:testing"
import "core:thread"
import "support:system"

// Another thread of the caller changes a record of the shared call region
// while sum_words reads it (finding W2 of the hostile read). The export
// copies the record once and uses only the copy: it gives a sum or an
// error record, never a fault.
@(test)
a_record_that_changes_during_the_call :: proc(t: ^testing.T) {
	Shared :: struct {
		words: [1]Word,
		stop:  bool,
	}
	shared: Shared
	shared.words[0] = {start = 0, count = 4}
	changer := thread.create_and_start_with_data(&shared, proc(data: rawptr) {
		shared := (^Shared)(data)
		for !intrinsics.atomic_load(&shared.stop) {
			intrinsics.volatile_store(&shared.words[0].start, 7)
			intrinsics.volatile_store(&shared.words[0].start, 0)
		}
	})
	text := "abcdefgh"
	answers: [2]int
	for _ in 0 ..< 2_000_000 {
		words := system.Table_To_Change(Word){records = &shared.words[0], count = 1, capacity = 1}
		bytes := system.Bytes_To_Read{bytes = raw_data(text), count = 8, capacity = 8}
		error: errors.Error_Record
		result := sum_words(&words, &bytes, &error)
		answers[result < 0 ? 1 : 0] += 1
	}
	intrinsics.atomic_store(&shared.stop, true)
	thread.join(changer)
	thread.destroy(changer)
	testing.expect(t, answers[0] > 0 && answers[1] > 0, "the two values of start were both seen")
}

// The test runs on the host: the module links support/system, whose entries
// of the machine (support/system/enter.asm) are not on the host. These
// definitions are never called by sum_words; each one stops the test if it
// is.
@(export, link_name = "system_enter")
host_system_enter :: proc "c" (wait: u64) -> u64 {intrinsics.trap()}
@(export, link_name = "thread_record")
host_thread_record :: proc "c" () -> rawptr {intrinsics.trap()}
@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}
@(export, link_name = "port_write_8")
host_port_write_8 :: proc "c" (port: u16, value: u8) {intrinsics.trap()}
@(export, link_name = "port_read_8")
host_port_read_8 :: proc "c" (port: u16) -> u8 {intrinsics.trap()}
@(export, link_name = "port_write_32")
host_port_write_32 :: proc "c" (port: u16, value: u32) {intrinsics.trap()}
@(export, link_name = "port_read_32")
host_port_read_32 :: proc "c" (port: u16) -> u32 {intrinsics.trap()}
