#+build !linux
package kerneltool

import "core:time"

// The wait for a change of the log of a machine, on a host with no watch
// of a file: the poll with LOG_POLL_PERIOD (log_watch_linux.odin has the
// watch).

Log_Watch :: struct {}

log_watch_wait :: proc(watch: ^Log_Watch, path: string) {
	time.sleep(LOG_POLL_PERIOD)
}

log_watch_close :: proc(watch: ^Log_Watch) {
}
