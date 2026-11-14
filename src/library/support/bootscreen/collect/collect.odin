// The reader of the boot display: it fills a bootscreen.Data with the
// records of the kernel. The program needs the machine with the right
// Inspect.
package collect

import "support:bootscreen"
import op "contract:operation"
import "support:system"

// data fills a Data with the boot report, the system report, the report of
// each processor, the report of each program, and the name of the
// processor. A report that the kernel refuses stays zero: its card shows
// that the fact is not known.
data :: proc "contextless" (result: ^bootscreen.Data, machine: system.Handle) {
	inspect :: proc "contextless" (machine: system.Handle, kind: op.Inspect_Kind, index: u64, report: ^$T) {
		system.call(.Inspect, u64(machine), u64(kind), index, u64(uintptr(report)), size_of(T))
	}
	inspect(machine, .Boot, 0, &result.boot)
	inspect(machine, .System, 0, &result.machine)
	for &processor, index in result.processors[:min(result.machine.processors, bootscreen.PROCESSOR_ROWS)] {
		inspect(machine, .Processor, u64(index), &processor)
	}
	result.program_count = 0
	result.program_total = 0
	for slot in 1 ..< result.machine.program_slots {
		report: op.Program_Report
		inspect(machine, .Program, slot, &report)
		if report.state == .None {
			continue
		}
		result.program_total += 1
		if result.program_count < bootscreen.PROGRAM_ROWS {
			result.programs[result.program_count] = {slot = slot, report = report}
			result.program_count += 1
		}
	}
	if result.processor_name[0] == 0 {
		result.processor_name = bootscreen.processor_name()
	}
}
