# First milestone

Status: implemented on 2026-11-10. `nix flake check` passes.

This document describes what the code does now.
It lists the choices that were made during the implementation and that the owner has not reviewed.
It lists the gaps between the code and the documents.
`GLOSSARY.md` defines the terms.

## Evidence

- `kerneltool test` starts the machine under QEMU and acts as the person through the QEMU monitor: keys, pointer moves, clicks.
- Each step of the scenario waits for a text in the log of the kernel. A step that does not see its text in 20 seconds fails the test.
- The scenario is a table in `tools/kerneltool/machine.odin`.
- The test saves three pictures of the screen. `kerneltool screenshots` copies them to `docs/screenshots/`.
- `nix flake check` runs the same test in the Nix sandbox.

The scenario does these actions:

1. Wait for the kernel, the root service, the input service, the compositor and the console.
2. Type expressions and commands in the console: `1 + 2 * 3`, a variable, `length`, `hash("abc")`, a type error, `modules()`.
3. Start `life` from the console with `start("life")`. Drag its window.
4. Start `monitor`, `paint` and `plasma` from the bar. Choose colors and draw lines in `paint`.
5. Start `fault`. The kernel stops it on a page fault. The other programs continue.
6. Close `plasma` with its close button. Stop `paint` with `stop("paint")`.
7. Call `programs()` and `memory()`.
8. Call `gcd(84, 36)`: the console has no such command. Call `load("math")`, then `gcd(84, 36) + power(2, 10)`: the result is 1036.
9. Call `help()`, then `shutdown()`. The machine stops with code 0.

## The path from power to desktop

1. The firmware starts the boot program (`boot/`), a PE file.
2. The boot program reads the kernel module and the boot image from the boot volume. It loads the kernel with the code of `module/`. It collects the memory map and the framebuffer in a `Boot_Info` record, leaves the firmware, and jumps to the kernel.
3. The kernel (`kernel/`) takes the memory, builds its tables, sets the processor tables, the interrupt controller and the timer.
4. The kernel loads one program from the boot image: the root service. It gives it three handles: the machine, the framebuffer, the boot image.
5. The root service (`programs/root`) loads the other programs in user space with `system.program_start`. It starts the input service, the compositor and the console.
6. From this point, the kernel only executes kernel operations, schedules, and turns interrupts into wakes.

## Kernel

| Subject | Now |
|---|---|
| Entry | One entry point: the `syscall` instruction. `rdi` is 0, a deadline in milliseconds, or `WAIT_FOREVER`. `rax` returns the time |
| Kernel operations | 16 command kinds in the kernel ring. `kernel/operation/operation.odin` is the full list |
| Objects | Memory, Program, Interrupt, Ports, Machine |
| Tables | Flat and fixed: 2048 memory objects, 64 programs, 128 handles and 128 mappings per program |
| Memory | A memory object is a run of contiguous page frames with a reference count. `Memory_Map` maps it in a program |
| Wait and wake | `Wake(memory)` wakes the other programs that map this memory. Each program has a wake-pending flag, so no wake is lost |
| Scheduler | One processor. Round-robin. A time slice is 10 ms. The timer runs at 1000 Hz. Idle is `hlt` |
| Devices | A Ports object opens a port range in the port bitmap of the program. An Interrupt object counts interrupts and wakes its owner |
| Faults | A fault in a program stops this program with a code. The root service sees the state and reclaims the handles |
| Inspect | The Machine handle gives `System_Report` and `Program_Report` records, and stops the machine |

The kernel contains no code for a device, except the timer, the interrupt controller and the serial port of its log.

## User space

