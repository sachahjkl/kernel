package system

import op "contract:operation"

// The name of the resource of the boot image that makes a measure run: the
// root service looks for it, and the tool puts it in the boot image of
// `kerneltool measure` only (docs/TOOLS.md, "A check by count, a measure by time").
MEASURE_RUN_RESOURCE :: "measure_run"

// measure_run says if this program runs for a measure: its starter wrote 1
// in the value of the context for it. A program then measures its rates
// over a duration; else it runs its checks only, which end after a count
// of work (docs/TOOLS.md, "A check by count, a measure by time").
measure_run :: proc "contextless" () -> bool {
	return context_record().values[op.CONTEXT_VALUE_MEASURE_RUN] != 0
}
