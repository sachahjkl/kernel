type: Fixed

**An unmap gives back the page tables that it empties**: a page table that a mapping made returns to the budget that paid for it when the last mapping in it ends, at each level of the table. Before, it stayed until the program ended: a program that mapped at many addresses lost one page for each 2 MiB that it ever used, and a parent was one page short after its first child. An Uncommitted object of 1 GiB now keeps 0 pages after its unmap, where it kept 513.
