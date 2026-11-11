type: Added

**Programs can use AVX and AVX-512**: the kernel saves the extended state of each thread with `xsaveopt` (x87, SSE, AVX, and AVX-512 when the processor has it; one save writes at most 832 bytes with AVX and 2688 with AVX-512, and each thread entry of the kernel holds an area of 2688 bytes), sets `CR4` and `XCR0` itself on each processor, and logs what it saves at boot. A processor without `xsave` keeps the save with `fxsave`. A program reads what it can use with `support/instruction_sets`, and the program `extended_state` shows that each register of each thread is kept.
