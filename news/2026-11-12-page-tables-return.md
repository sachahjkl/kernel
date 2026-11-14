title: An unmap gives its page tables back
date: 2026-11-12
release: 0.92.0
picture: none
kind: Fixed
guide: docs/ARCHITECTURE.md

A page table that a mapping made now returns to the budget that paid for it when the last mapping in it ends. Before, the table stayed until the program ended. A program that maps at many addresses, as the loader that starts each child does, lost one page for each 2 MiB that it ever used. The budget of a parent is now the same before the start of a child and after its end. An Uncommitted object of 1 GiB keeps 0 pages after its unmap, where it kept 513. The program address_space checks it at three levels of the table, for a reservation, for a large page, and while another thread uses a page of the same table.
