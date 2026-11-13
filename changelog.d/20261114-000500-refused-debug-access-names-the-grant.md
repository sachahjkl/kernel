type: Fixed

**A refused debug access names the grant**: `debug("notes")` in the console, and `debugger.attach` from the host, now print "the debug access to this program: the grant Store of the program refuses it". Before, the sentence gave a number ("the grant 7 of the root service") that changed when a grant was added, and only the log of the root service gave the name. The list of the start grants and their names is now a contract, `contract/start_grant`, which the root service and the reader of an error record both read; the number of a start grant no longer changes.
