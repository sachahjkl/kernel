type: Fixed

**A program that maps and unmaps no longer grows its page tables**: a mapping with no address takes the first free range between the mappings of the program; before, each such mapping took a new range and new page tables until the budget refused (a call host refused its 61st call).
