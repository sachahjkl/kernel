# Foreign systems: programs of Linux and of NT

The system implements no foreign interface. A foreign system runs whole inside a guest that holds only its grants (`docs/DECISIONS.md`, D-214). This file records the comparison that led to that rule, and the forms that were refused. Nothing of it is built.

The rule is in [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Objective". The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Guest".

## The problem

The request was a layer for Linux programs, a layer for NT programs, and the access to a GPU (see [gpu_access.md](gpu_access.md)). The objective of the system said "no compatibility goal". The two could not both stand.

A layer for Linux presents `fork`, signals, a tree of files that all programs see, `/proc`, `ioctl`, `argv`, standard streams and user identifiers. A layer for NT adds a registry. The properties forbid each of these as a concept of the system.

## The scoping rule

The contradiction ends with one rule: foreign semantics exist only inside one foreign instance. The properties hold at the border of the instance and between instances.

- One instance for each launch. An instance holds only its grants.
- No native program sees a foreign interface. No native contract gets a foreign concept.
- Inside the instance the holes reopen: a child inherits, a global name exists, an install script runs with full access. Between two instances, and between an instance and the system, they stay closed.
- A foreign binary or a guest image is data in a store. It is not in the system description, and it runs only in a sandbox.
- Code of 32 bits runs only inside a guest. No contract of the system gets a form of 32 bits.

One reading of an older rule had to be corrected first. The rule "no backward compatibility" speaks of the older formats of the system itself. It does not forbid a foreign system in a guest.

## The forms for Linux

| Form | What it is | What the kernel needs that it does not have |
|---|---|---|
| A library in the same program | The layer is a module in the program. It loads one binary and serves its system calls with ring commands | The delivery of a foreign system call as a record; faults of every kind as records; a base register for each thread; a copy-on-write clone of a memory object; storage at the size of a tree of files |
| A layer in a separate program | The guest program holds no handle; the layer holds Control on it and the grants | The same, plus the control of the threads of another program and a pager for another program |
| A Linux kernel in a guest | A real Linux kernel, with its own programs, on the processor | Guest support: a second form of address space that the kernel builds from memory objects, virtual processors that run as threads, exits as records of a ring |

### The chosen form: a guest

- It needs no concept of the kernel that is specific to Linux. It needs guest support, and guest support also serves NT and the GPU.
- The two other forms write again about 200 system calls: tens of thousands of lines of layer code, and the upkeep of an interface that grows with each release of Linux.
- The size of guest support is known from a small hypervisor of the literature: a few thousand lines in the kernel, and the rest in the program that runs the guest.

### The refused form: a layer for one binary

A layer for one binary gives Linux binaries the place of first-class programs with typed grants. It is not planned. It is the only form that needs the foreign system call as a record, and binary rewriting does not replace that: the usual technique puts a trampoline at address 0, and this system cannot map address 0.

## The forms for NT

- **Wine as a Linux program, inside the Linux guest: chosen.** It needs no NT code in the system, so it adds nothing to the trusted code or to the interface.
- **A native NT layer: refused.** The system must write the side of Wine that meets the host: the system call dispatcher, the window layer over surfaces and input, a service in the place of the server of Wine, the registry. It is the largest work of the three.
- **Loading a Windows driver: refused.** A Windows graphics driver needs an NT kernel around it: an executive, a hardware layer, the device manager and the graphics kernel. One free NT system has a graphics kernel of about 128 000 lines alone. Display output from a vendor driver outside Windows was shown. No source shows 3D acceleration from one.
- **Windows, or a free NT system, as a whole guest**: the answer for a program that Wine does not run. It needs no mechanism past the guest and a firmware for it.

## One abstraction for three requests

A second address space is a page table that the kernel builds from memory objects, read by a guest processor (nested paging) or by a device (the IOMMU). One structure of the kernel then serves a guest and a device. The mapping operation that exists maps memory objects into it, and the exits of a guest arrive as records of a ring, as the faults do. This is the reason for the bound of three to five new kernel operations, each with its recorded reason.

## The subtle points

- **The network of a guest is not a raw frame grant.** A raw grant gives the guest the whole network identity of the machine. The program that runs the guest translates the TCP and the UDP of the guest to the grants of the instance.
- **The disk of a guest changes inside the guest.** It is data of the program that runs the guest, not a list of modules. The identity by hash stops at the image.
- **A guest that draws** gets a surface: its scanout becomes a surface of the compositor. No native program sees a foreign graphics interface.
- **The files that cross** between a guest and the system are the slow part of this form in other systems. They cross as granted objects.
- **The test host is an AMD processor.** Nested virtualization gives the test machine the AMD form of guest support, so that form comes first.
- **Three primitives are gaps of the native system too**: faults of every kind as records, the control of a thread with its registers, and storage at the size of a tree of files. They were built first, because each is useful with no foreign system.

## The order

The primitives, then the IOMMU (a device reaches only the memory that its service was granted; the properties already require it on real hardware), then guest support, then Linux in a guest, then Wine in that guest, then the GPU. The order of the work is in `docs/FIRST_MILESTONE.md`.

## State

Decided, with no code. The three primitives are built. The IOMMU is the next step.
