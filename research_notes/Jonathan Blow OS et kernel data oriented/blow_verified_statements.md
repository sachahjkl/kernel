# Jonathan Blow on operating systems: statements read at the source

Date: 2026-11-09.

This file replaces the secondary evidence in `blow_os_kernel.md` for the design items.
Each statement below was read in the transcript of the video.
The transcripts are in `transcripts/`. They are YouTube automatic captions.
Quotes are cleaned of filler words. Check the video before you publish a quote as exact.

Reference format: `[video id mm:ss]`. The video list with dates is in `transcripts/README.md`.

Short names for the main videos:

| Short name | Video id | Title | Uploaded |
|---|---|---|---|
| OS-2020 | `k0uE_chSnV8` | how an operating system should work | 2020-08-01 |
| DRV-2021 | `xXSIs4aTqhI` | on Drivers | 2021-01-11 |
| ARCH-2026 | `q3dCQLxrFYo` | on operating system architecture | 2026-01-26 |
| MAKE-2026 | `bQnB6eI8DU4` | on making an operating system | 2026-04-15 (stream of 2026-04-11) |
| STAG-2026 | `cKyrT8OVbDo` | Why Operating Systems Stagnated | 2026-10-04 |
| PROJ-2026 | `YstsL4oqjYw` | on modern OS projects | 2026-04-05 |
| UNIX-2026 | `uF_3aRpyzD8` | why Unix is the wrong base | 2026-10-19 |
| SOCK-2026 | `yKfaU4Ke6mg` | why the socket API is the wrong abstraction | 2026-06-18 |
| LINBIN-2026 | `6zQzNpjgbAY` | Why Linux Binaries Are Hard to Distribute | 2026-10-17 |
| MEM-2026 | `srX5vUTTZCA` | Why Memory Now Matters More Than CPU Speed | 2026-11-09 |

## 1. Objective of a new operating system

- The objective is not adoption. The objective is "a massively simplified technical stack that still has all the functionality that we have today". [MAKE-2026 01:01]
- The point is "to prove out the concept that you don't need 99% of the code that's on your computer right now". [MAKE-2026 02:01]
- "You can at least make a core that's clean and beautiful and reusable and modern and not Unix." [PROJ-2026 00:00]
- The correct operating system "doesn't do most of what Linux does". [OS-2020 06:35]
- He prefers "much less software, but that was actually good". [OS-2020 06:35]
- The operating system exists to make good software easier to write. Today a game must avoid most operating system services to be reliable. [`-oDxMLNvikY` 04:02]
- "We used to have a name for a system that would reliably rerun the same program over time. It was called the operating system." Containers exist because the operating system stopped doing that. [STAG-2026 03:04]

## 2. Size of the kernel and of its interface

- "The operating system itself should be small. Most things should happen in user space." [OS-2020 01:01]
- "The core interface that the operating system implements should be very simple. It should be as simple as possible. It shouldn't be a big spec." [DRV-2021 04:03]
- 400 processes at start is the problem, not the amount of shared memory. [OS-2020 00:31, 10:43]
- 4,500 executables on a desktop distribution is not a good idea. [OS-2020 09:39]

## 3. The base interface: non-blocking command buffers

This item was absent from the earlier notes. It is the most concrete interface statement.

- "At the bottom-most level, everything should be a non-blocking command buffer interface where you fill out command buffers and you submit them." [ARCH-2026 04:04]
- A blocking interface such as `fread` is a layer that a program can choose to put on top. [ARCH-2026 04:04]
- The base interface "uses shared memory to transport data instead of some model where you copy data into the kernel and back out of the kernel". [ARCH-2026 04:04]

## 4. "Everything is a file" is rejected

- "A modern operating system does not do the Unix philosophy at all. It doesn't use pipes." [ARCH-2026 02:03]
- A file, a console stream, a network connection and a device status must not share one interface. The shared interface "creates a huge amount of internal complexity". [ARCH-2026 03:03]
- The code that reads a local file and the code that reads a game server connection are different in any case. "Acknowledge that those things are different and just treat them in the simplest possible way." [ARCH-2026 03:03, 04:04]
- The socket is "a Unix concept for tying together a bunch of different things that are not related". The wanted network interface is: connect, write and read messages, disconnect. [SOCK-2026 00:00, 01:01]
- He calls Plan 9 an attempt that "was all about serializing and deserializing, so I don't love that". [STAG-2026 07:08]

## 5. Kernel off the data path, and devices

- "If you're going to talk to the network card, that should not go through the operating system at all. Period." [OS-2020 01:01]
- Access control uses "some kind of security token handoff". [OS-2020 01:01]
- The kernel validates the permission one time. After the key exchange, "you should just be able to send messages to the device without the kernel being in the middle". The key can be a 64-bit hash. [ARCH-2026 05:04]
- "You should not allow drivers in the way that we do today." [OS-2020 05:34]
- Hardware abstraction is a standardized interface: "I want a DMA to the hardware and there's a particular protocol over what that packet format is." [DRV-2021 00:30]
- Each user process implements its own TCP stack, as each process implements `printf`. [DRV-2021 00:00]
- Hardware that does not follow the standard protocol can have "a user space program that marshals communication". He does not recommend it. [DRV-2021 03:01]
- Drivers exist "because people think it's cheaper to do stuff in software than in firmware or hardware". [DRV-2021 01:00]
- Sound output is a solved problem and must be a small interface. [DRV-2021 02:00]

