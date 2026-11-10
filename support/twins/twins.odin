// What the program `frames` and its program `twin` agree on (paging,
// second part). `frames` starts each twin with one mode, and reads what the
// twin did.
package twins

// The roles of the context of a twin.
GRANT_PAGE :: 0 // Memory, with Read and Write: one page that `frames` also maps. MODE_WRITE_PAGE only.
VALUE_MODE :: 0

MODE_WAIT :: 0 // Wait with no end: `frames` counts the pages of the twin.
MODE_WRITE_PAGE :: 1 // Write WORD at the start of the page of GRANT_PAGE, and wake the threads that wait on it.
MODE_WRITE_CODE :: 2 // Write to its own code: the kernel stops the twin.

WORD :: u32(0x5EA5_1DE5)
