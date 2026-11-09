# Proven and radical kernel design ideas: what to keep, what to avoid (catalogue for a new data-oriented kernel)

Source-confidence legend used throughout:
- **[V]** = URL surfaced or fetched and checked during this research session (Nov 2026).
- **[R]** = canonical URL and content recalled from the researcher's own knowledge; the page was NOT re-fetched in this session. The facts are standard and well known, but the report writer should treat the exact URL as "very likely correct, unverified".
- Numbers flagged "(verify)" are recalled and should be checked before being quoted.

---

## 1. Windows NT: which design ideas are regarded as good, which as regrettable? (and what is "libnt"?)

### Takeaway
NT's lasting good ideas are structural: one object manager with one handle table and one namespace for every kernel resource, an I/O model that is asynchronous and packet-based (IRP) from the bottom up with completion ports on top, and a stable user-mode DLL boundary (ntdll) that leaves the kernel free to renumber syscalls. The regrets are mostly accretion: Win32k in the kernel, Win32 path/namespace legacy, the registry, heavyweight process creation, filter-driver stacks, and personalities that never achieved full fidelity (POSIX subsystem, WSL1).

### Cited Findings

**"libnt" clarification**
- There is no widely known kernel component literally named "libnt". The most plausible referent is the **NT Native API exposed by `ntdll.dll`** (the `Nt*`/`Zw*`/`Rtl*` functions), which is the real user/kernel boundary of Windows; Win32 (`kernel32`, `user32`) is layered on top. Native applications such as `autochk` and `smss` link only against ntdll. — [Russinovich, "Inside Native Applications", Sysinternals](https://learn.microsoft.com/en-us/sysinternals/resources/inside-native-applications) [R]
- The second plausible referent is **Cosmopolitan libc's `libc/nt` package** (Justine Tunney). The directory contains per-DLL import subdirectories (`ntdll`, `kernel32`, `advapi32`, `ws2_32`, `user32`, ...), `struct`/`enum`/`typedef`/`thunk` folders, and files `ntdll.h`, `ntdllimport.S`, `ntdllimport.h`, `sysv2nt.S`, `codegen.sh`, `master.sh`, `iocp.h`. It is a hand-generated binding layer that lets one "actually portable executable" call NT/Win32 functions from System V-ABI code. The fetched page does not document the mechanism; that `sysv2nt.S` is a System V to Win64 calling-convention thunk is inferred from file names and from stub code seen in a dataset listing. — [jart/cosmopolitan `libc/nt`](https://github.com/jart/cosmopolitan/tree/master/libc/nt) [V]
- Other things someone might mean: midipix's `ntapi` (a POSIX runtime built directly on the Native API, bypassing Win32) — [midipix ntapi source](https://dev.midipix.org/runtime/ntapi/blob/main/f/src/internal/ntapi.c) [V]; the `phnt` native-API headers from System Informer — [winsiderss/phnt](https://github.com/winsiderss/phnt) [R]; Zig's standard library policy of preferring ntdll over kernel32 — [ziglang/zig issue #1840](https://github.com/ziglang/zig/issues/1840) [R, verify issue number].

**Stable DLL boundary vs stable syscall ABI**
- NT system service numbers are not a contract: NtReadFile was 0x32 on XP, 0x4B on Vista, 0x54 on Windows 7 according to a 2010 slide deck; tools resolve numbers by parsing the loaded ntdll at run time. — [Sys_Hack slides, Uni Jena](https://users.fmi.uni-jena.de/~nwk/Sys_Hack.pdf) [V]; per-build tables: [hfiref0x/SyscallTables](https://github.com/hfiref0x/SyscallTables) [V], [j00ru syscall table](https://j00ru.vexillium.org/syscalls/nt/64/) [R]
- Wine developers observe a header value for `NtGdiAlphaBlend` (4) not matching the number actually used by win32u.dll on Windows 11 (0x1075), illustrating that anything bypassing the DLL is fragile. — [wine-devel thread, 2025](https://list.winehq.org/archives/list/wine-devel@list.winehq.org/thread/RNDWRYDMZ6GVVOFXL4PZVIYLE25DEUOC) [V]
- Linux takes the opposite contract: the raw syscall ABI is the stable interface ("WE DO NOT BREAK USERSPACE") while in-kernel APIs are deliberately unstable. — [Torvalds, LKML 2012-12-23](https://lkml.org/lkml/2012/12/23/75) [R]; [stable-api-nonsense, kernel docs](https://docs.kernel.org/process/stable-api-nonsense.html) [R]
- Other systems chose the NT model later: Go 1.12 stopped making raw syscalls on macOS and calls libSystem instead; OpenBSD now pins syscalls to libc call sites; Fuchsia states that the vDSO is the only permitted way to enter the kernel. — [Go 1.12 release notes](https://go.dev/doc/go1.12#darwin) [R]; [OpenBSD pinsyscalls(2)](https://man.openbsd.org/pinsyscalls.2) [R]; [Fuchsia vDSO](https://fuchsia.dev/fuchsia-src/concepts/kernel/vdso) [R]

**Object manager, handles, namespace**
- Every kernel resource (file, process, thread, section, event, key, port, token, device) is a typed object managed by one component that provides naming, reference counting, per-process handle tables, and uniform security checks; named objects live in one hierarchical namespace (`\Device`, `\??`, `\BaseNamedObjects`). — [Windows Kernel-Mode Object Manager](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/windows-kernel-mode-object-manager) [R]
- Win32 paths are a compatibility veneer over that namespace, and the translation rules (drive letters, DOS device names, `\\?\`) are a long-running source of bugs and security holes. — [Project Zero, "The Definitive Guide on Win32 to NT Path Conversion"](https://googleprojectzero.blogspot.com/2016/02/the-definitive-guide-on-win32-to-nt.html) [R]

**Asynchronous layered I/O: IRPs and completion ports**
- All I/O is represented by an I/O Request Packet that travels down a stack of layered drivers, each with its own stack location; synchronous I/O is built on top of the asynchronous path rather than the reverse. — [I/O request packets](https://learn.microsoft.com/en-us/windows-hardware/drivers/gettingstarted/i-o-request-packets) [R]; [Handling IRPs](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/handling-irps) [R]
- I/O completion ports are a kernel queue of completions bound to a thread pool with a concurrency limit; waiting threads are released in LIFO order to keep caches warm, and the kernel wakes another thread when one blocks. This is completion-based, not readiness-based (contrast epoll). — [I/O Completion Ports](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports) [R]
- Windows later added an io_uring-style shared-ring API (IoRing) in Windows 11, modelled closely on Linux's design, which indicates that IOCP's one-syscall-per-operation cost had become the limit. — [Yarden Shafir, "IoRing vs. io_uring"](https://windows-internals.com/ioring-vs-io_uring-a-comparison-of-windows-and-linux-implementations/) [R]
- Regret: the generic filter-driver stack makes every file operation expensive. A Microsoft WSL engineer explained that NT file I/O is slow for Unix-style small-file workloads because each operation traverses the filter stack and because the object/handle-centric path API lacks a dentry-style cache. — [microsoft/WSL issue #873 comment](https://github.com/Microsoft/WSL/issues/873#issuecomment-425272829) [R]

**HAL, IRQL, DPC, APC**
- The HAL isolates the kernel and drivers from platform differences (interrupt controllers, timers, bus access). — [Windows Kernel-Mode HAL Library](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/windows-kernel-mode-hal-library) [R]
- Interrupt work is split: a short ISR queues a Deferred Procedure Call that runs later at DISPATCH_LEVEL; APCs deliver work into the context of a specific thread (the mechanism under I/O completion and under alertable waits). — [Introduction to DPC Objects](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/introduction-to-dpc-objects) [R]; [Asynchronous Procedure Calls](https://learn.microsoft.com/en-us/windows/win32/sync/asynchronous-procedure-calls) [R]; [Managing Hardware Priorities (IRQL)](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/managing-hardware-priorities) [R]

**Sections, tokens, SEH, registry, ALPC, UMDF**
- Section objects unify file mapping, shared memory and image loading: one object, mapped as views into any process. — [Section Objects and Views](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/section-objects-and-views) [R]
- Security is identity-based: each process/thread carries an access token (SIDs, privileges) checked against per-object ACLs. — [Access Tokens](https://learn.microsoft.com/en-us/windows/win32/secauthz/access-tokens) [R]
- Structured exception handling gives hardware faults and software exceptions one OS-defined, language-neutral unwinding mechanism (contrast Unix signals). — [Structured Exception Handling](https://learn.microsoft.com/en-us/windows/win32/debug/structured-exception-handling) [R]
- The registry is a kernel-hosted hierarchical configuration database. — [Registry](https://learn.microsoft.com/en-us/windows/win32/sysinfo/registry) [R]
- ALPC is the kernel's internal message-passing IPC (under RPC, CSRSS, LSASS); it is officially undocumented, and public knowledge comes from Windows Internals and reverse engineering. — [Windows Internals book page](https://learn.microsoft.com/en-us/sysinternals/resources/windows-internals) [R]; [csandker, "Offensive Windows IPC 3: ALPC"](https://csandker.io/2022/05/24/Offensive-Windows-IPC-3-ALPC.html) [R]
- UMDF runs drivers in a user-mode host process so a driver crash does not bring down the kernel. — [Overview of UMDF](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/overview-of-the-umdf) [R]
- Regret: in NT 4.0, USER and GDI were moved from the user-mode Win32 subsystem process into kernel mode (win32k.sys) for performance, which abandoned the original microkernel-like separation. — [Microsoft TechNet, "The Windows NT 4.0 Kernel mode change"](https://learn.microsoft.com/en-us/previous-versions/cc750820(v=technet.10)) [R, verify URL]

**Subsystems / personalities**
- Pico processes (from the Drawbridge research project) are minimal processes whose syscalls are routed to a kernel-mode "pico provider" driver; WSL1 used this (lxss.sys/lxcore.sys) to implement the Linux syscall ABI on the NT kernel. — [MS WSL blog, "Pico Process Overview"](https://learn.microsoft.com/en-us/archive/blogs/wsl/pico-process-overview) [R]
- WSL2 abandoned syscall emulation for a real Linux kernel in a lightweight VM, citing file-system performance and full system-call compatibility. — [Announcing WSL 2](https://devblogs.microsoft.com/commandline/announcing-wsl-2/) [R]

**Cutler and VMS heritage**
- A roughly three-hour Dave Plummer interview with Dave Cutler was published in October 2023 (Dave's Garage); it covers RSX-11, VMS and NT, the original vision of NT as a portable system hosting several environments (OS/2, POSIX), and the schedule overrun. The link `youtu.be/xi1Lq79mLeE` is given by an OSNews commenter and was not opened in this session. — [TUHS thread, Oct 2023](https://www.tuhs.org/pipermail/tuhs/2023-October/029084.html) [V]; [OSNews](https://www.osnews.com/story/137951/windows-nt-peeking-into-the-cradle/) [V]; [Thurrott summary](https://www.thurrott.com/windows/291293/dave-cutler-talks-nt-cairo-and-more) [V]
- Primary long-form source on Cutler's design thinking: Computer History Museum oral history. — [CHM catalog 102717163](https://www.computerhistory.org/collections/catalog/102717163) [V]
- NT's architecture closely mirrors VMS (process/thread scheduler with priority levels, IRQL vs IPL, IRPs, the object and I/O layering); Russinovich documents the correspondences. — [Russinovich, "Windows NT and VMS: The Rest of the Story"](https://www.itprotoday.com/windows-client/windows-nt-and-vms-the-rest-of-the-story) [R]
- VMS's kernel was written in VAX assembly; NT was written in C for portability. — [Xataka (secondary)](https://www.xataka.com/historia-tecnologica/vms-historia-semilla-que-acabo-transformandose-windows-nt/amp) [V]

### Inferences
- The NT lesson most relevant to a new kernel: **put the ABI contract at a library/vDSO boundary, not at the trap instruction**. It preserves freedom to restructure syscalls (batching, renumbering, shared-ring transport) forever. Linux's contract buys static binaries and containers but freezes mistakes.
- NT proves a uniform object/handle table scales to a full commercial OS; its weakness is that the *namespace and security model* around it stayed ambient-authority (tokens + ACLs + global names) rather than capability-based. Zircon is essentially "NT's object manager done as capabilities".
- NT's IRP is an early form of "I/O as a data record passed through stages". Its cost comes from per-request allocation, pointer-linked driver stacks and callbacks; a data-oriented redesign would keep the request-as-record idea and batch records through stages instead.
- Personalities emulated at the syscall level (POSIX subsystem, WSL1) fail on fidelity and on performance mismatches of the underlying model; a new kernel that needs Linux binaries should plan for a VM or a full ABI layer from the start.

### Gaps
- The Cutler/Plummer video itself was not opened; specific quotations from it are not available here. Treat the portability anecdote (non-x86 first targets) as secondary.
- No Microsoft primary document was found stating in so many words that ntdll/kernel32 is the stable boundary; this rests on the documented absence of any syscall-number guarantee plus third-party evidence.
- ALPC has no official public specification.
- The Cosmopolitan `libc/nt` mechanism was not confirmed from documentation, only from the directory listing.

---

## 2. Linux: design successes and design regrets

### Takeaway
Linux's successes are narrow, composable mechanisms that move work out of the syscall path (futex, vDSO, io_uring, RCU), make the kernel programmable without modules (eBPF, sched_ext), and turn every resource into a pollable file descriptor. Its regrets are inherited Unix abstractions that do not compose with threads, async or security: fork, signals, ioctl, the tty layer, and text-format procfs.

### Cited Findings

**Successes**
- Stable syscall ABI: the rule is that a kernel change that breaks a working user program is a kernel bug. — [Torvalds, LKML 2012](https://lkml.org/lkml/2012/12/23/75) [R]; ABI stability levels documented at [kernel ABI docs](https://docs.kernel.org/admin-guide/abi-stable.html) [R]. New syscalls are expected to take extensible structs with a size argument (clone3, openat2). — [Adding a New System Call](https://docs.kernel.org/process/adding-syscalls.html) [R]
- io_uring (Jens Axboe, Linux 5.1, 2019): two single-producer/single-consumer rings shared between user and kernel (submission and completion queues) so that many operations cost one or zero syscalls; fixed buffers and registered files remove per-call lookups. — [Axboe, "Efficient IO with io_uring"](https://kernel.dk/io_uring.pdf) [R]
- io_uring caveat: Google reported that 60% of submissions to its kernel exploit bounty used io_uring vulnerabilities and disabled it on ChromeOS, for Android apps and on production servers. A huge new async surface is a huge new attack surface. — [Google Security Blog, June 2023](https://security.googleblog.com/2023/06/learnings-from-kctf-vrps-42-linux.html) [R]
- eBPF: verified, JIT-compiled programs attached to kernel hooks, with maps as shared key/value tables between kernel and user space. — [kernel BPF docs](https://docs.kernel.org/bpf/) [R]; [ebpf.io](https://ebpf.io/what-is-ebpf/) [R]
- sched_ext: scheduling policies implemented as BPF programs. Torvalds said he would merge it for 6.11 over the scheduler maintainer's objection; it landed in 6.12. By LPC 2024 it shipped in CachyOS, Arch, Ubuntu, Fedora, Nix and openSUSE. — [LWN 978007](https://lwn.net/Articles/978007) [V]; [Phoronix, 6.12 merge](https://www.phoronix.com/news/Linux-6.12-Lands-sched-ext) [V]; [LWN 991205](https://lwn.net/Articles/991205/) [V]; [pull request](https://lkml.iu.edu/hypermail/linux/kernel/2409.1/07472.html) [V]
- Counterpoint on eBPF safety: a HotOS 2023 paper argues the in-kernel verifier approach is untenable as it grows ("Kernel extension verification is untenable"). — [HotOS 2023 program](https://sigops.org/s/conferences/hotos/2023/program.html) [R]
- futex: uncontended locks never enter the kernel; the kernel only provides wait/wake keyed on a user address. — [Franke, Russell, Kirkwood, "Fuss, Futexes and Furwocks", OLS 2002](https://www.kernel.org/doc/ols/2002/ols2002-pages-479-495.pdf) [R]
- RCU: readers proceed with no locks or atomic writes; writers copy and defer reclamation. — [What is RCU?](https://docs.kernel.org/RCU/whatisRCU.html) [R]
- vDSO: kernel-supplied user-mode code page for calls such as clock_gettime that need no privilege transition. — [vdso(7)](https://man7.org/linux/man-pages/man7/vdso.7.html) [R]
- KVM: turn the kernel into the hypervisor by exposing virtualization hardware as a device with ioctls, reusing the scheduler and memory manager. — [Kivity et al., "kvm: the Linux Virtual Machine Monitor", OLS 2007](https://www.kernel.org/doc/ols/2007/ols2007v1-pages-225-230.pdf) [R]
- Everything-is-an-fd: pidfd gives a race-free process handle; eventfd, signalfd, timerfd, memfd extend the same pattern. — [pidfd_open(2)](https://man7.org/linux/man-pages/man2/pidfd_open.2.html) [R]; [memfd_create(2)](https://man7.org/linux/man-pages/man2/memfd_create.2.html) [R]
- Namespaces and cgroups v2 (single unified hierarchy). — [LWN, "Namespaces in operation"](https://lwn.net/Articles/531114/) [R]; [cgroup v2 docs](https://docs.kernel.org/admin-guide/cgroup-v2.html) [R]. Critique: a Linux "container" is not a kernel object but a convention assembled from many primitives, unlike Solaris zones or BSD jails. — [Frazelle, "Containers vs. Zones vs. Jails vs. VMs"](https://blog.jessfraz.com/post/containers-zones-jails-vms/) [R]
- Unprivileged self-sandboxing: seccomp-BPF and Landlock. — [seccomp filter docs](https://docs.kernel.org/userspace-api/seccomp_filter.html) [R]; [Landlock docs](https://docs.kernel.org/userspace-api/landlock.html) [R]
- userfaultfd (user-space page-fault handling) and DAMON (access-pattern monitoring with bounded overhead). — [userfaultfd docs](https://docs.kernel.org/admin-guide/mm/userfaultfd.html) [R]; [DAMON docs](https://docs.kernel.org/mm/damon/index.html) [R]
- Rust for Linux: at the December 2025 Maintainers Summit the "experiment" was declared concluded; Miguel Ojeda's patch "rust: conclude the Rust experiment" removes the experimental wording, noting Rust code is already in production use. s390 support was raised as an open issue. — [LWN 1050174](https://lwn.net/SubscriberLink/1050174/6b6d55c90ce1100f) [V]; [patch](https://patchew.org/linux/20251213000042.23072-1-ojeda@kernel.org) [V]

**Regrets**
- fork: Baumann, Appavoo, Krieger and Roscoe argue fork is a historical hack that is not thread-safe, is insecure by default (inherits everything), is slow for large address spaces, does not compose with user-mode state, encourages memory overcommit, and constrains OS design; they recommend spawn-style APIs and cross-process primitives that act on a child handle. — ["A fork() in the road", HotOS 2019](https://www.microsoft.com/en-us/research/uploads/prod/2019/04/fork-hotos19.pdf) [R]
- The fork problem is still live in 2025: HotOS 2025 has "Spork: A posix_spawn you can use as a fork". — [HotOS 2025 program](https://sigops.org/s/conferences/hotos/2025/program.html) [V]; [DOI](https://doi.org/10.1145/3713082.3730396) [V]
- ioctl: at LSFMM 2022, Luis Chamberlain argued "everything is a file" enables lazy API design and that ioctl commands are poorly documented and not introspectable; Ted Ts'o called them system calls in disguise; James Bottomley defended judicious use. — [LWN, "ioctl() forever?"](https://lwn.net/Articles/897202/) [V]. Torvalds in 2001 called ioctls typeless back doors. — [LWN archive](https://static.lwn.net/2001/0524/a/lt-ioctl.php3) [V]. Netlink, the proposed replacement, is considered hard to use from user space. — [lore thread 2022](https://lore.kernel.org/all/Yh1HkqZHDtnSzm+d@bombadil.infradead.org/T/) [V]
- procfs: by 2004 maintainers were asking that no more interfaces be added to /proc. — [LKML 2004](https://lkml.iu.edu/hypermail/linux/kernel/0412.2/0125.html) [V]. sysfs responded with a "one value per file" rule. — [sysfs docs](https://docs.kernel.org/filesystems/sysfs.html) [R]
- signals: process-global, asynchronous, interact badly with threads and libraries; signalfd does not fix the underlying model. — ["signalfd is useless"](https://ldpreload.com/blog/signalfd-is-useless) [R]
- tty layer: line discipline, job control and terminal emulation concerns are entangled in the kernel for teletype-era reasons. — [Åkesson, "The TTY demystified"](https://www.linusakesson.net/programming/tty/) [R]
- epoll: readiness notification tied to file descriptions rather than descriptors leads to surprising behaviour with dup/fork and to thundering-herd/load-balancing problems across threads. — [Majkowski, "Epoll is fundamentally broken"](https://idea.popcount.org/2017-02-20-epoll-is-fundamentally-broken-12/) [R]

### Inferences
- The pattern across Linux's successes: **the kernel provides a tiny mechanism plus shared memory; policy and the fast path live in user space** (futex, vDSO, io_uring rings, BPF maps). All of these are flat shared arrays or tables, which is why they fit a data-oriented kernel.
- The pattern across the regrets: **implicit, ambient, process-global state** (fork copies everything, signals are per-process, tty state is hidden, ioctl is untyped). A new kernel should make every such thing an explicit handle with a typed, introspectable schema.
- io_uring shows both the benefit of batch submission and the security cost of bolting a second, very large entry path onto an existing kernel. If batched rings are the *only* entry path from day one, there is one surface to harden instead of two.
- pidfd arriving in 2019 shows what happens when a core object (the process) lacks a handle for decades. Give every object a handle from the start.

### Gaps
- No single authoritative "list of Linux design regrets" by the maintainers was found; the regrets above are assembled from separate sources of varying authority (the fork paper and LWN are strong; the signals, tty and epoll items are respected practitioner blog posts).
- The LWN article that reported the 6.12 sched_ext merge itself was not located; the Phoronix report and the pull request were.

---

## 3. Radical alternatives: what was tried, what worked, what failed and why

### Takeaway
Most radical designs were technically vindicated in part but did not survive as general-purpose systems; their ideas were absorbed piecemeal (exokernel into kernel-bypass and virtualization, capabilities into Capsicum/Zircon/CHERI, language-based isolation into Rust kernels and eBPF, library OSes into WSL and SQL Server on Linux). The designs that did ship at scale are narrow or compatibility-preserving: seL4, Tock, Hubris, Zircon, HongMeng.

### Cited Findings

**Exokernels, library OSes, unikernels**
- Exokernel (MIT Aegis/XOK): the kernel only securely multiplexes hardware; all abstractions live in untrusted library OSes, so applications can specialise them. — [Engler, Kaashoek, O'Toole, SOSP 1995](https://pdos.csail.mit.edu/6.828/2008/readings/engler95exokernel.pdf) [R]
- Drawbridge: a Windows library OS in a "picoprocess" over a narrow ABI of about 36 calls (verify). It became the basis of WSL1 pico processes and of SQL Server on Linux. — [Porter et al., ASPLOS 2011](https://www.microsoft.com/en-us/research/publication/rethinking-the-library-os-from-the-top-down/) [R]; [SQL Server on Linux, how it works](https://cloudblogs.microsoft.com/sqlserver/2016/12/16/sql-server-on-linux-how-introduction/) [R, verify URL]
- Unikernels (MirageOS): compile application plus only the needed OS libraries into one single-address-space image for a hypervisor. — [Madhavapeddy et al., ASPLOS 2013](https://anil.recoil.org/papers/2013-asplos-mirage.pdf) [R]
- Unikraft: modular micro-library unikernel with POSIX compatibility; EuroSys 2021. — [arXiv 2104.12721](https://arxiv.org/abs/2104.12721) [R]
- Why unikernels stayed niche: no process boundary means no debugging tools, no multi-process software, and a crash is a reboot. — [Cantrill, "Unikernels are unfit for production"](https://www.tritondatacenter.com/blog/unikernels-are-unfit-for-production) [R]

**Microkernels and capabilities**
- L4 lesson: IPC must be extremely fast and the kernel minimal; twenty years of experience is summarised by Heiser and Elphinstone. — ["L4 Microkernels: The Lessons from 20 Years"](https://trustworthy.systems/publications/nicta_full_text/8988.pdf) [R, verify URL]
- seL4: first general-purpose kernel with a machine-checked proof of functional correctness; all authority is by capability and the kernel does no dynamic allocation of its own (user space supplies "untyped" memory for kernel objects). — [Klein et al., SOSP 2009](https://www.sigops.org/s/conferences/sosp/2009/papers/klein-sosp09.pdf) [R]; [seL4 whitepaper](https://sel4.systems/About/seL4-whitepaper.pdf) [R]
- KeyKOS / EROS: pure capability systems with orthogonal persistence by whole-system checkpoint; no file system is needed because everything persists. — [KeyKOS papers at cap-lore](http://cap-lore.com/CapTheory/upenn/) [R]; [Shapiro et al., "EROS: a fast capability system", SOSP 1999](https://dl.acm.org/doi/10.1145/319151.319163) [R]
- The motivating argument against ambient authority. — [Hardy, "The Confused Deputy"](http://cap-lore.com/CapTheory/ConfusedDeputy.html) [R]
- Capsicum: retrofits capabilities onto Unix by turning file descriptors into capabilities and adding a "capability mode" with no global namespaces. — [Watson et al., USENIX Security 2010](https://www.usenix.org/legacy/event/sec10/tech/full_papers/Watson.pdf) [R]
- CHERI: hardware capabilities (bounded, unforgeable pointers) in the ISA. — [Cambridge CHERI](https://www.cl.cam.ac.uk/research/security/ctsrd/cheri/) [R]
- Zircon (Fuchsia): object-capability kernel; handles are process-local 32-bit integers carrying rights; most syscalls operate on handles; no global file system namespace in the kernel. — [Zircon fundamentals](https://fuchsia.dev/fuchsia-src/get-started/learn/intro/zircon) [V]; [kernel concepts](https://fuchsia.dev/fuchsia-src/concepts/kernel) [R]
- Fuchsia shipped on first-generation Nest Hub in 2021 and second-generation in 2023. — [The Stack](https://www.thestack.technology/google-ships-fuchsia/) [V]. Third-party write-ups say rights can only be reduced on duplication, and that Starnix (Linux ABI layer) is a major focus; these were not checked against official docs. — [capos Zircon notes (third party)](https://capos-93z.pages.dev/research/zircon) [V]
- HongMeng (Huawei, HarmonyOS NEXT): production microkernel that keeps Linux API/ABI compatibility to reuse apps and drivers, and revisits IPC, capability-based access control and user-space paging for performance; the authors report it deployed in production and typically faster than Linux in their measurements. — [Chen et al., "Microkernel Goes General", OSDI 2024](https://www.usenix.org/conference/osdi24/presentation/chen-haibo) [V]; [slides](https://usenix.org/system/files/osdi24_slides-chen-haibo.pdf) [V]
- Genode: component framework with recursive sandboxing and explicit resource budgets passed from parent to child. — [Genode Foundations](https://genode.org/documentation/genode-foundations/) [R]
- Managarm: microkernel with fully asynchronous I/O throughout and Linux source compatibility. — [managarm on GitHub](https://github.com/managarm/managarm) [R]
- Redox: Rust microkernel where resources are reached through user-space "scheme" providers (URL-like names). — [Redox book](https://doc.redox-os.org/book/) [R]

**Plan 9**
- All resources are files served over one protocol (9P); each process has its own composable namespace; no ioctl, no sockets API, no superuser needed for mounting. — [Pike et al., "Plan 9 from Bell Labs"](https://9p.io/sys/doc/9.html) [R]; ["The Use of Name Spaces in Plan 9"](https://9p.io/sys/doc/names.html) [R]

**Language-based isolation, single address space**
- Singularity: software-isolated processes in one address space and one privilege level, verified by a type-safe language; contract-typed message channels; sealed processes (no dynamic code loading). The paper reports that hardware isolation costs far more than software isolation (under 5% vs about 38% on one benchmark; verify). — [Hunt & Larus, "Singularity: Rethinking the Software Stack"](https://www.microsoft.com/en-us/research/publication/singularity-rethinking-the-software-stack/) [R]
- Midori (Joe Duffy's series): everything asynchronous, objects as capabilities with no ambient authority, a safe native-compiled C# dialect, and a two-part error model (abandonment for bugs, checked exceptions for recoverable errors). It ran real workloads internally but was cancelled in 2015; lessons flowed into .NET and C#. — [Blogging about Midori](https://joeduffyblog.com/2015/11/03/blogging-about-midori/) [R]; [Objects as Secure Capabilities](https://joeduffyblog.com/2015/11/10/objects-as-secure-capabilities/) [R]; [Asynchronous Everything](https://joeduffyblog.com/2015/11/19/asynchronous-everything/) [R]; [Safe Native Code](https://joeduffyblog.com/2015/12/19/safe-native-code/) [R]; [The Error Model](https://joeduffyblog.com/2016/02/07/the-error-model/) [R]
- Hard limit on software-only isolation: Spectre lets code in one address space read memory it cannot architecturally access; the V8 team concluded this cannot be fully mitigated in software. — ["Spectre is here to stay", arXiv 1902.05178](https://arxiv.org/abs/1902.05178) [R]
- Single-address-space OSes (Opal; also Mungi, Nemesis): one global virtual address space so pointers are valid everywhere and sharing is trivial; protection is by domains, not address spaces. Nemesis added the idea that applications do their own work (including paging) to avoid QoS crosstalk. — [Chase et al., Opal, TOCS 1994](https://dl.acm.org/doi/10.1145/195792.195795) [R]; [Leslie et al., Nemesis, IEEE JSAC 1996](https://doi.org/10.1109/49.536480) [R]
- Theseus: Rust OS, single address space and single privilege level, built from many small "cells" with runtime-checked boundaries; the design goal is to avoid "state spill" between components so they can be swapped live. — [Boos et al., OSDI 2020](https://www.usenix.org/conference/osdi20/presentation/boos) [R]
- Asterinas: "framekernel" — a single-address-space Rust kernel split into a small privileged framework (OSTD) that may use `unsafe` and de-privileged services written in safe Rust; over 210 Linux syscalls, performance comparable to Linux, TCB about 14.0% of the code base. — [USENIX ATC 2025](https://www.usenix.org/conference/atc25/presentation/peng-yuke) [V]; [arXiv 2506.03876](https://arxiv.org/abs/2506.03876) [V]; [LWN 1022920](https://lwn.net/Articles/1022920/) [V]
- Tock: embedded Rust kernel; kernel extensions ("capsules") isolated by the type system at zero run-time cost, applications isolated by MPU, and per-process "grant" regions so kernel allocations on behalf of a process are charged to that process. — [Levy et al., SOSP 2017](https://dl.acm.org/doi/10.1145/3132747.3132786) [R]. A SOSP 2025 paper "Tock: From Research To Securing 10 Million Computers" exists (seen only as a citation). — [citation in arXiv 2609.04372](https://arxiv.org/pdf/2609.04372) [V]
- Hubris (Oxide): no run-time task creation or destruction, no dynamic resource allocation, no privileged driver code, no C; all tasks are declared at build time and linked into one image, which means a faulted task can always be restarted because its resources are reserved. — [hubris.oxide.computer](https://hubris.oxide.computer/) [V]; [Oxide blog, "Hubris and Humility"](https://oxide.computer/blog/hubris-and-humility) [V]
- Verified Rust kernels, SOSP 2025: Atmosphere (Rust + Verus, proof-to-code ratio 3.32:1, verification in under 20 s on a laptop; uses manual memory management rather than leaning on the borrow checker; a third-party summary notes it uses a big lock and leaves boot and drivers unverified). CortenMM (verified concurrent memory management, Best Paper). — [Atmosphere paper](https://mars-research.github.io/doc/2025-sosp-atmo.pdf) [V]; [third-party summary](https://awesome-system-papers.pages.dev/papers/Atmosphere-SOSP25) [V]; [CortenMM paper](https://zhou-diyu.github.io/files/cortenmm-sosp25.pdf) [V]
- Oberon: a complete single-user OS and compiler small enough to be described in one book; type-safe modules, no processes in the Unix sense, commands as exported procedures. — [Wirth & Gutknecht, Project Oberon](https://people.inf.ethz.ch/wirth/ProjectOberon/index.html) [R]
- Smalltalk: language, environment and "OS" are one image of live objects. — [Ingalls, "Design Principles Behind Smalltalk"](https://www.cs.virginia.edu/~evans/cs655/readings/smalltalk.html) [R]. Lisp machines (Genera) took the same single-language, single-address-space approach. — [Wikipedia: Genera](https://en.wikipedia.org/wiki/Genera_(operating_system)) [R, secondary]
- TempleOS: ring 0 only, identity-mapped single address space, no protection, JIT-compiled HolyC as both shell and systems language. Demonstrates how small and immediate a system becomes when protection is dropped; unusable for anything adversarial. — [templeos.org](https://templeos.org/) [R]
- WebAssembly in ring 0: Nebulet (Rust microkernel running wasm in kernel mode, avoiding ring transitions) and Wasmer's kernel-wasm (wasm inside Linux). Both are dormant experiments. — [nebulet](https://github.com/nebulet/nebulet) [R]; [kernel-wasm](https://github.com/wasmerio/kernel-wasm) [R]

**Persistence**
- Phantom OS: orthogonal persistence of a managed object heap via continuous snapshots; no files. — [phantomuserland](https://github.com/dzavalishin/phantomuserland) [R]
- Twizzler: an OS for non-volatile memory where persistent objects with invariant (position-independent) pointers replace files and read/write. — [Bittman et al., USENIX ATC 2020](https://www.usenix.org/conference/atc20/presentation/bittman) [R]
- Context shift: a HotOS 2025 paper from Microsoft Research is titled "Storage Class Memory is Dead, All Hail Managed-Retention Memory". — [DOI](https://doi.org/10.1145/3713082.3730381) [V]

**Multicore, dataplane, disaggregation**
- Barrelfish multikernel: treat the machine as a distributed system; one kernel per core, no shared kernel state, replicated state kept consistent by messages; hardware knowledge held in a queryable "system knowledge base". — [Baumann et al., SOSP 2009](https://www.sigops.org/s/conferences/sosp/2009/papers/baumann-sosp09.pdf) [R]
- Arrakis and IX (both OSDI 2014): kernel as control plane only; applications get direct, hardware-virtualised device access; IX adds run-to-completion with adaptive batching. — [Arrakis](https://www.usenix.org/conference/osdi14/technical-sessions/presentation/peter) [R]; [IX](https://www.usenix.org/conference/osdi14/technical-sessions/presentation/belay) [R]
- Demikernel: a library-OS architecture with a portable queue-based async I/O API over heterogeneous kernel-bypass devices. — [Zhang et al., SOSP 2021](https://irenezhang.net/papers/demikernel-sosp21.pdf) [R]
- LegoOS "splitkernel": OS functions split into monitors running on disaggregated processor, memory and storage components. — [Shan et al., OSDI 2018](https://www.usenix.org/conference/osdi18/presentation/shan) [R]

**DBOS**
- DBOS (Stonebraker, Zaharia, Kozyrakis et al.) proposes an OS stack built on a distributed transactional DBMS; the authors report a prototype with competitive performance for scheduling, file management and IPC. PVLDB 15(1):21-30; sources disagree on whether to date it 2021 or 2022. — [VLDB paper](https://mail.vldb.org/pvldb/volumes/15/paper/DBOS%3A%20A%20DBMS-oriented%20Operating%20System) [V]; [Stanford page](https://web.stanford.edu/~kozyraki/publication/2021-dbos-vldb) [V]; [CIDR 2022 progress report](https://mail.vldb.org/cidrdb/2022/a-progress-report-on-dbos-a-database-oriented-operating-system.html) [V]

**HotOS 2023-2025 and the 2024-2026 direction**
- HotOS is biennial; the 20th edition was held May 14-16, 2025 in Banff, and a listing site shows the next edition in 2027. There is no HotOS 2026. — [HotOS 2025 site](https://sigops.org/s/conferences/hotos/2025/) [V]
- HotOS 2025 papers relevant to kernel design: "How I learned to stop worrying and love learned OS policies"; "The NIC should be part of the OS" (Xu, Roscoe); "Stop Taking the Scenic Route: the Shortest Distance Between the CPU and the NIC is MMIO"; "Apiary: An OS for the Modern FPGA"; "Spork: A posix_spawn you can use as a fork"; "Guillotine: Hypervisors for Isolating Malicious AIs"; "Modular, Full-System Verification"; "Lightweight Hypervisor Verification"; "Rethinking Tiered Storage: Talk to File Systems, Not Device Drivers"; "My CXL Pool Obviates Your PCIe Switch"; "Can Large Language Models Verify System Software?". — [HotOS 2025 program](https://sigops.org/s/conferences/hotos/2025/program.html) [V]

### Inferences
- Reasons radical OSes fail are rarely technical: no drivers, no applications, and no migration path. The three that reached production at scale recently (Zircon, HongMeng, Asterinas-in-progress) all invested heavily in Linux ABI or driver compatibility. HongMeng's paper title states the lesson: performance *and compatibility*.
- Language-only isolation (Singularity, Midori, Theseus, TempleOS-style ring 0) gives the largest performance and simplicity wins but is undermined by Spectre for mutually distrusting code. The Asterinas "framekernel" compromise — language isolation *inside* the kernel, hardware isolation for user processes — is the current consensus position.
- Static configuration (Hubris, seL4's no-kernel-allocation rule, Tock grants) trades flexibility for the ability to reason about every resource. The same property makes them naturally table-shaped (see section 4).
- The 2025 research agenda has moved from "new kernel structure" to (a) verification of Rust kernels, (b) learned/programmable policy, (c) the OS re-absorbing hardware it does not control (NICs, FPGAs, CXL, BMCs), and (d) isolating AI workloads.

### Gaps
- The DBOS PDF could not be fetched (HTTP 503), so the detailed design (which tables, which DBMS, measured numbers, stated limitations) is not sourced here. From the researcher's memory, unverified: a four-level stack (microkernel services, distributed DBMS, OS services written as SQL/stored procedures, applications), prototype on VoltDB, and tables for tasks, workers, files and messages. The report writer should confirm against the paper before quoting.
- Mungi: no primary URL verified. Lisp machines: only a secondary (Wikipedia) link given.
- Fuchsia/Starnix 2025 status rests on community sources only.
- No 2026 workshop paper proposing a complete new kernel architecture was found; HotOS did not run in 2026, and SOSP/OSDI 2026 programs were not searched.
- Nebulet and kernel-wasm status ("dormant") is recalled, not re-checked.

---

## 4. Which ideas map naturally onto a data-oriented kernel (OS state as flat tables/arrays, batch processing, minimal pointer chasing)?

### Takeaway
The strongest precedents are DBOS (OS state as queryable tables), io_uring (batched request/completion arrays in shared memory), capability/handle tables (Zircon, seL4 CNodes, NT handle tables), and build-time static tables (Hubris, Tock). No surveyed system combines all four; that combination appears to be open design space.

### Cited Findings
- DBOS's stated premise is to build the OS around a DBMS so that scheduling, files and IPC are operations on tables, with competitive prototype performance reported by the authors. — [DBOS, PVLDB 15](https://mail.vldb.org/pvldb/volumes/15/paper/DBOS%3A%20A%20DBMS-oriented%20Operating%20System) [V]
- io_uring's interface is two shared ring arrays of fixed-size records (SQEs, CQEs); registered buffers and files replace per-call lookups with array indices. — [Axboe, io_uring paper](https://kernel.dk/io_uring.pdf) [R]
- Windows adopted the same ring layout in IoRing. — [Shafir, IoRing vs io_uring](https://windows-internals.com/ioring-vs-io_uring-a-comparison-of-windows-and-linux-implementations/) [R]
- Zircon handles are 32-bit process-local integers that index kernel objects and carry rights. — [Zircon fundamentals](https://fuchsia.dev/fuchsia-src/get-started/learn/intro/zircon) [V]
- seL4 stores capabilities in CNodes (arrays of capability slots) and the kernel never allocates memory itself; user space retypes untyped memory into kernel objects. — [seL4 whitepaper](https://sel4.systems/About/seL4-whitepaper.pdf) [R]
- Hubris fixes the task set at build time with no dynamic allocation. — [hubris.oxide.computer](https://hubris.oxide.computer/) [V]
- Tock's grants give each process its own region for kernel state held on its behalf. — [Tock, SOSP 2017](https://dl.acm.org/doi/10.1145/3132747.3132786) [R]
- eBPF maps are typed key/value tables shared between kernel programs and user space. — [kernel BPF docs](https://docs.kernel.org/bpf/) [R]
- IX processes packets run-to-completion in adaptive batches. — [IX, OSDI 2014](https://www.usenix.org/conference/osdi14/technical-sessions/presentation/belay) [R]
- Barrelfish keeps per-core replicated state with no sharing and a queryable knowledge base of hardware facts. — [Multikernel, SOSP 2009](https://www.sigops.org/s/conferences/sosp/2009/papers/baumann-sosp09.pdf) [R]
- NT IRPs represent each I/O as one record with a per-driver stack-location array. — [I/O request packets](https://learn.microsoft.com/en-us/windows-hardware/drivers/gettingstarted/i-o-request-packets) [R]
- Linux's text-format procfs is regarded as a mistake; maintainers pushed back on extending it. — [LKML 2004](https://lkml.iu.edu/hypermail/linux/kernel/0412.2/0125.html) [V]
- RCU gives lock-free readers over versioned data. — [What is RCU?](https://docs.kernel.org/RCU/whatisRCU.html) [R]

### Inferences
Mapping of ideas to a table-centric kernel (all of this is the researcher's synthesis, not a claim from any source):

| Idea | Table-shaped form | Caveat |
|---|---|---|
| DBOS | All kernel state in typed tables; introspection is a query, not a text file or ioctl | DBOS ran on a full DBMS above a conventional kernel; the cost of the idea at kernel level with plain arrays is undemonstrated |
| io_uring / IoRing | Syscall interface = submission array in, completion array out; kernel processes a batch per stage | Linux's security record shows the cost of adding it beside a legacy path |
| Handle/capability tables (NT, Zircon, seL4) | Handle = index + generation into a per-process array of (object index, rights) | Revocation and delegation need care; seL4's derivation tree is pointer-heavy |
| Hubris / Tock static tables | Task, IRQ and region tables sized at build or boot time | General-purpose systems need growth; fixed-capacity pools with explicit limits are the middle ground |
| seL4 "no kernel allocation" | User space donates memory for every table row; accounting is exact | Complicates the user-space API |
| eBPF maps / sched_ext | Policy code reads and writes kernel tables through a verified interface | Verifier complexity is a known risk (HotOS 2023) |
| Barrelfish multikernel | Per-core tables, no cross-core pointers, messages between cores | Replication protocols add latency |
| IX / Demikernel | Run-to-completion batches through pipeline stages | Tail latency versus batch size trade-off |
| NT IRP | Request record flows through stages | Replace per-request callbacks and linked driver stacks with stage-wise batch passes |
| RCU | Versioned columns/rows with epoch reclamation for readers | Patent-free now but reclamation design is subtle |
| sysfs "one value per file" → binary schema | Tables exported read-only with a self-describing schema instead of text | Schema evolution must be designed in (cf. extensible-struct syscalls) |

- Ideas that fit poorly: Plan 9 "everything is a file/byte stream" (untyped streams are the opposite of typed tables, though per-process namespaces map to a per-process name table); Smalltalk/Lisp-machine object graphs and orthogonally persistent heaps (pointer-rich by construction); fork (requires copying an entire implicit state graph).
- A data-oriented kernel makes whole-system checkpointing (KeyKOS-style persistence) and live introspection cheap, because state is already in flat, relocatable form. This is a plausible secondary benefit, undemonstrated.

### Gaps
- No source was found that evaluates a kernel built explicitly on data-oriented design (structure-of-arrays kernel tables, batch-per-stage syscall processing). Whether such a design beats a conventional kernel is unmeasured in the literature surveyed.
- DBOS's detailed table schemas and performance numbers were not retrieved (see section 3 gaps).
- Jonathan Blow's own statements about OS design were out of scope here and are not covered.

---

## 5. Classic papers on why new OSes fail or matter, and the driver-ecosystem problem

### Takeaway
The recurring argument is that new OSes fail on ecosystem (drivers, applications, standards compliance), not on technical merit, and that the OS community has compounded this by treating Linux-on-idealised-hardware as the only research target. Every successful newcomer has had an explicit strategy for borrowing drivers or binaries.

### Cited Findings
- Rob Pike (2000) argued that systems software research had become irrelevant: new OSes must reimplement an ever-growing pile of external standards before doing anything new, so research retreated to measuring and tweaking existing systems. — ["Systems Software Research is Irrelevant"](http://herpolhode.com/rob/utah2000.pdf) [R]
- Richard Gabriel: a simple, slightly wrong design that is easy to implement and port spreads faster than "the right thing" and then improves in place; Unix and C are his examples. — ["The Rise of Worse is Better"](https://www.dreamsongs.com/RiseOfWorseIsBetter.html) [R]
- Timothy Roscoe's joint ATC/OSDI 2021 keynote argues the OS community should re-engage with what modern hardware actually is; commentary on the talk notes his points that a classical OS controls only a fraction of a modern machine and that platform management controllers can treat the OS as an adversary. — [USENIX keynote page (video)](https://www.usenix.org/conference/osdi21/presentation/fri-keynote) [V]; [TUHS discussion](https://www.tuhs.org/pipermail/tuhs/2021-September/024391.html) [V]
- Roscoe's group continued the argument at HotOS 2025 with "The NIC should be part of the OS". — [DOI](https://doi.org/10.1145/3713082.3730388) [V]
- Lampson's design advice (keep it simple, get it right, make the fast path fast, use hints) remains the standard reference. — ["Hints for Computer System Design"](https://www.microsoft.com/en-us/research/publication/hints-for-computer-system-design/) [R]
- Linux deliberately has no stable in-kernel driver API, which keeps drivers in-tree and makes them hard for other kernels to reuse. — [stable-api-nonsense](https://docs.kernel.org/process/stable-api-nonsense.html) [R]
- Driver-reuse strategies:
  - Run the donor OS and its unmodified drivers in a virtual machine and talk to them over a narrow interface. — [LeVasseur et al., OSDI 2004](https://www.usenix.org/legacy/event/osdi04/tech/levasseur.html) [R]
  - Rump kernels / anykernel: structure a kernel (NetBSD) so its drivers and file systems run unmodified as libraries in user space or on other hosts. — [Kantee, USENIX ATC 2009](https://www.usenix.org/legacy/event/usenix09/tech/full_papers/kantee/kantee.pdf) [R]
  - LinuxKPI: a shim that implements enough of the Linux kernel programming interface for FreeBSD to compile Linux graphics and wireless drivers. — [FreeBSD wiki, LinuxKPI](https://wiki.freebsd.org/LinuxKPI) [R]
  - ABI compatibility as the strategy: HongMeng keeps Linux API/ABI compatibility specifically to reuse applications and drivers. — [OSDI 2024](https://www.usenix.org/conference/osdi24/presentation/chen-haibo) [V]. Asterinas targets the Linux ABI (210+ syscalls). — [ATC 2025](https://www.usenix.org/conference/atc25/presentation/peng-yuke) [V]. WSL2 runs a real Linux kernel in a VM. — [Announcing WSL 2](https://devblogs.microsoft.com/commandline/announcing-wsl-2/) [R]
  - User-mode driver frameworks reduce the cost of a bad driver. — [UMDF overview](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/overview-of-the-umdf) [R]

### Inferences
- For a break-with-tradition kernel the realistic bootstrapping order is: (1) run under a hypervisor with virtio only, which reduces the driver problem to a handful of devices; (2) reuse Linux drivers through a driver VM or a LinuxKPI-style shim; (3) write native drivers only for the few devices where the new design's advantage matters (NIC, NVMe, GPU).
- Gabriel's argument cuts both ways for a data-oriented kernel: a small, simple, table-based core is "worse is better" compatible if it is easy to port and understand; an ambitious "right thing" that requires a new language, new drivers and new applications all at once repeats Midori's outcome.
- Pike's standards burden has grown since 2000 (USB, ACPI, UEFI, Wi-Fi, GPU stacks, TLS, browsers). The only cheap escapes are narrowing the target (servers, VMs, embedded, consoles) or hosting a compatibility personality.
- Roscoe's point implies a new kernel has an opening the incumbents lack: modelling the whole machine (firmware, BMC, SmartNIC, accelerators) as first-class managed state rather than opaque devices.

### Gaps
- Roscoe's keynote was not watched and no transcript was found; the characterisation above comes from the abstract and mailing-list commentary.
- No quantitative study was found of how much engineering effort each driver-reuse strategy costs or how much device coverage it yields.
- HongMeng's specific driver-reuse mechanism was not read in detail; only the abstract-level claim is sourced.
