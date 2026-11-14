# The access to a GPU for acceleration

Programs of the system see one graphics interface, and the system writes its implementation from nothing: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One graphics interface: WebGPU with WGSL". This file records how that interface reaches a real GPU, and which forms were refused. The access to a GPU is the aim of the work on guests (`docs/DECISIONS.md`, D-214). Nothing of it is built.

The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Driver domain".

## The constraints

- No vendor code in the kernel. The code of a device is a program: a device service.
- A GPU writes memory by direct memory access from the command buffers that programs give. So a real GPU needs the IOMMU first.
- The project does not port an existing implementation of the graphics interface.
- No support for hardware that nobody on the project owns: one GPU, named, with an opt-in test.
- The compositor owns the display. A guest must not draw on a screen that the compositor does not own: it can draw a false system dialog there.

## The chosen form: a driver domain, with one serialization

A driver domain is a small Linux guest that owns the GPU through the IOMMU. It runs the Linux driver and the open user-space driver with no change, and serves the GPU to the system.

The library of the system emits Vulkan commands in one serialization, the one that the virtual GPU of QEMU carries (Venus). The same encoder then serves two transports:

- under QEMU, the virtio GPU device carries the commands;
- on real hardware, a ring between the system and the driver domain carries them.

Why this works in the reversed direction: the serialization is not a transport. The renderer that reads it also takes it over a socket with no guest at all, so it runs over any byte channel. In the usual use the renderer is in the host and the client in the guest. Here the programs of the system are the clients and the guest is the renderer. This direction is the safer one: the renderer sees only the memory that the system granted to the guest.

What the system writes: the graphics interface and its back end in the shape of Vulkan, the encoder, a path from the shader language to the intermediate form of Vulkan, a ring service, and the program that runs the guest. The encoder runs in each client and is not trusted: a wrong stream harms only its own context.

What the kernel must provide is already in the order of the work: the IOMMU with interrupt remapping, guest support, the assignment of a device to a guest, a reset of the device, and shared memory of hundreds of megabytes between the guest and a client.

## The refused forms

| Form | Why refused, or when |
|---|---|
| A Windows driver loaded outside Windows | It needs an NT kernel around it. See [foreign_systems.md](foreign_systems.md) |
| The whole GPU given to one guest | The guest gets native speed, and native programs never use the GPU. It does not reach the aim. It stays as a test of the IOMMU, with the display of the guest inside a surface |
| A device service for the GPU, written for the system | It removes the guest, but it is one device service for each vendor. The open kernel modules of one vendor are about 2.2 million lines; the smallest known form is a multiplexer for one family of integrated GPUs. Only for a fixed machine that must run with no guest |
| The kernel interface of one vendor's driver carried to the client ("native context") | Faster: within a few percent of native. But each client then holds the user-space driver of that vendor, of 100 000 lines and more. Only after a measure, for one vendor |
| The older protocol of the virtual GPU, which carries OpenGL state | The wrong shape for the one graphics interface |
| A stream of the graphics interface itself sent to an implementation in the guest | It removes the Vulkan back end from the system, but it puts in the guest an implementation that the project did not write, and the virtual GPU of QEMU does not carry it. One mechanism on both transports is preferred |
| An existing implementation of the graphics interface, ported | The property forbids it |

## The numbers behind the choice

- The whole GPU given to one guest: 98 to 100 % of native.
- The chosen serialization: 45 to 77 % of native on one discrete GPU in the published measures, and "close to native" in other reports. The limit is the synchronization between the two sides.
- The native context: within a few percent.

The chosen form is the most modular one: any GPU with a Linux Vulkan driver works with no change of the system. The measured cost is the price of that. The fraction of native speed that is enough is fixed before the measure; a native context for one vendor is added only when the measure is below it.

## The order

1. The graphics interface in software. It fixes the interface that each later step keeps.
2. The service of the virtual GPU under QEMU, in 2D, then with the serialization. It needs one new thing of the kernel: a device mapping with the cache type that the device gives. It brings the encoder and the back end, which the next steps reuse with no change.
3. The IOMMU, then guest support.
4. The driver domain over a ring, on one GPU, as an opt-in test.
5. The measure against the same GPU under Linux with the same program.

## The subtle points

- **The compositor keeps the display.** The first form renders only: the compositor keeps the framebuffer of the firmware or the scanout of the virtual GPU, and receives rendered surfaces. The display of the guest comes later.
- **Compute needs no second interface.** The one graphics interface has compute pipelines. The vendor compute stacks exist only with the full driver of the vendor: inside a guest that owns the GPU, not for native programs.
- **A buffer with no copy.** The memory of the guest is made of memory objects of the system. A buffer that the guest allocates can be mapped into a client with no copy, when the guest reports its pages. That needs a small helper in the guest that does not exist. The first version can copy.
- **The driver domain is trusted for the content of the GPU.** It can read and change what each client renders. The rest of the system does not trust it.
- **The image of the driver domain is a resource by hash**, not a disk that changes.

## Not verified

- Whether a software Vulkan driver on the test host is enough for the serialization. If not, the test of the virtual GPU is opt-in.
- The size of an encoder for only the commands that the back end uses.
- Which machine and which GPU: the system must boot on it directly, the GPU must be alone in its IOMMU group, and it must reset.
