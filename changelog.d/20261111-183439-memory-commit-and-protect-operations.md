type: Changed

**Two new kernel operations and a narrow right on budgets**: the kernel has 29 operations (`Memory_Commit` 28, `Memory_Protect` 29). A commit names the budget that pays for the object; the new right `Commit` on a budget handle lets another program commit pages of that object and nothing else, so a program can let another one grow its object without letting it create objects on its budget.
