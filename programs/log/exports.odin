package log

import "contract:errors"
import "contract:isolated"
import op "contract:operation"
import "support:system"
import "base:intrinsics"

// The log is also a service: records() gives the log records as a table of
// records with typed fields (property 19), so that a reader checks the
// program, the channel and the level of a record, not a line of text. The
// serial port keeps the same records as lines: it works before any service
// runs, and when the network does not.
//
// The records of the log are facts of all the programs (property 20): the
// export gives them only to a caller that acts for the person.

// One log record: records(). 256 bytes, the most that a record of a
// description has: the text keeps 168 of the 176 bytes of a log record.
Record :: struct {
	number:  i64, // The number of the record, from 0.
	time:    i64, // Microseconds since the start of the machine.
	program: [32]u8, // The name of the program, or "kernel".
	slot:    i64, // The slot of the program. 0: the kernel.
	level:   [8]u8, // info, debug, warning or error.
	channel: [16]u8, // Empty: the program gave no channel.
	lost:    i64, // The first row only: the records after `after` that the kernel wrote over before this call read them.
	text:    [168]u8,
}
#assert(size_of(Record) == 256)

ERROR_PERSON :: -1

@(rodata)
level_names := [system.Log_Level]string {
	.Info    = "info",
	.Debug   = "debug",
	.Warning = "warning",
	.Error   = "error",
}

service: system.Service
reader_head: ^op.Log_Head
reader_records: [^]op.Log_Record

// records gives the log records from the number `after` on, one row each: the number, the time in microseconds, the program and its slot, the level, the channel, and the text. The first row also gives the records that the kernel wrote over before this call read them. The result is the count of the records from `after` to the last one, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the person).
@(export, link_name = "records")
records :: proc "c" (after: i64, result: ^[]Record, error: ^errors.Error_Record) -> i64 {
	if caller := system.service_caller(); caller != nil && caller.grant & isolated.CALLER_PERSON == 0 {
		return errors.fail(error, ERROR_PERSON, .No_Grant, .Person)
	}
	written := intrinsics.atomic_load(&reader_head.written)
	next := u64(max(after, 0))
	lost: u64
	if next > written {
		next = written
	}
	if written - next > op.LOG_RECORD_CAPACITY {
		lost = written - next - op.LOG_RECORD_CAPACITY
		next += lost
	}
	total := written - next
	count := 0
	for count < len(result^) && next < written {
		record := reader_records[next % op.LOG_RECORD_CAPACITY]
		// The kernel can write over the record during the copy.
		if intrinsics.atomic_load(&reader_head.written) - next > op.LOG_RECORD_CAPACITY {
			lost += 1
			next += 1
			continue
		}
		row := &result[count]
		row^ = {number = i64(record.sequence), time = i64(record.time), slot = i64(record.program)}
		copy(row.program[:len(row.program) - 1], system.name_of(record.name[:]))
		if record.level <= max(system.Log_Level) {
			copy(row.level[:], level_names[record.level])
		}
		copy(row.channel[:], system.name_of(record.channel[:]))
		copy(row.text[:], record.text[:min(int(record.text_count), len(record.text), len(row.text))])
		count += 1
		next += 1
	}
	if count > 0 {
		result[0].lost = i64(lost)
	}
	return i64(total)
}
