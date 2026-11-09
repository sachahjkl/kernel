# Next-Gen Kernel

A new kernel and operating system, written in Odin.
The system boots under QEMU to a graphical desktop with a console, a system tool and demo programs.

![The desktop: console, monitor, plasma, life and paint](docs/screenshots/desktop.png)

| | |
|---|---|
| ![The console](docs/screenshots/console.png) | ![The commands of the console](docs/screenshots/tools.png) |

`kerneltool screenshots` makes these pictures from the running machine.

## What works

- A UEFI boot program loads the kernel module and the boot image, then leaves the firmware.
- The kernel has one entry point. Each kernel operation is a command record in the kernel ring.
- Each program has its own address space and its own handle table. A program reaches only the objects of its handles.
- The root service loads all other programs in user space and grants their handles.
- The input service reads the keyboard and the mouse through granted ports and interrupts.
- The compositor owns the framebuffer. Each program draws into a surface in shared memory.
- The console is a normal program. A command is a typed function: `hash("abc")`, `start("life")`, `programs()`.
- A program that faults stops alone. The system continues.

`docs/FIRST_MILESTONE.md` gives the details, the design choices and the gaps.

## Documents

| File | Content |
|---|---|
| `docs/PROPERTIES.md` | The properties that the system is built on |
| `docs/ARCHITECTURE.md` | The key systems and how they connect |
| `docs/MODULE_CONTRACT.md` | The module format, the loader and the call form |
| `docs/FIRST_MILESTONE.md` | What the code does now, the choices made, the gaps |
| `docs/GLOSSARY.md` | The terms of the project. One term per concept |
| `docs/HANDOFF.md` | Current state, rules of the owner, next steps |
| `docs/research/` | Research notes with sources, and video transcripts |

## Code

| Folder | Content |
|---|---|
| `boot/`, `boot_info/` | The boot program (UEFI) and the record that it gives to the kernel |
| `kernel/` | The kernel. `kernel/operation/` defines the kernel operations |
| `module/`, `blake3/` | The module format, the loader code, the hash |
| `ring/` | The ring: two queues in shared memory |
| `system/` | The library of a program: kernel operations, text, loader, grants |
| `graphics/`, `display/` | Drawing with the processor; the protocol of the compositor |
| `programs/` | `root`, `input`, `compositor`, `console`, `monitor`, `plasma`, `life`, `paint`, `fault` |
| `modules/` | Test modules of the host load test |
| `tools/kerneltool/` | The kernel tool: all the automation of the project |

## Use

The Nix flake supplies the compiler, the linker, the assembler, QEMU and the UEFI firmware.

```
nix develop
mkdir -p build
odin run tools/kerneltool -out:build/kerneltool -- run
```

| Command | Action |
|---|---|
| `build` | Build the modules, the boot image and the boot program |
| `run` | Build, then start the machine under QEMU, with the log of the kernel on the terminal |
| `test` | Build, start the machine, act as the person (keys, pointer), check the log, save pictures |
| `screenshots` | `test`, then copy the pictures to `docs/screenshots/` |
| `font` | Convert the BDF file of the font to `graphics/font.odin` |
| `check` | `odin check -vet` and `odin test` of the host code, then `test` |

`nix flake check` runs the formatting hooks and `check`.

In the machine, type `help()` in the console. The buttons of the bar start programs.

## Licences

The font is Spleen 8x16 by Frederic Cambus, BSD 2-Clause. See `graphics/FONT_LICENSE`.
