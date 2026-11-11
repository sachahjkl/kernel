type: Security

**The compositor takes only a surface that the program gave**: a program could name, in its command to create a surface, a handle that the compositor holds for another program. The compositor then showed the memory of the other program and closed its handle. The compositor now asks the kernel to prove that the handle came through the ring of the program, and closes each handle that it was given, also when it refuses the command.
