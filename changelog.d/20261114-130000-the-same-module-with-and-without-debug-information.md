type: Changed

**The same module with and without debug information**: the build asks the compiler for a kind of debug information that adds no instruction to the code, `-debug-info:same-code`, an option of the fork of Odin that the flake pins. Each of the 89 modules is the same bytes with and without debug information, so the full check passes again. A debugger loses little: for `inspect`, the locations of the local variables cover 0.3 % fewer bytes.
