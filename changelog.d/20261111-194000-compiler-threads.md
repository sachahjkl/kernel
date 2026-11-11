type: Changed

**The compiler runs on all its threads, with no patch**: with the release dev-2026-11a of Odin, the same source gives the same module for any count of compiler threads (20 builds of each of the 64 modules, one result each). The patch of 0.59.0 and the option `-thread-count:1` are removed.
