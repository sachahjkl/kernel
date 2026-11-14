# Roadmap

This file holds the planned work of modus. **Now** is the work that is in progress. **Next** is the work that is decided and comes after. **Later** is the work that is wanted and has no order. An entry leaves this file in the commit that ends its work.

## Now

- **Every program that draws imports the drawing module.** The programs that draw a picture, the terminal and the compositor use the drawing module, as 23 programs do today. The code of the drawing is then loaded one time, and one correction reaches every program. [Design](src/md/api/library_modules.md)
- **One source library for a program of a third party.** Everything that becomes the system is now in the folder `src`. What is left: the code that the programs share becomes one source library, `modus`, so that a developer names the system by one name in each import and gives the compiler one folder. [Design](src/md/infrastructure/repository_layout.md)

## Next

- **A share of the processor for each program.** The program `scheduler` sets the weight of each thread, so that a program with many threads takes no more of the processor than a program with one. A measure run prints the share that each program gets. [Design](src/md/features/scheduling_policy.md)
- **The icons of the site from the generator of the mark.** The generator of the pictures of the mark also writes the icon file and the vector icon of the site, and the icons are rows of the one table of the files of the mark. A developer then finds every file of the mark in one table. [Design](src/md/features/mark_pictures.md)
- **A window for the debugger.** The debugger gets a window over the exports that the console uses today: the threads, the stack, the variables and the source lines. A step over a call stops after the call returns, not inside it.
- **The palette sets the scheduling strategy.** The scheduling strategy is an entry of the palette, as each setting is. A click in a field of the palette puts the input there. [Design](src/md/features/palette.md)
- **Kind icons in the completion list of the console.** Each row of the completion list shows the kind icon of its name, as each row of the palette does. A reader tells a command from a module or a variable before reading the name.
- **Programs from a disk.** The root service loads a program from a tree of the storage service, by its hash, and not only from the boot image. A developer adds a program to a machine with no new boot image.
- **A key sealed by the TPM, and a recovery key.** The TPM releases the key of a principal only to the system whose measure it holds, so an older or a changed system opens no store. A principal who loses the passphrase opens the stores again with a recovery key.
- **A send with no copy in the network service.** A frame to send holds its headers in the memory of the network service and its data in the memory of the program, which the device reads. The network service then reads no byte of the data that a program sends. [Design](src/md/infrastructure/network_data_path.md)
- **The IOMMU.** A device reaches only the memory that its service was granted. A device service that has a fault then damages no other program.
- **A guest.** A program runs another system in a guest, with the virtualization support of the processor. The first guest writes to a port, and the write arrives as a record in the program that runs it. [Design](src/md/features/foreign_systems.md)
- **A window never shows a picture that is being drawn.** Each program draws its next picture apart, and the compositor shows it only when it is complete, as `terminal`, `manual` and `heron` do today. A window then shows no frame that mixes two pictures. [Design](src/md/features/heron_program.md)
- **The option for the debug information in the compiler of the Odin project.** The kind of debug information that adds no instruction is offered to the Odin project. A developer then builds the modules of the system with the compiler of that project, with no fork. [Design](src/md/infrastructure/debug_information_and_code.md)
- **No text over a text, and no cut text, in five windows.** The two pages of the program `manual` that show a module and its tables draw each text in its own box, the window of `notes` draws its note whole, and the stack trace of a stop report wraps in the windows of `errors` and of `inspect`. A reader then reads every line of these windows.

## Later

- **Linux in a guest.** A principal runs Linux, and the programs of Linux, in a guest beside the programs of the system. [Design](src/md/features/foreign_systems.md)
- **Programs of NT.** A program of NT runs through Wine inside the Linux guest, with no work of its own in the system. [Design](src/md/features/foreign_systems.md)
- **Acceleration by a GPU.** The one graphics interface of the system runs in software first, then on the virtual GPU of the test machine, then on a real GPU through a driver domain. The GPU then draws the windows and the pictures, and not the processor. [Design](src/md/features/gpu_access.md)
- **A receive queue for each endpoint.** On a device that has several queues, the frames of an endpoint arrive in the memory of its program. The network service then leaves the path of the data that a program receives. [Design](src/md/infrastructure/network_data_path.md)
- **The stores of a principal are encrypted.** The storage service encrypts the stores of a principal with the key of that principal. A reader of the disk who has no key reads no object.
- **Several principals, and one identity on several machines.** More than one named principal uses a machine, each with its own session and its own stores. A principal has the same identity on another machine, and a grant can be signed for a principal of another machine.
- **A grant for the key of a client of `remote`.** The principal gives the public key of a client to the program `remote` as a grant that can be revoked. A call from another machine then acts only for a principal who allowed that client.
- **Processor counters for a program.** A program reads the counters of the processor for its own code, such as the cache misses. A developer then measures the cost of a data layout, and not only its time.
- **A pager for another program.** A program answers the page faults of another program and supplies its pages.
- **Every window uses the interface package.** The windows of the programs that still draw by themselves are built from the elements of the interface package. Each window then has the same look, the same keys and the same damage rules.
- **The pointer on the scroll bars of the palette and of a completion list.** The scroll bar of the palette and of the completion list of the console moves its list under the pointer, as the scroll bar of a terminal does. The wheel of the pointing device moves the view under the pointer. [Design](src/md/features/scroll_bar.md)
- **Keyboard layouts.** The input service reads a layout other than the US layout. A principal chooses the layout as a setting.
- **The program `manual` opens the links of a page.** A link to a term, a guide or a declaration in the documentation of a module opens its page in the program `manual`. Today only a link to a module or to an export opens.
- **The console colors each field by its value kind.** The description of a field of a record states its value kind, so the console draws a size, a time or a handle in a field in its color. Today a field has the color of its type only.
- **The history of a store.** A version is a state of a whole store, and the versions of each object are found in it. A principal then steps a store back as one thing, not object by object.
- **The same object is kept one time.** The storage service finds an object by its hash, so an object that two entries name takes its blocks once.
- **A faster switch between threads.** A processor that takes again the thread whose extended state its registers hold skips the restore of that state. A measure gives the gain.
- **The history of each measure, release by release.** The measure record keeps the numbers of each release, and the site draws a chart of each measure over the releases. A reader then sees whether a change made the system faster or slower.
- **Measures on a quiet host.** The numbers of the windows, of the calls, of the vector forms and of QUIC are measured on a host with no other load. A reader then compares them from one release to the next.
- **LLVM 22.** The build uses LLVM 22, with a measure of the speed of the code before and after.
- **Checks for three rules that hold by reading.** The tool compares the count of kernel operations with the number that the properties state, checks that no shared package calls an allocator, and runs a block device that drops a write. Each check turns a rule that a reader must trust into a test.
- **The QUIC library follows two more rules to the letter.** One answer goes out for each path challenge, and a misplaced extension fails with the alert that the standard names. No peer is harmed today, so the work waits.
- **The guides agree with the code on three points.** The guides state the object kinds, the ring of each thread to the kernel and the form of a handle as the code has them.
