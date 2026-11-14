type: Fixed

**The window of the program `heron` no longer shows a half-drawn heron**: during a fast move, one picture of the screen could show the head of the heron and none of its body, which a reader sees as a flicker. The program now draws a picture that the screen does not read, and the screen takes it when it is complete. Each key of the program also writes one line on the log: the pause, the speed, the cell size, and the frame that the window holds.
