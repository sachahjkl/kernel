# Next-Gen Kernel

A new kernel and operating system, written in Odin. The project is in its design stage.

## Documents

| File | Content |
|---|---|
| `docs/PROPERTIES.md` | The properties that the system is built on |
| `docs/ARCHITECTURE.md` | The key systems and how they connect |
| `docs/MODULE_CONTRACT.md` | Proposal for the module format, the loader and the call form |
| `docs/GLOSSARY.md` | The terms of the project. One term per concept |
| `docs/HANDOFF.md` | Current state, rules of the owner, next steps |
| `docs/research/` | Research notes with sources, and video transcripts |

## Code

| Folder | Content |
|---|---|
| `boot/` | The boot program: a UEFI program |
| `tools/kerneltool/` | The kernel tool: all the automation of the project |

## Use

The Nix flake supplies the compiler, the linker, QEMU and the UEFI firmware.

```
nix develop
mkdir -p build
odin run tools/kerneltool -out:build/kerneltool -- help
```

| Command | Action |
|---|---|
| `build` | Build the boot program |
| `run` | Build, then start the machine under QEMU with the console on the terminal |
| `test` | Build, start the machine under QEMU, and wait for the mark of the boot program |
| `check` | Check the tool with `-vet`, then `test` |

`nix flake check` runs the formatting hooks and the boot test.
