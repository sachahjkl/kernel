package system

import op "../kernel/operation"
import "base:intrinsics"

// A reader of the records of the log (operation.Log_Record). The program
// needs the memory object of the log with the right Read.
Log_Reader :: struct {
	head:    ^op.Log_Head,
	records: [^]op.Log_Record,
	next:    u64, // The number of the next record to read.
}

Log_Level :: op.Log_Level
Log_Record :: op.Log_Record

log_open :: proc "contextless" (memory: Handle) -> (reader: Log_Reader, status: Status) {
	address := memory_map(memory, {}) or_return
	reader.head = (^op.Log_Head)(address)
	reader.records = ([^]op.Log_Record)(rawptr(uintptr(address) + size_of(op.Log_Head)))
	return reader, .Ok
}

// log_next gives the next record. lost is the count of records that the
// kernel wrote over before this reader read them.
log_next :: proc "contextless" (reader: ^Log_Reader) -> (record: Log_Record, lost: u64, ok: bool) {
	for {
		written := intrinsics.atomic_load(&reader.head.written)
		if reader.next == written {
			return record, lost, false
		}
		if written - reader.next > op.LOG_RECORD_CAPACITY {
			late := written - reader.next - op.LOG_RECORD_CAPACITY
			lost += late
			reader.next += late
		}
		record = reader.records[reader.next % op.LOG_RECORD_CAPACITY]
		// The kernel can write over the record during the copy.
		if intrinsics.atomic_load(&reader.head.written) - reader.next > op.LOG_RECORD_CAPACITY {
			continue
		}
		reader.next += 1
		return record, lost, true
	}
}

// wait_log adds the log to a wait list: the thread waits while the log has
// no record that the reader did not read.
wait_log :: proc "contextless" (wait: ^Wait, reader: ^Log_Reader) {
	wait_word(wait, (^u32)(&reader.head.written), u32(reader.next))
}
