title: A failed call names each thing that went wrong
date: 2026-11-11
release: 0.71.0
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

An export can now give each thing that went wrong in a call, not only the first. The caller gives an optional table of error records, and the export writes one record for each fault. A caller with no table gets the one error record of before. `monitor.counts_named` names each row of its argument that names no count. The console and `kerneltool call` print each detail on its own line after the error. In the check of the step, a call from the host printed "detail 2 of 2: monitor.counts_named: row 3 of the argument names names nothing that exists". The cost for a caller is not measured.
