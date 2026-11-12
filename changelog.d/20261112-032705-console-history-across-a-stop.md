type: Added

**The console keeps its line history across a stop**: after each line, the history goes to a store of its own in the storage service (4 blocks, apart from the store of the person), and at the next start Up and Control-R find the lines of before, also after a stop of the machine. history_clear() forgets it, in memory and on the disk.
