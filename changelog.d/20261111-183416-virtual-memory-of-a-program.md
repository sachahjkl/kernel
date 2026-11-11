type: Added

**A program drives its own virtual memory**: a memory object made `Uncommitted` holds a range of addresses (1 GiB in one mapping) and its budget pays only for the pages that the program commits; `Memory_Commit` commits and decommits tables of ranges, and a decommit gives the pages back to the budget at once; `Memory_Protect` changes the protection of pages, with `No_Access` for a guard page; an object made `Large_Pages` is mapped with pages of 2 MiB. The program `address_space` shows each case with its numbers.
