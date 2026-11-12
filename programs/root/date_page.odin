package root

import "contract:fixed_addresses"
import "contract:date"
import op "contract:operation"
import "support:system"

// The date (contract/date): this service creates the date page, gives it
// with Write and the two ports of the real-time clock to the program
// `date`, and maps it read-only into each program that it starts.

date_memory: system.Handle

date_page_create :: proc "contextless" () {
	status: system.Status
	date_memory, status = system.memory_create(1)
	if status != .Ok {
		fail("cannot create the date page", status)
	}
}

// date_page_give adds the date page, read-only, to the mappings of a
// program, and sets its bit in the values.
date_page_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^[op.CONTEXT_VALUES]u64) {
	if date_memory == 0 || count^ >= len(mappings) {
		return
	}
	mappings[count^] = {memory = date_memory, address = date.PAGE_ADDRESS, first = 0, page_count = 1, flags = {}}
	count^ += 1
	fixed_addresses.range_mapped_add(values, .Date_Page)
}
