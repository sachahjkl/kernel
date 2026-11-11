type: Added

**A load names each missing import**: when `load` in the console fails because a module is missing or has the wrong hash, it prints a line for each import of the whole graph that is missing or wrong, not only the first.
