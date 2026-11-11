type: Added

**Tables and bytes as parameters**: an export takes a table of records or a run of bytes, to read, to change or to append to, in memory of the caller. The same description works in a direct call, in a call host and in a service; the console, `kerneltool call` and `remote` take a table as an argument. A table of 65536 records can pass as a memory object, with no copy.
