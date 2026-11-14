package system

// The hang bound of the checks of a program, in milliseconds of the machine
// (docs/TOOLS.md, "The bounds of the tests"). A check tests a condition (a
// value, a state, a stop); a time in it has one role: to end a wait that
// would never end, so that the program writes its own report of the hang.
// The bound is generous and the same for each wait, never tuned to how fast
// the work is on some host: a loaded host runs the machine many times
// slower, and that says nothing about the system. Where a case writes a
// count of its progress, the bound is on a stall: this long with no growth
// of the count. It is smaller than the hang bound of a step of a machine
// test in kerneltool (HANG_BOUND, 120 s), so that the report of the program
// comes first.
TEST_HANG_BOUND_MILLISECONDS :: 60_000
// The whole run of a case that writes a count of its progress: it ends a
// case that goes on for ever while its count still grows. The step of
// kerneltool that waits for such a case has a larger bound of its own
// (PROGRESS_CASE_HANG_BOUND_SECONDS, 660 s).
TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS :: 600_000
