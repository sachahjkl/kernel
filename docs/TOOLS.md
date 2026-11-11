# Developer tools

Status: asked by the owner on 2026-11-10 (`HANDOFF.md`, items 93 to 95: "tools that show memory and execution"). The first tool, `inspect`, is implemented on 2026-11-11. The owner has not reviewed the choices below.

A developer tool (`GLOSSARY.md`) shows how the system runs. It reads reports of the kernel with a grant, and it changes nothing. Property 20 sets the limit: a tool inspects a program only with a handle that has the right to inspect.

## What each tool reads

| Tool | Grant | Reports |
|---|---|---|
| `monitor` | machine, Inspect | `System_Report`, `Program_Report` of each slot. It serves `programs()`, `counts()`, `count()` and `served()` |
| `pages` | machine, Inspect | `Mapping_Report` of its own page table and of the kernel half |
| `processors` | machine, Inspect | `Processor_Report` of each processor |
| `locks` | machine, Inspect | `System_Report.locks` |
| `scheduler` | machine, Inspect and Schedule | `Processor_Report`, `System_Report.strategy` |
| `manual` | machine, Inspect; boot image; replacement table | the flat tables of the modules, `Module_Report` of each slot |
| `log` | the log records, Read | `op.Log_Record`. It serves `records(after)` |
| `inspect` | machine, Inspect; boot image | `Program_Report`, `Module_Report`, and the four reports below, of the program that the person chooses. It serves `mappings()`, `threads()` and `modules()` |

## The program `inspect`

One window for one program that the person chooses in a list. It shows:

1. **The address space** (`Inspect_Kind.Program_Mappings`, `op.Program_Mapping_Report`): each mapping of the program, with its address, its pages, the first page of its memory object, the pages that have a frame (from the page table: the kernel does not give a frame for the report), the size and the serial of the memory object, and flags: Write, Execute, Uncached, Device, Contiguous, Shared (another mapping or handle names the object), Thread_Area. The window draws one band scaled by address. A gap between two mappings is folded: it has a fixed width and lines at an angle (`DESIGN.md`, section 2: lines at an angle are a part with no measure on the scale). The kind of a mapping comes from these facts and from the module records: module code, module constants, module data, thread area, device, shared memory, memory of the program. The kernel does not know a stack: it is memory of the program.
2. **The modules** (`Module_Report`): name (from the boot image), hash, base and size. Each address in the window is `module + offset` when a module record holds it, as the stack trace of step 42 names a frame.
3. **The threads** (`Inspect_Kind.Threads`, `op.Thread_Table_Report`): the thread area, the state, the processor that runs it and its home queue, the weight and the request, the virtual time, the virtual deadline and the lag of the strategy, the processor time, the words of a word wait and its deadline. The kernel reads the fields of the scheduler with no run lock: each field is whole, two fields can come from two instants.
4. **The stop report** of a program that stopped on a fault (`Inspect_Kind.Stop`): the vector, the address, and each frame as `module + offset, near export`.
5. **Live**: a sample each 250 ms. A value that changed since the sample before is drawn in the color of the boot program for one sample. Space freezes the sample. The window shows the time of one sample and its kernel entries.
6. **A hex view** of the memory of `inspect` itself (the code of its export `entry`, and four pages of a memory object of which two were written): 16 bytes in each row, the address as `module + offset`, the ASCII at the right, the boundary of each page marked. A page with no frame is shown as such, and the tool does not read it: it asks `Inspect_Kind.Pages` (`op.Page_Report`) which pages have a frame, so its read gives no frame to a page.

## What `inspect` does not read: the bytes of another program

The reports give counts, places, states and the stack trace, never a byte of the memory of a program. To read the bytes of another program is a stronger right than Inspect: a tool with it reads the secrets of each program (P20, line 2: "Debug access is a handle to one program. The person grants it"). This step does not add that right: the hex view shows the memory of `inspect` itself. The right, when it comes, is a right of the program handle (one program, not the machine), that the root service gives to a tool on the request of the person, visible in `grants()` and revocable.

## The cost

A sample makes one kernel entry for each report: the program reports of the list (one for each slot), and the mappings, the modules, the threads and the stop report of the chosen program. The kernel time of the mappings report grows with the mapped pages of the program: it reads one entry of the page table for each page, to count the pages with a frame. The window and the log give the measured time and entries of one sample.
