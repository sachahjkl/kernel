type: Fixed

**The program `clock` no longer fails when its thread leaves its processor between two reads of the time**: it checked that a kernel entry and a read of the time page were at most 1 ms apart, which a busy machine does not give. It now checks that the time of a kernel entry is between two reads of the page around it.
