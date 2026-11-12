type: Changed

**The kernel runs its small instructions in place**: the ports, the model-specific registers, the control registers, `invlpg`, the read of the record of the processor and the copy of `user_copy` are instruction templates of Odin, which the compiler puts in the code of each caller with no call and no return; the code that owns the stack or the frame stays in the assembler file.