## 6. Fixed hardware first

- "You just pick some fixed hardware to start with", because drivers for all hardware "drown" the project. [MAKE-2026 01:01]
- "It would be like a very specific CPU, a very specific GPU." [MAKE-2026 02:01]
- A common instruction set for CPU and GPU does not help. None of his design depends on the instruction set. [ARCH-2026 10:06]
- Game console graphics interfaces are better than the desktop ones. [`695CiqtPEVE` 02:00] PlayStation already gives a better device interface. [MAKE-2026 02:01]

## 7. Sandbox and storage

- "Programs should be sandboxed from each other by default. It should be very heavily sandboxed where most programs cannot really do that much." [OS-2020 01:31]
- "By default, a program can't just look at the file system. That's not even a thing." [OS-2020 02:01]
- The sandbox "can't be an additional thing. It has to be the basics of how the operating system works". This answers a viewer who cites OpenBSD `unveil`. [OS-2020 03:02]
- Each program has "their own sandboxed file space". A program can also read some common configuration files and possibly a user folder. [ARCH-2026 01:01]
- He says that the file sandbox is not the most important of his ideas. [ARCH-2026 00:01, 01:01]
- The desktop part is not designed: "I haven't thought about that part enough." [OS-2020 01:31]

## 8. Communication between processes

- "Processes communicate by direct memory mapping usually." Two processes map a mutual buffer and copy data structures into it. "That's your basic communication mechanism." [OS-2020 02:01, 02:31]
- Shared data structures across a boundary remove serialization, parsing and parse errors. He opposes Language Server Protocol for this reason. [STAG-2026 02:04]

## 9. Code units: libraries, programs, installs

- "You would make all code position-independent. You would just have one library type, which could either be linked statically or dynamically. That's just a thing that you decide when you link it." [OS-2020 03:33, 04:04]
- Static linking is the default, "but in such a way that within the executable file, you still have the information of what library that came from". This keeps security patches possible. [OS-2020 04:04, 04:34]
- Position-independent code has no performance cost that matters, and address space layout randomization makes all code dynamic in any case. [ARCH-2026 06:04]
- A command-line program and a library must be the same thing. The `grep` program and a `grep` library are one unit. [OS-2020 05:04] [ARCH-2026 07:04]
- "Why, if you have a library, can you not just run the library and get a test of the code?" [ARCH-2026 07:04]
- "There's no installs. You just run a program." A program that can reach only its own space has nothing to do during an install. [OS-2020 03:02, 03:33]
- No registry. [OS-2020 09:09]
- No `PATH` string. A possible replacement is a user folder with links to the places that contain executables. He is not sure that a path is necessary. [OS-2020 08:08, 08:39]
- Batch scripting is usually not a good idea: "it usually turns into programs. So, just write programs." [OS-2020 08:08]
- "The binary is the actual specification of your program." A system must let an author distribute a binary. [LINBIN-2026 02:03]
- Linux fails here: the C library, the window system and the desktop toolkit are all unknown on the target machine. [`U3i37f6wtWk` 01:00, 04:04]

## 10. Graphics

- "To start with, I would just not support graphics accelerators." [OS-2020 07:07]
- A later option is a very thin driver, "just enough to let you run a compute shader that writes to GPU memory". [OS-2020 07:37]
- X11 sends drawing commands over a network. The approach that won is to draw locally, then sample the screen and send it. [`pN7DUcJZLHo` 01:00]

## 11. Isolation inside a program (unsolved)

- A thread or memory context with limited write permission is not possible today without a separate process. Then the communication with that process is awkward. [STAG-2026 00:00]
- A crashed plugin can leave shared state broken, for example a lock-free counter that it did not decrement. [STAG-2026 03:04]
- "What should I do if I want a fully robust untrusted plugin running on my machine with my code?" There is no good answer in current systems. [STAG-2026 08:08]
- He wants a standard sandboxed virtual machine: "an abstracted version of machine instructions that just operates on memory", present in every operating system. [STAG-2026 09:10]

## 12. Memory as the main cost

- A cache miss costs 400 to 500 cycles. Memory layout is now the main performance factor. [MEM-2026 02:00]
- The distance between cores and caches on the chip will matter more. [MEM-2026 04:01]
- A global heap is a bad design. A real program needs more than one heap. [MEM-2026 01:00, 02:00]
- The Jai runtime support is about 500 lines and does almost nothing at start. [MEM-2026 09:04, 11:06]
- Load a complete file in one operation, in binary format, then read it in memory. [`4u4HYyavfoU` 00:00]

## 13. His own plans

- 2020: he wants to "try to get something to boot in a VM" for a weekend. [OS-2020 11:13, 13:17]
- 2026: "The chance is very close to zero." He has no money and no time, and an operating system needs "a team of at least a few really good people". [MAKE-2026 02:01, 03:03]
- He says that his thinking is "nowhere near" the work necessary for a real design. [MAKE-2026 00:00]

## Corrections to `blow_os_kernel.md`

- All items marked [S] from the two Swifton clips are confirmed, except the items below.
- The word "microkernel" does not occur in the transcripts that were read.
- "Too many processes" in OS-2020 comes from a Hacker News discussion about shared libraries. The numbers 400 and 4,500 are quoted from that discussion.
- OS-2020 was uploaded on 2020-08-01 and DRV-2021 on 2021-01-11. The stream dates are not known.
- Not found in any transcript: scheduler design, executable file format, capability model details, file system internals.
