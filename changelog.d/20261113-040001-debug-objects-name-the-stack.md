type: Added

**A stop report names its procedures and its source lines**: the build writes a debug object for each module (its procedures and its line table, made from the DWARF of the compiler) and puts them in a debug image beside the boot program, not in the boot image. The console, `errors` and `inspect` now show a frame as `fault::three + 0x8 in fault (programs/fault/main.odin:15)`; the module bytes are the same with and without debug information, and `kerneltool check` proves it with a third build.
