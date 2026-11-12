type: Fixed

**No text of the system is cut in silence**: a log line longer than 512 bytes was cut with no sign, and so was each text that a program formats in a buffer too small; the log now takes a text whole, in several lines, and a text that a place cannot hold ends with "... and N bytes more". The console refuses a program name longer than 31 bytes, which the root service cut before.
