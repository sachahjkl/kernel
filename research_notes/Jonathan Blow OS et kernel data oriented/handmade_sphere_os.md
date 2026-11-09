# Handmade-sphere OS and kernel design ideas (Muratori, Handmade Network, Fleury, gingerBill, Kelley and adjacent)

Research date: 2026-11-09. Method note for the report writer: the talk video of "The Thirty Million Line Problem" and the paywalled Computer Enhance videos could not be read directly (no transcript access), so talk content below is reconstructed from Muratori's own blog abstract plus several independent written summaries; each bullet says which. Anything I know only from memory and could not confirm this session is confined to the "Gaps" subsections and labelled UNVERIFIED.

## 1. Casey Muratori's "The Thirty Million Line Problem": thesis and follow-ups

### Takeaway
Muratori's thesis is that the unreliability of modern software and the absence of OS competition both trace back to hardware that can only be driven through tens of millions of lines of vendor/OS code, and that the way out is for hardware (ideally whole SoCs) to expose stable, documented, driverless interfaces treated like an ISA, so that a small team could again write an OS or boot software directly. He himself concedes that a stable hardware ISA costs vendors more than shipping buggy, continuously patched drivers.

### Cited Findings

Primary source (Muratori's own abstract)
- Title "The Thirty-Million-Line Problem (2015)", posted on his blog 2018-05-21; the "(2015)" marks when the lecture was given. Video: https://youtu.be/kZRE7HIO3vk — [caseymuratori.com/blog_0031](https://caseymuratori.com/blog_0031); video URL as linked from [a podcast listing](https://pocketcasts.com/podcast/software-unscripted/1f1720a0-5ab3-013a-d70c-0acc26574db2/jonathan-blow-on-programming-language-design/ccc56d23-0dd0-4adb-a4f0-2ae27ffbd8ff)
- Diagnosis: software is less trustworthy than in the 1990s despite vastly better hardware (forced restarts, mandatory updates, malware exposure, ads, programs that stop working with no user action) — [caseymuratori.com/blog_0031](https://caseymuratori.com/blog_0031)
- Economic argument: desktop and phone OSes are duopolies whose owners earn their money elsewhere; direct quote "The operating system is never a product anymore." — [caseymuratori.com/blog_0031](https://caseymuratori.com/blog_0031)
- Root cause claimed: interfacing with consumer hardware is so hard that a new OS cannot realistically enter the market (he suggests this also explains desktop Linux's weakness) — [caseymuratori.com/blog_0031](https://caseymuratori.com/blog_0031)
- Proposal: treat hardware interfaces as instruction set architectures; consolidate to a few reasonable ISAs. He admits shipping a stable ISA is more expensive than shipping continually updated buggy drivers. Quote: "Eventually, I'd really like to see a return to sensible, simple interface standards for hardware." — [caseymuratori.com/blog_0031](https://caseymuratori.com/blog_0031)

Talk content as reported by third-party written summaries (secondary; I could not check them against the video)
- Length about 1h talk plus 40 min Q&A. Claims: early machines (e.g. Amiga) let a developer be "in total command of a machine and its resources"; complexity (measured roughly in lines of code) now sits mostly in the OS, driven by hardware variety and HALs; USB is the cautionary example (a standard bus that left device behaviour to vendors, hence vendor drivers); the fix is an "ISA" of driverless, primitive device interfaces, with documented game consoles and modern SoCs as precedents — [arrdem, 2021-04-27](https://www.arrdem.com/2021/04/27/thirty_million/)
- The proposed solution is described as an SoC-wide ISA covering all components — [ForwardCom forum, Kulasko, 2018-05-14](https://www.forwardcom.info/forum/viewtopic.php?t=89)
- The talk cites stacks of roughly 30 or 55 million lines; discusses that entering 64-bit mode on x86 is 10-20 lines of assembly plus page tables, that multicore bring-up (APs start in 16-bit mode), interrupt routing (IOAPIC) and ACPI are where the pain is (ACPICA alone "over 125,000 lines of code"), that USB/Plug and Play left machines "at the mercy of hardware manufacturers", and uses 1980s Amiga boot disks as the example of many custom per-application "OSes" — [Andrew Bromage, Homebrew OS blog, 2018-05-13](https://handmade.network/p/14/homebrew-os/blog/p/3137-the_thirty-million_line_problem)
- HN commenters paraphrase the proposal as "Simplify the NIC, SATA, USB and video interface" and "17 million lines of code in Thing X to do Activity Y" — [HN thread 21366555, 2019](https://news.ycombinator.com/item?id=21366555)
- A 2025 HN comment summarises that Muratori argues for ISAs for hardware "including GPUs, instead of heavy drivers" (search-result summary of the thread; not fetched in full) — [HN 46302488](https://news.ycombinator.com/item?id=46302488)

Follow-ups and related Muratori material
- "Where bad code comes from" (as restated in a Sept 2026 interview, The Peterman Pod, "Casey Muratori: Surprises In Computer History And Where Bad Code Comes From", published 2026-09-14): bad code comes from "this failure to engage with the actual reality of the situation"; up-front design without implementation "universally ... leads to the worst kind of code"; remedy is bottom-up, build what you know you need and derive the abstraction from working code — [developing.dev](https://www.developing.dev/p/casey-muratori-surprises-in-computer)
- Conway's law, same interview: the one software-engineering idea he would bet on being a real law; "Products will have a similar structure to the organization that produced them"; treat it as unavoidable and place team boundaries where they hurt least. (Relevant to kernel design: subsystem/driver boundaries mirror vendor/org boundaries.) — [developing.dev](https://www.developing.dev/p/casey-muratori-surprises-in-computer)
- BSC 2025 (Better Software Conference, Sweden, July 2025): "The Big OOPs: Anatomy of a Thirty-five-year Mistake", a history of OOP/architecture; it is not an OS talk — [Wikipedia: Casey Muratori](https://en.wikipedia.org/wiki/Casey_Muratori); [Talk::Overflow digest](https://talkoverflow.substack.com/p/talkoverflow-14-highlights-from-better); posted by Blow at [x.com/Jonathan_Blow/status/1945912418908955097](https://x.com/Jonathan_Blow/status/1945912418908955097)
- A later BSC talk (reported as BSC 2026) traces "premature optimization is the root of all evil" to its origins (aggregator headline only; content not verified) — [zeli.app](https://zeli.app/story/49463888)
- refterm / Windows Terminal (2021): Muratori wrote a reference terminal renderer after a GitHub dispute (microsoft/terminal issue #10362). His reported figures for a 1 GB dump: Windows Terminal about 330 s, refterm through conhost about 40 s, refterm through "fast pipes" about 6 s, about 0.6 s after a basic optimisation; his FAQ says Windows Terminal is about 10x slower than it should be and conhost another 10x. Kernel-relevant point: the console/pipe IPC layer of the OS, not rendering, was a large share of the cost. (Figures via search-result summaries of his write-up and FAQ mirror; not read in the original.) — [refterm FAQ mirror](https://github.winds-ss.workers.dev/warappa/refterm/blob/main/faq.md); independent look at refterm's performance: [nibblestew, 2021-07-05](https://nibblestew.blogspot.com/2021/07/looking-at-performance-of-refterm.html)
- Computer Enhance: the performance-aware course has a page-faults video; visible Q&A questions (2023-09-11) show the content covered: page-fault cost attributed to "the work the OS does" managing page tables rather than swapping, Linux mapping fresh allocations to a shared zero page and remapping on write, OS fault-ahead (an asker measured about 902 KB per fault against 4 KB pages), and OS page-fault counters versus reading the CPU directly. Casey's answers are paywalled — [computerenhance.com Q&A #26](https://www.computerenhance.com/p/q-and-a-26-2023-09-11)

### Inferences
- The kernel-design reading of the talk is closer to "exokernel plus standardised hardware" than "no OS": if devices have stable, primitive, documented interfaces, the kernel's job shrinks to secure multiplexing, and the 30M lines become unnecessary rather than relocated. Bromage (below) makes this exokernel connection explicitly.
- Muratori's argument is primarily economic/structural (who can afford to enter the OS market), not a kernel architecture; it gives a design target (bootable by a small team, small hardware support matrix) rather than mechanisms.
- The refterm and page-fault material supply the measurable version of the complaint: costs imposed by OS mechanisms (console host IPC, demand-zero faulting at 4 KB granularity) that an application cannot opt out of. A new kernel could expose pre-faulted or large-page mappings and bulk, low-copy pipes as first-class options.

### Gaps
- I could not access a transcript of the talk, so "booting directly to applications" and the exact line-count breakdown are confirmed only via the secondary summaries above (Amiga boot disks, 30/55M figures), not from Muratori's words.
- "The OS as a library": I found no primary source in which Muratori uses this phrase. UNVERIFIED attribution; do not quote it as his.
- UNVERIFIED from memory, not fetched this session: "The Worst API Ever Made" (his critique of Windows ETW; I believe it is caseymuratori.com/blog_0025, 2014); a standalone talk "Where Does Bad Code Come From?" (Molly Rocket YouTube, circa 2021); "Clean Code, Horrible Performance" (computerenhance.com, Feb 2023; about virtual dispatch and code organisation, not OS). Titles are real to my knowledge but URLs/dates need checking, and none is an OS-design text.
- No evidence found of a Muratori talk specifically on OS design at BSC 2025 or 2026.
- Syscall-cost numbers from Computer Enhance: none retrievable (paywall).

## 2. OS projects from or admired by the Handmade community, and their kernel choices

### Takeaway
The community's actual OS output is small and mostly solo: Essence (nakst, a conventional but from-scratch desktop kernel with the window manager in-kernel), Serenum (Sam H. Smith, hardware and OS sold together as an explicit answer to the Thirty Million Line Problem), the dormant Homebrew OS (Bromage, exokernel-leaning), and Orca (Fouilleul, a sandboxed WebAssembly app runtime that sidesteps the kernel entirely). Ryan Fleury supplies the essay-level argument (hardware complexity kills OS competition; the browser won because the OS failed at sandboxing and distribution) rather than a kernel.

### Cited Findings

Essence (nakst)
- "An operating system I've been writing since ~June 2017"; long-shot goal of replacing Linux and Windows on the desktop; source at https://gitlab.com/nakst/essence — [essence.handmade.network](https://essence.handmade.network)
- Kernel feature list from the README: "Filesystem independent cache manager"; "Memory manager with shared memory, memory-mapped files and multithreaded paging zeroing and working set balancing"; "Networking stack for TCP/IP"; "Scheduler with multiple priority levels and priority inversion"; "On-demand module loading"; "Virtual filesystem"; "Window manager" (listed under the kernel); "Optional POSIX subsystem, capable of running GCC and some Busybox tools"; custom UI library on the desktop side — [Essence README](https://gitlab.com/nakst/essence/-/raw/master/README.md)
- nakst on the OSDev forum: "The kernel and all of userland are built freestanding, without libc" (musl is used only for the hosted toolchain) — [OSDev forum](https://f.osdev.org/viewtopic.php?p=320616)
- Status: a 2023 Korean digest of an HN discussion says development appeared to have slowed or stopped as of April 2022 (secondary; current status unconfirmed) — [news.hada.io](https://news.hada.io/topic?id=11088)

Serenum (Sam H. Smith)
- Described as "a completely distinct computing platform", "Hardware and Operating System sold together", and "Serenum is my solution to the 'Thirty Million Line Problem'." Release 7 (posted 2024-10-10) added Wi-Fi support after about four months of work. Project site: samhsmith.com/serenum/ — [handmade.network/p/474/serenum](https://handmade.network/p/474/serenum/)
- Smith has also posted about why explicit allocators lead to language-design problems and about internet transport design (search-result summary of his Handmade Network feed; not read in full) — [handmade.network/m/samhsmith](https://handmade.network/m/samhsmith)
- Ryan Fleury recorded a conversation with Sam Smith (reported as Nov 2025, "Desktop Abstraction and OS Design") on user-space OS concepts, applying lessons from the RAD Debugger's visualisation engine (found only as a search-result description; video not located or verified) — [Digital Grove archive](https://www.rfleury.com/archive)

Homebrew OS (Andrew Bromage) and its response to the talk (2018-05-13)
- Project is on hiatus; "Integrating ACPICA is one of the reasons why Homebrew OS is on hiatus." — [Homebrew OS blog](https://handmade.network/p/14/homebrew-os/blog/p/3137-the_thirty-million_line_problem)
- Design ideas he draws from the talk: exokernels "eliminate the notion that an operating system should provide abstractions on which applications are built" (securely multiplex raw hardware, let libraries build abstractions); but RAM, disks and NICs still need sharing abstractions so the real question is the right abstraction level; cites Flask-style nested VMs for security without losing straight-line performance; OS research on structure largely stopped about 15 years earlier — [Homebrew OS blog](https://handmade.network/p/14/homebrew-os/blog/p/3137-the_thirty-million_line_problem)

Orca (Martin Fouilleul; Handmade Network project)
- "A development platform and runtime environment for cross-platform, sandboxed graphical WebAssembly applications"; WebAssembly modules as the portable program representation, bundled with Orca's own runtime into self-contained apps per host OS; presented at Handmade Seattle 2023 as "WebAssembly apps without the Web"; early versions used the wasm3 interpreter with C as the only officially supported language — [handmadecities.com/media/seattle-2023/orca](https://handmadecities.com/media/seattle-2023/orca/); [Orca repo](https://git.handmade.network/hmn/orca/src/branch/main/doc/QuickStart.md)
- Motivation text (via search-result excerpt of orca.handmade.network; the site redirected when fetched): operating systems "that could seamlessly download applications using a cross-platform format, and run them in a truly sandboxed way" would be a better model than the web; Orca is a launcher/runtime toward that, not an OS — [orca.handmade.network](https://orca.handmade.network)

Ryan Fleury (essays; no kernel)
- "Computers, Ownership, Agency" (2022-07-04): "the success of the browser is due to the failure of the operating system" (dominant OSes failed at simple sandboxed execution and easy software delivery); core OS components "have not become drastically more sophisticated than they were a few decades ago"; what changed is "the set of hardware combinations that a consumer operating system is required to support", so "driver software has become a necessity"; hardware interfaces "act more like protocols"; "The lack of competition in operating systems is because of complexity in the hardware domain"; complexity "is what disqualifies small, innovative teams"; he wants a world where writing an OS is "very easy, instead of very hard" on hardware that is "mostly fixed in-place" — [dgtlgrove.com](https://www.dgtlgrove.com/p/computers-ownership-agency)
- "The Digital Grove Project" (2023-06-07): media + community + codebase to build "an alternative computing foundation" (freedom, simplicity, performance, privacy, ownership); criticises the culture in which "Building a new operating system, a new code generator, or even a custom file format, or even a file format parser is nuts." — [dgtlgrove.com](https://www.dgtlgrove.com/p/the-hidden-grove-project)
- Fleury on distribution (X post): "imagine a web-style distribution model, but for regular native programs ... You just type a name, whether you've previously installed it or not, and then go." — [x.com/rfleury](https://x.com/rfleury/status/1961197875884683701)
- Fleury is lead developer of the RAD Debugger (Epic Games); he has posted about porting it to Linux and blames incoherent platform design for the weak Linux desktop (search-result description) — [x.com/rfleury](https://x.com/rfleury/status/2086251138035396680)

SerenityOS (admired/adjacent; not a Handmade project)
- Andreas Kling's project builds kernel, libc, GUI, browser from scratch in one repository with no third-party runtime dependencies; Kling credits this for the "strong feeling of cohesion within the codebase"; architecturally it is a conventional Unix-like — [The New Stack](https://thenewstack.io/building-an-operating-system-from-scratch-serenityos/); [SerenityOS README](https://cdn.jsdelivr.net/gh/SerenityOS/serenity@master/README.md)

Abner Coimbre
- Founder of Handmade Network and Handmade Cities/Handmade Seattle; worked under Jonathan Blow and then at Cyan Worlds; the Handmade Manifesto was written by Andrew Chronister, not Coimbre; his current project is Terminal Click, a cross-platform terminal emulator. No OS or kernel project by him was found — [Cyan Worlds post](https://cyan.com/2022/04/13/some-sad-happy-news-to-share/); [Handmade Network about text](https://git.handmade.network/hmn/hmn/raw/commit/48dfb6199796462b5fd6d7a30936ca5e332da5a5/oldstaticpages/about.txt)

### Inferences
- Every Handmade-sphere OS effort that got far either accepted a conventional monolithic design and a single reference target (Essence: emulator-first builds; Serenum: own hardware) or avoided the kernel (Orca). None demonstrated the driverless-hardware thesis on commodity PCs; Homebrew OS stalling on ACPICA is a concrete data point for Muratori's diagnosis.
- Serenum is the most literal implementation of the thesis: fix the hardware so the support matrix has one entry. That is also the conclusion of the critics (Apple M-series, Raspberry Pi) in section 5.
- Fleury's and Fouilleul's shared requirement for a new OS is at the application-model layer: named, instantly runnable, sandboxed native programs. A new kernel aimed at this audience needs capability-style sandboxing and install-free execution as primitives, not as a browser on top.
- Essence putting the window manager in the kernel and making POSIX an optional subsystem matches the sphere's general stance: desktop latency and API coherence over Unix compatibility.

### Gaps
- "Dawn": I found no Handmade-sphere OS project by that name tied to Coimbre or Fouilleul; search hits were an unrelated SUBLEQ "Dawn OS" by Geri. Treat the "Dawn" attribution in the brief as unconfirmed.
- No single canonical "Handmade OS" discussion thread was located.
- No Fleury essay that specifies a hypothetical kernel or file system was found; his OS views are in the 2022 essay, X posts, and the unverified Sam Smith video.
- Essence's syscall/API design (handles, message-passing between desktop and apps) was not retrievable from the README; the GitLab source would need reading.
- Serenum's kernel architecture, CPU target and language are not described on its Handmade Network page; samhsmith.com/serenum was not fetched.
- Mike Acton: no OS/kernel-specific statements found this session (his relevance is data-oriented design generally, which I did not research further).

## 3. Blow and Muratori (or others) conversations on OS design and complexity

### Takeaway
I found no primary source of a Blow-Muratori conversation specifically about designing a new OS; their recorded joint material located this session is about C++, language design and game design. The OS-relevant arguments in the adjacent sphere are in Muratori's solo talk, Fleury's essay, and interviews.

### Cited Findings
- Blow hosts a podcast on which Muratori has appeared more than once; the May 2024 episode is about game design ("The podcast is back, with Casey Muratori once again, and we talk about game design") — [x.com/Jonathan_Blow](https://x.com/Jonathan_Blow/status/1791849255893639454); a "Braidcast" episode "Getting the Game Going - Casey Muratori Part 2" also exists — [rss.com/podcasts/braidcast](https://rss.com/podcasts/braidcast/1462848/)
- Blow promoted Muratori's BSC 2025 talk "The Big OOPs" — [x.com/Jonathan_Blow](https://x.com/Jonathan_Blow/status/1945912418908955097)
- A third-party essay groups Blow's and Muratori's complexity arguments and describes the Thirty Million Line Problem as software growing larger than can be comprehended — [macoy.me](https://macoy.me/blog/programming/SoftwareComplexitySolutions)
- Muratori on a 2024-25 podcast (Backend Banter #056, "Maybe Programmers are Just Bad") revisits the "30 million line problem" at about 57:03 and discusses ARM vs x86 at 43:43 (episode index only; transcript not read) — [metacast.app](https://metacast.app/podcast/backend-banter/uTs5S40g/056---maybe-programmers-are-just-bad-feat-casey-muratori/Wpsmo0bW)

### Inferences
- The "why can't we just write a new OS" answer in this sphere is consistent across Muratori and Fleury: the kernel proper is tractable; the hardware support matrix and vendor driver economics are not.

### Gaps
- No transcript-backed Blow-Muratori exchange about OS design was found. If one exists (e.g. in Blow's stream Q&As or older Handmade Hero / HandmadeCon chats), it was not surfaced by search.
- HandmadeCon-era fireside chats (2015-2016) were not searched individually.

## 4. Odin / Zig / Jai allocator ideas relevant to kernel API design

### Takeaway
The shared doctrine is that allocation is a property of lifetime groups, not of individual objects, and that whoever calls an API should choose where its results live: Fleury's arena-parameter convention, Odin's implicit `context.allocator`/`context.temp_allocator`, and Zig's explicit `Allocator` (now mirrored by an explicit `Io`) parameter are three encodings of the same rule. Transposed to a kernel boundary, this argues for syscalls that write into caller-supplied memory, never allocate hidden per-call kernel state the caller cannot bound, and expose reserve/commit of address space as a cheap primitive.

### Cited Findings

Ryan Fleury, "Untangling Lifetimes: The Arena Allocator" (2022-09-23)
- An arena is "a handle to which allocations are bound"; allocations are freed together by pop/clear/release, not individually — [dgtlgrove.com](https://www.dgtlgrove.com/p/untangling-lifetimes-the-arena-allocator)
- Functions that allocate take an `Arena*`: "the caller must choose an arena, and thus determine the lifetime of any persistent allocations" — same source
- Thread-local scratch arenas with `ArenaTempBegin/End`; `GetScratch` must be told which arenas are in use for persistent results so temporaries and results never alias; two scratch arenas per thread suffice for arbitrarily deep call stacks — same source
- Growth strategy: "reserve a massive upper-bound of contiguous virtual address space, then commit physical pages as needed" (`VirtualAlloc`; about 48 bits of address space on PCs, about 38 on Nintendo Switch) — same source
- He calls the OS "the ultimate garbage collector", since process exit reclaims all pages — same source

gingerBill, "Memory Allocation Strategies, Part 1" (2019-02-01)
- Each allocation has a size, a lifetime and a usage pattern; his estimate is that about 95% of allocations have known size and known lifetime, about 4% unknown size/known lifetime, about 1% known size/unknown lifetime, under 1% unknown in both — [gingerbill.org](https://www.gingerbill.org/article/2019/02/01/memory-allocation-strategies-001/)
- Lifetime generations: permanent, transient (per frame/cycle), scratch; memory in a generation is allocated and freed together — same source
- Rejects the stack/heap dichotomy for a monistic "everything is virtual memory" view; "You know much more about your program than the compiler could ever know."; ownership semantics focus on single objects rather than whole systems — same source

Odin's context system (documentation and community sources; not gingerBill's own text)
- Every Odin procedure receives an implicit `context` carrying `context.allocator` (general heap) and `context.temp_allocator` (a growable arena never cleared automatically; the program calls `free_all(context.temp_allocator)` at a point it chooses, e.g. per frame) — [package core:mem](https://pkg.odin-lang.org/core/mem); [engineered.at](https://engineered.at/articles/understand-the-temporary-allocator-understand-arenas)
- Failure mode: core library procedures use the temp allocator implicitly; a user who set `context.temp_allocator` to a panicking allocator found logging broke — [Odin forum](https://forum.odin-lang.org/t/temporary-allocators-and-the-core-library/944)

Zig (Andrew Kelley)
- "Zig's New Async I/O" (text version; std.Io patchset landed 2025-10-29, previewing 0.16): "Setting up a `std.Io` implementation is a lot like setting up an allocator"; reusable code takes an `Allocator` if it allocates and an `Io` if it does I/O, both as explicit parameters created once in `main()` — [andrewkelley.me](https://andrewkelley.me/post/zig-new-async-io-text-version.html)
- Implementations are swappable behind the interface: `std.Io.Threaded` (blocking threads) is the reference; io_uring and kqueue proof-of-concepts use stackful coroutines; stackless coroutines are future language work — same source
- Semantics split: `io.async` expresses asynchrony (implementation may run it inline), `io.concurrent` demands real concurrency and can fail with `error.ConcurrencyUnavailable`; "we needed concurrency, but we asked for asynchrony" — same source
- Cancellation is part of the interface: `cancel` is `await` plus a cancellation request, idempotent, and "the conditions under which cancellation requests are honored are defined by each I/O implementation" — same source
- Zig 0.16 shipped in spring 2026 with Io as an interface (secondary news source) — [machineherald](https://machineherald-io.pages.dev/article/2026-05/20-zig-0160-ships-io-as-an-interface-rewrites-type-resolution-and-lands-incremental-compilation)

Dissent inside the sphere
- Sam H. Smith (Serenum) has argued that explicit allocators lead to language-design problems (search-result description of his post; argument not read) — [handmade.network/m/samhsmith](https://handmade.network/m/samhsmith)

### Inferences
- Syscall design consequences: (a) every syscall that returns variable-size data should take a caller buffer/arena plus a length and report required size, never hand back kernel-allocated memory with a separate free call; (b) kernel object creation should let the caller donate the backing memory (in the style of seL4 untyped retype or Zircon-style quotas), so the "who pays and for how long" question has the same answer as in an arena API; (c) the kernel should export cheap reserve/commit/decommit of large virtual ranges and a pre-fault/large-page option, because arena-style user code depends on them and the default 4 KB demand-zero fault is the cost Muratori measures.
- Odin's implicit context shows the hazard of ambient allocators (hidden uses by callee libraries); Zig's explicit parameter avoids it at the cost of verbosity. For a kernel ABI, explicit is the only option that survives across language boundaries.
- Zig's `Io` design suggests treating the I/O backend, with its cancellation and concurrency-availability semantics, as a first-class, replaceable capability. A kernel could expose one completion-based I/O primitive with well-defined cancellation and let blocking-thread and event-loop models be user-space policy.
- gingerBill's permanent/transient/scratch generations map onto kernel object lifetimes: boot-lifetime, per-process, per-syscall/per-request, suggesting per-process arenas freed wholesale at exit instead of per-object teardown.

### Gaps
- Jai's `context.allocator` and temporary storage: excluded as Blow's own material (covered by another researcher); nothing fetched here.
- gingerBill statements specifically about OS/kernel APIs were not found; his later posts in the allocation series (arena/stack/pool, virtual memory) were not fetched.
- Andrew Kelley's wording "no hidden allocations" is a Zig project slogan to my knowledge, but I did not fetch a primary page stating it this session. UNVERIFIED.
- None of these authors was found discussing syscall design directly; the kernel mapping above is inference.

## 5. Best-known rebuttals to the Thirty Million Line Problem

### Takeaway
The rebuttals converge on four points: the line count is misleading because most of it is drivers that are never loaded on a given machine; drivers exist for real reasons (resource arbitration, vendors' performance work, closed IP as competitive lock-in); a fixed hardware ISA works for mature devices (storage, HID) but breaks on accelerators and novel hardware; and standardisation is a coordination/economics problem, not a technical one. Even sympathetic critics conclude the realistic form of the idea is a vertically fixed platform (Raspberry Pi, Apple M-series).

### Cited Findings
- Line-count objection: much of Linux's code is drivers "which are likely not even loaded"; "These systems are this complex because there is demand for them to be." — zamalek, [HN 21366555](https://news.ycombinator.com/item?id=21366555)
- Leaky-abstraction objection: a hardware ISA "is just kicking the can down the road" and would not accommodate novel hardware (ML accelerators, quantum coprocessors) — zamalek, same thread
- Coordination objection: an ISA alone is insufficient; you still need OS ABIs, wire protocols and network protocols; existing abstractions embody "untold millions of dev-hours" and getting organisations to agree is the hard part — kortex, same thread
- Supportive data from the same thread: Android ROMs must be built per phone model because ARM platforms lack a BIOS-like generalising layer (sp332); "There are millions of untestable lines of driver code which may or may not be run" (smadge) — same thread
- Hardware-diversity objection: "90% is drivers for millions of hardware SKUs" and the 1980s-90s world lacked that variety, so shipping was inherently simpler; "OS is not a problem." (HN comment via mirror; search-result excerpt) — [HN mirror](https://qwik-hackernews.ryansolid.workers.dev/stories/42007373)
- Consumer-viewpoint objection (ForwardCom forum, 2018-05-14): the proposal looks at the problem "from a pure consumer point of view"; an SoC-wide ISA either wastes encoding space on systems lacking components or makes large parts optional; it trades flexibility (e.g. external GPUs) for simplicity; state now managed by drivers must move into hardware; per-component ISAs leave the glue problem and need open architectures (no open GPU architecture exists); drivers arbitrate hardware between competing programs; vendors keep architectures closed as lock-in (x86, CUDA) — Kulasko, [ForwardCom forum](https://www.forwardcom.info/forum/viewtopic.php?t=89)
- Essential-vs-incidental objection (arrdem, 2021-04-27): agrees hardware is the problem but asks whether the complexity is essential; standardisation suits stable technology (storage, HID already have standard interfaces); accelerators must expose hardware-specific capability to deliver performance, so durable abstractions are hard; HALs are a faulty compromise ("'transparent' abstraction is really no abstraction whatsoever"); best realistic option is an industry-standard interface per accelerator model; Raspberry Pi and Apple's small support matrix (M1) approximate what Muratori wants — [arrdem.com](https://www.arrdem.com/2021/04/27/thirty_million/)
- OS-developer qualification (Bromage, 2018-05-13): Linux's 17M lines include hardware he never uses; most Windows 95/98 blue screens came from third-party drivers rather than the OS (which supports Muratori's diagnosis but locates the fault in vendors, not OS design); smart peripherals with their own CPUs are old (Commodore 1541) and compatible with standard buses; raw-hardware multiplexing still needs abstraction for security, so it "tends to become a modern OS" — [Homebrew OS blog](https://handmade.network/p/14/homebrew-os/blog/p/3137-the_thirty-million_line_problem)
- GPU-driver objection (Medium post by "fulalas"; page returned 403, so this is from a search-result excerpt only): most of the lines are not compiled in a given environment; asks whether Muratori really thinks Nvidia and AMD add driver overhead "just for fun", arguing driver bulk is performance-specific code paths — [medium.com/@fulalas](https://medium.com/@fulalas/i-just-watched-the-thirty-million-line-problem-87ccb2b245bf)
- Scale datum often cited on both sides: the AMD GPU kernel driver alone has passed six million lines (Reddit snapshot, 2026; secondary) — [reddit snapshot](https://reddit.sentinel-team.org/posts/1rwwqko/snapshots/2026-03-20T16%3A10%3A43.025975Z)
- Muratori's own concession: a stable ISA is more expensive for vendors than shipping patched drivers — [caseymuratori.com/blog_0031](https://caseymuratori.com/blog_0031)

### Inferences
- The strongest rebuttal for a kernel designer is the accelerator one: GPUs/NPUs are where both the performance and the line count are, and they are exactly where a frozen interface costs the most. A new kernel can plausibly go driverless-simple for storage (NVMe), HID, serial, and virtio-class NICs, and must treat GPU as a separate problem (e.g. user-space drivers behind a narrow kernel mediation interface).
- "Not loaded" does not fully answer Muratori: unloaded code still has to be written, reviewed and trusted by whoever wants to ship a competing OS, which is his barrier-to-entry point. The two sides are measuring different costs (runtime complexity vs. cost of entry).
- The realistic deployment path both camps implicitly agree on is a fixed reference platform: virtio/QEMU, one SoC board, or own hardware (Serenum's choice).

### Gaps
- No formal, widely cited long-form rebuttal by a kernel maintainer or hardware vendor was found; the rebuttals are forum comments and personal blogs.
- I did not find a direct reply from Muratori to these critiques.
- The original 2018 HN thread for the talk was not located (the one fetched is the 2019 resubmission, item 21366555).
