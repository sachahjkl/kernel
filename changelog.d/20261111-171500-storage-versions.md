type: Added

**Every program gets versions of its data.** The storage service keeps the state of an object before each change, with no save action and no code in the program. A program or the person lists the versions of an object, reads one, compares two, restores one (nothing is lost: the state before the restore stays a version), and clones an object, which shares its blocks until one side changes. Old versions are thinned: each one is kept for 10 minutes, then one an hour for a day, then one a day; at the limit of a store the oldest go first. Disks of the earlier format are not read.
