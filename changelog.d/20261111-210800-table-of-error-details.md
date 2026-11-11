type: Added

**A table of error details**: an export can give each thing that went wrong, not only the first, in an optional table of error records that the caller gives. A caller with no table gets the one error record of before. `monitor.counts_named` names each row that names no count, and the console and `kerneltool call` print each detail on its own line after the error.
