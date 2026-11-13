package kerneltool

import "core:strings"
import "core:sys/linux"
import "core:time"

// The wait for a change of the log of a machine: the kernel of the host
// tells the tool when QEMU wrote in the file, so a wait for a line of the
// log ends when the line comes, not at the next turn of a clock. The poll
// with LOG_POLL_PERIOD stays under it: before QEMU made the file, and on a
// host where the watch is refused.

Log_Watch :: struct {
	descriptor: linux.Fd,
	open:       bool, // The descriptor exists.
	watching:   bool, // The descriptor watches the file.
}

@(private = "file")
log_watch_period_milliseconds :: proc() -> i32 {
	return i32(LOG_POLL_PERIOD / time.Millisecond)
}

// log_watch_wait ends when the file changed since the last call, or after
// LOG_POLL_PERIOD. The caller then reads the file again: a change between
// two calls is kept for the next call, so no change is lost.
log_watch_wait :: proc(watch: ^Log_Watch, path: string) {
	if !watch.open {
		descriptor, error := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
		if error != .NONE {
			time.sleep(LOG_POLL_PERIOD)
			return
		}
		watch.descriptor, watch.open = descriptor, true
	}
	if !watch.watching {
		// QEMU makes the file when it starts: until then, the poll.
		_, error := linux.inotify_add_watch(watch.descriptor, strings.clone_to_cstring(path, context.temp_allocator), {.MODIFY})
		if error != .NONE {
			time.sleep(LOG_POLL_PERIOD)
			return
		}
		watch.watching = true
		// The file can have changed before the watch began: the caller
		// reads it now.
		return
	}
	descriptors := [1]linux.Poll_Fd{{fd = watch.descriptor, events = {.IN}}}
	_, _ = linux.poll(descriptors[:], log_watch_period_milliseconds())
	// Take each record of a change: the next call waits for a new one.
	buffer: [4096]u8
	for {
		count, error := linux.read(watch.descriptor, buffer[:])
		if error != .NONE || count <= 0 {
			break
		}
	}
}

log_watch_close :: proc(watch: ^Log_Watch) {
	if watch.open {
		_ = linux.close(watch.descriptor)
	}
	watch^ = {}
}