| Part | Role |
|---|---|
| `system/` | Wrappers of the kernel operations, text formatting, the loader, the grant roles |
| `ring/` | Command queue and completion queue in one memory object |
| `display/` | The protocol of the compositor (create a surface, present, key and pointer events) and the client code |
| `graphics/` | Canvas, fill, line, copy, text. The font is Spleen 8x16 at its native size |
| `programs/root` | Root service: starts programs, grants by name, answers Start and Stop, reclaims stopped programs |
| `programs/input` | Input service: PS/2 keyboard and mouse through granted ports and interrupts |
| `programs/compositor` | Compositor and desktop shell: bar, clock, windows, focus, drag, close, pointer |
| `programs/console` | Console: integers, texts, variables, arithmetic, typed commands |
| `programs/monitor` | System tool: memory, kernel entries, interrupts, pages and processor share of each program |
| `programs/plasma`, `life`, `paint` | Demos: animation, simulation, pointer and key input |
| `programs/fault` | A program that writes to an address that it does not own |

Grants by the root service:

| Program | Handles |
|---|---|
| `input` | Ports and interrupts of the keyboard and mouse; a ring to the compositor |
| `compositor` | The framebuffer; the input ring; a control ring to the root service |
| `console` | A display ring; a ring to the root service; the machine; the boot image |
| `monitor` | A display ring; the machine |
| all others | A display ring only |

A program with only a display ring can draw in its surface and read its own input events. It can do nothing else.

## Choices made during the implementation

The owner did not review these. Each one can change.

1. **Export numbers.** The kernel tool holds an ordered export list per module. The export index is the position in that list. Imports resolve by name at build time only.
2. **Entry instruction.** `syscall`, with the full register state saved per program and a return by `iretq`. The kernel is not preemptible and has one stack.
3. **Wake by memory.** `Wake` and `Handle_Give` take a memory handle to name "the other side of this ring". The kernel has no ring object: a ring is a memory object with a layout that the two programs agree on.
4. **The kernel loads the root service only.** The loader of all other programs is user-space code in `system/load.odin`. This closes open question 2 of `ARCHITECTURE.md` in the direction "minimal loader in the kernel, for one program".
5. **Fixed addresses.** A program module is at `0x40_0000`. The stack, the context and the kernel ring have fixed addresses. No random base address.
6. **The compositor is also the desktop shell.** The glossary defines them as two programs. One program holds both roles now.
7. **Grants by program name.** The root service decides the handles of a program from its name, in code. No grant record, no revoke.
8. **Commands of two origins.** The system commands (`programs`, `start`, `shutdown`...) are compiled into the console. `load("math")` loads a module of the boot image: each export becomes a command. The console reads the name, the types and the help of an export from the function table of the module, and calls the export with the call form. `load` checks the hash of the module first.
9. **Font.** Spleen 8x16, BSD 2-Clause, converted from its BDF file by `kerneltool font`.
10. **Types of the description.** `Integer` (64 bits, in a register) and `Text` (the address of a slice record, parameters only). At most 6 parameters. The kernel tool holds the description of each export in its module table; no tool checks it against the source.

## Gaps

Against the properties and the module contract:

- Handles have no rights. A program can give any of its handles onward.
- The Machine handle gives inspect and stop together.
- Property 19 is not complete: a loaded module runs in the address space of the console (direct call only, no isolated call through a ring). A command cannot give a Text. The description has no records, no handles and no grants.
- Frame pointers are not enforced. An import call goes through a stub that the linker adds.
- The test "a C program calls an Odin module" does not exist.
- One processor. One thread per program.
- No storage, no network, no document service, no principals, no TPM, no Secure Boot.

Performance:

- The compositor draws the full screen for each frame. With `plasma` open it uses about 60 % of the processor under QEMU.
- The kernel saves and restores the floating-point state on every entry.
- `display.open` repeats `Handle_Give` until the compositor maps the ring.

Input:

- The keyboard layout is US only.

## Next steps

1. Isolated call of an export through a ring; Text results; descriptions made from the source (property 19).
2. Rights on handles, and a split of the Machine handle.
3. Damage rectangles in the compositor.
4. A block device service (virtio), then the storage service.
5. Several processors.
