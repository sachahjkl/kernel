# Jonathan Blow: statements from the transcripts that were not read before

Status: research note, 2026-11-09. Sources are automatic captions; verify against the video before an exact quotation.

## Scope and method

- A transcript is "already read" if its video id occurs in `blow_verified_statements.md`.
- That rule gives 15 transcripts already read and 21 unread. The task text said 19; the count by the rule is 21.
- All 21 unread transcripts were read completely.
- Reference format: `[video id mm:ss]`, as in `blow_verified_statements.md`.
- A timestamp is the caption block that contains the statement. A caption block is about one minute long.
- "Quotation" marks text where the caption is unambiguous. All other items are paraphrases.
- The captions do not name the speaker. Where a second speaker or a chat message is possible, the item says so.
- `LKwG0WJfHZY` is a one-minute extract of `W5s965qdmyU`. It adds no statement.

The 21 unread transcripts:

| Video id | Title | Uploaded |
|---|---|---|
| `W5s965qdmyU` | on Windows Terminal | 2019-06-29 |
| `unx3WCWZwUc` | on Apple's M1 Processor | 2020-12-04 |
| `fEn2HPGXwj8` | Technology Automatically Degrades | 2022-07-18 |
| `2pJtqDgWXys` | Writing Everything from Scratch | 2022-08-08 |
| `6jaVyckxjsA` | Abstraction Layers in Programming | 2023-03-29 |
| `LKwG0WJfHZY` | on the Windows Terminal | 2023-11-21 |
| `GXa3wSPn8do` | on libc | 2023-11-25 |
| `M_6-A8iMeJM` | on Shipping to Linux | 2023-12-03 |
| `t63x3Tv4sEw` | on the Complexity of Linux | 2023-12-04 |
| `sb1T9205ZY8` | on What Went Wrong with Operating Systems | 2024-01-09 |
| `llK5tk0jiN8` | Windows is a trash fire but it's still the best we have | 2024-01-16 |
| `oiv4amBUf9Q` | on Docker | 2024-03-07 |
| `ogHl_OwcZWE` | on Global State in Programming | 2025-03-20 |
| `uzxV_RsL89g` | on why his stream sound (and Windows) sucks | 2026-01-09 |
| `AEO2OY1nPhI` | on Visual Studio and Windows | 2026-01-14 |
| `iLYJadO9FOA` | Jon gives homework to the Linux nerds | 2026-02-15 |
| `LmriR7AkpDA` | on why code size should be small | 2026-05-29 |
| `QXEAQQueYkk` | on how Windows bricked his laptop | 2026-07-10 |
| `NNlrLNv9byI` | on the GPUs that lie about DirectX 12 | 2026-08-29 |
| `zZUnt_XLgrk` | on two patterns every Windows programmer runs into | 2026-09-24 |
| `I3Q0cP49OTk` | on why Windows can't sleep properly | 2026-10-15 |

## Statements by topic

### A. Purpose and failure of operating systems

- Operating systems were invented to let a person run programs on the computer. [`sb1T9205ZY8` 01:00] Tag: purpose.
- Quotation: "it all comes down to the fact that operating systems have basically failed". He names web applications and Docker as results of that failure. [`sb1T9205ZY8` 00:00] Tag: purpose.
- A stock Linux distribution installs a large number of executables and runs many background processes, only to run one program. Quotation: "it doesn't make any sense". [`sb1T9205ZY8` 01:00] Tag: system size.
- People add more software because the system does not work without it. The added software has the same defects. [`sb1T9205ZY8` 02:00] Tag: complexity. The addressed person is "Casey"; the speaker of this block is probably Blow.
- The usual argument is that systems must be bad because people download things from the internet. He rejects it: Microsoft itself ships products that need a network connection and install with administrator access. [`sb1T9205ZY8` 00:00] Tag: security, installation.
- It is probably easier to make a new operating system and make it successful than to make Windows good. [`uzxV_RsL89g` 02:04] Tag: purpose.
- He wants to make a different operating system but has no time and no money. [`llK5tk0jiN8` 00:00, 04:02] Tag: own plans.
- 2022, to an interviewer who asks when his operating system will come out: "maybe soon and not too soon". The context is a joke about writing everything from scratch. [`2pJtqDgWXys` 00:00] Tag: own plans.

### B. Installation, packaging and program distribution

- In the 1990s, on Unix workstations, people copied programs between machines and ran them. The programs were mostly statically linked. If they were dynamically linked, the shared objects were compatible. [`oiv4amBUf9Q` 01:01] Tag: packaging, linking.
- Docker solves problems that the industry created in the 1990s and 2000s. He names "do you have the right DLLs" and the "file system view". These problems are not fundamental to computers. [`oiv4amBUf9Q` 00:01] Tag: packaging.
- Docker is a remedy stacked on bad ideas. Each layer is one more thing that people must deal with. [`oiv4amBUf9Q` 00:01] Tag: complexity.
- On Linux, a program does not run after installation because the kernel version or the glibc version is wrong. The person then installs hundreds of packages and it still does not work. [`sb1T9205ZY8` 01:00, 02:00] Tag: packaging. Caption reads "GBC"; glibc is the probable word. A second speaker is possible.
- A Windows setup program asks to close an unrelated background program ("Windows Phone IP over USB transport"). [`sb1T9205ZY8` 02:00] Tag: installation. The speaker is probably the second person, not Blow.
- Shipping Braid on Linux was "a disaster" and "a huge amount of effort". [`M_6-A8iMeJM` 00:00] Tag: Linux defect.
- The DirectX 12 Agility SDK lets a game use new DirectX 12 features with no operating system update. He says that this is what the DirectX redistributable did before. [`llK5tk0jiN8` 03:01, 04:02] Tag: packaging, graphics.

### C. Linking, loading and the C library

- On Linux, a shared library cannot have read-only data segments that contain addresses. The address patching happens in user space, so the segment must be writable. He asks the Linux developers to fix that. [`iLYJadO9FOA` 00:00] Tag: loading. He says "I forget exactly why" before the explanation.
- He calls this one of "10,000 things" on Linux that wasted his time. [`iLYJadO9FOA` 00:00] Tag: Linux defect.
- Asked how he would change glibc I/O and string management: he would use none of that code. Quotation: "I wouldn't use any of that code." He calls libc "the worst code in the history of anything". [`GXa3wSPn8do` 00:00] Tag: C library.

### D. Dependence of a program on the system

- Game programmers isolate the program from the system as much as possible. They use system interfaces "begrudgingly and minimalistically" and supply most functions themselves. [`oiv4amBUf9Q` 02:01] Tag: system interface.
- A program cannot be lean and precise if its author does not know the substrate that it runs on. [`oiv4amBUf9Q` 02:01] Tag: system interface.
- Text drawing is an example. The game carries its own text drawing code and its own font data. It does not ask the operating system for a font, because the result differs between machines. [`oiv4amBUf9Q` 03:03] Tag: graphics, robustness.
- Most of the industry treats programming as interoperation with the operating system and with many libraries. He says that robustness needs the opposite habit. [`oiv4amBUf9Q` 01:01, 03:03] Tag: complexity.

### E. Interface design and interface evolution (Windows API)

- The Win32 API is "terrible" for games. It is also better for games than the API of any other operating system, and "much much better than Linux". [`llK5tk0jiN8` 00:00, 01:01] Tag: API.
- Early Windows kept backward compatibility and still corrected things. The methods were a version 2 of a call, or a struct with a version number that enables features. He says that they "were very good about that for a while". [`llK5tk0jiN8` 01:01] Tag: API evolution.
- Now the old calls never improve. The one exception is UTF-8 support, which affects most functions. Microsoft adds new interfaces in place of corrections. [`llK5tk0jiN8` 01:01] Tag: API evolution.
- To learn which DirectX 12 version and features are present, a program needs a separate library with a separate API (the Agility SDK). No earlier DirectX version needed that. [`llK5tk0jiN8` 02:01, 03:01] Tag: graphics API.
- Windows pattern 1: call the function with a null pointer to learn the necessary size. Allocate that memory. Call again with the pointer and the size. The second call is guaranteed to give the data. [`zZUnt_XLgrk` 00:00] Tag: API, memory.
- Windows pattern 2: a struct carries its own size in a field (`cbSize`). This lets a data structure grow over time with no break of the API. [`zZUnt_XLgrk` 01:00] Tag: API evolution.
- In the raw input device information call, the size value is an input for one purpose and an output for another purpose. He calls this "pretty messy" and confusing. [`zZUnt_XLgrk` 01:00] Tag: API. The function is probably `GetRawInputDeviceInfo`; the caption reads "rid device info".
- When the size field is wrong, the function must return an error. Quotation: "They should error on this." [`zZUnt_XLgrk` 01:00] Tag: API.

### F. Time, sleep and threads

- A viewer proposes to poll input on a background thread and make a queue of events. He answers that this is "not a terrible idea". [`I3Q0cP49OTk` 00:00] Tag: threads, input.
- On Windows a program cannot poll at a high frequency with no CPU burn, because the sleep call is not accurate. [`I3Q0cP49OTk` 00:00] Tag: timer.
- The usual method: sleep for less than the wanted time, read the clock, sleep again if it is early, then spin with a pause instruction until the time. [`I3Q0cP49OTk` 00:00, 01:00] Tag: timer. Caption reads "MM wait"; `_mm_pause` is the probable word.
- For his own operating system: "I would give you a way to sleep with relatively guaranteed bounds on wake up time", with an accuracy better than 1 millisecond. [`I3Q0cP49OTk` 01:00] Tag: timer. Quotation.
- Quotation: "A millisecond is just an incredible amount of time on a modern computer." [`I3Q0cP49OTk` 01:00] Tag: timer.
- The method needs `timeBeginPeriod(1)` (caption: "time set period"). This call sets a global value that was system-wide. He thinks that it is still system-wide. [`I3Q0cP49OTk` 02:02] Tag: global state.
- The call changes the interrupt timer and drains the battery of the whole computer. Another program can change the value back and break the sleep again. [`I3Q0cP49OTk` 02:02] Tag: global state.
- A viewer cites `CreateWaitableTimerExW` with the high resolution flag, on Windows 10 and later. He answers that a program must then keep both code paths. The old path gets less testing, breaks, and causes support calls. [`I3Q0cP49OTk` 03:03] Tag: API evolution.
- The Visual Studio profiler shows "less than or equal to 1 millisecond" as its smallest time. [`I3Q0cP49OTk` 02:02] Tag: tools.
- No unread transcript states a thread model, a scheduler design or a program start model.

### G. Global state that one program changes for all programs

- Windows changes his microphone or stream volume with no action from him. [`uzxV_RsL89g` 00:00] Tag: Windows defect, sound.
- A viewer says that an application such as Google Hangouts or Skype was the cause. He answers that a user program must not be able to change the global microphone volume in a way that affects other programs. [`uzxV_RsL89g` 01:02] Tag: isolation.
- He says that preventing this is one of the things that an operating system is for. Quotation: "It's one of the things it's supposed to prevent." [`uzxV_RsL89g` 01:02] Tag: isolation.
- The system-wide timer period of section F is a second case of the same defect. [`I3Q0cP49OTk` 02:02] Tag: isolation.

### H. Graphics APIs and GPU drivers

- His game needs a GPU that supports DirectX 12. He dates such GPUs to 10 or 12 years ago. [`NNlrLNv9byI` 00:00] Tag: graphics.
- "DirectX 12 feature level 11" names a DirectX 11 GPU. Vendors called such GPUs "DirectX 12" through driver compatibility, so that the GPUs were not seen as obsolete. [`NNlrLNv9byI` 00:00, 01:01] Tag: GPU drivers.
- He thinks that feature level 11 does not run his game, although the GPU claims DirectX 12. [`NNlrLNv9byI` 01:01] Tag: GPU drivers.
- On PC a program can never run on 100% of the systems. [`NNlrLNv9byI` 01:01] Tag: hardware variety.
- The game runs well on Steam Deck. [`NNlrLNv9byI` 01:01] Tag: hardware.
- An Intel embedded GPU gives his game a lower frame rate than a discrete laptop GPU, before shader optimization. [`QXEAQQueYkk` 00:00] Tag: hardware.

### I. Console and text interface

- The command prompts of today are "the same program" that he used in 1990, but slower. The 1990 consoles ran under X on 1990 workstations. [`W5s965qdmyU` 01:00, 02:02] Tag: console. Caption reads "ex windows under x10"; the X version is an unclear caption.
- A console is a program where the person types text and text is printed back. He says that 50 people can each write one in a weekend. It must not need a large team and years of work. [`W5s965qdmyU` 00:00, 01:00, 03:03] Tag: console, complexity.
- Requirements that he states: print the text in a reasonable time, and handle a program that outputs a lot of text with smooth scrolling. [`W5s965qdmyU` 03:03] Tag: console, performance.
- He measures current consoles at about 100 milliseconds per line of program output. [`W5s965qdmyU` 06:12] Tag: console, performance.
- A game renders a 3D scene at 60 frames per second or more. Its text chat is a console that is a very small part of the game. No console on a modern operating system is that fast. [`W5s965qdmyU` 04:04, 05:09] Tag: console, performance.
- The Microsoft console is bad. The third-party console that he uses is better and still bad. The worst part is that nobody thinks that this is bad. [`W5s965qdmyU` 02:02] Tag: console.
- No unread transcript discusses command line arguments, text pipes or a shell language.

### J. Build and debugging tools

- He says that the Windows operating system team did not use Visual Studio to debug. They used WinDbg (caption: "windbag"). This was true about 10 years after the release of Visual Studio. [`AEO2OY1nPhI` 03:02] Tag: debugging.
- He guesses that the same team compiles with shell scripts and not with Visual Studio. This is a guess, marked "probably". [`AEO2OY1nPhI` 03:02] Tag: build tools.
- A chat message from a person "who works on Windows" says that most people there still use WinDbg. This is a chat message that he reads, not his statement. [`AEO2OY1nPhI` 04:02] Tag: debugging.
- Visual Studio reformatted the pointer stars in his code to its default style without a request. [`AEO2OY1nPhI` 00:01] Tag: tools.
- A default must suit people who know how to program and want correct programs. [`AEO2OY1nPhI` 01:02, 02:02] Tag: tools, defaults.

### K. Settings, updates, accounts and activation (Windows defects)

- An update of Visual Studio resets the changed settings. A reinstall of Windows resets them also. He has 17 computers. [`AEO2OY1nPhI` 02:02] Tag: settings.
- Windows now preloads Windows Explorer. He gives it as an example of the same attitude as the bad defaults. [`AEO2OY1nPhI` 01:02] Tag: Windows defect.
- A press on the Copilot key of his laptop opened a window that loaded for a long time. [`AEO2OY1nPhI` 01:02] Tag: Windows defect.
- Teams is installed locally with Windows and also runs in the browser. He started the local version, went back to the browser version, and then neither worked. [`AEO2OY1nPhI` 05:03] Tag: Windows defect.
- He reinstalled Windows from the image on the drive of the laptop. Windows then refused activation: the installed edition (Pro N) did not match the key stored in the device. [`QXEAQQueYkk` 00:00, 01:00] Tag: activation.
- The purchase links in Windows and in the Windows Store led to help pages. He found no way to buy a key from Microsoft. He bought a key from a reseller for 39 dollars and it worked. [`QXEAQQueYkk` 01:00, 02:01] Tag: activation.
- The Store made him sign in to his Microsoft account. That tied the Windows login to the account. After the restart, the laptop required a network login to the Microsoft account. [`QXEAQQueYkk` 02:01] Tag: accounts.
- The café Wi-Fi needs a web browser to accept its terms. Windows disabled that option before the account login. The laptop was not usable. [`QXEAQQueYkk` 03:02] Tag: accounts, network.
- He recovered with a connection through his phone. He says that a non-technical person, or a person with no phone reception, had no way to use the computer. [`QXEAQQueYkk` 03:02] Tag: accounts.
- Quotation: "Windows does not respect the user anymore". He wants an operating system that respects the user. [`t63x3Tv4sEw` 00:00] Tag: purpose.
- Microsoft shows no sign that it sees its changes to Windows as a mistake. He expects Windows to get worse. [`llK5tk0jiN8` 00:00] Tag: Windows defect.

### L. Linux

- He would leave Windows for a Linux distribution on which he can be productive. Linux is "not that usable". [`t63x3Tv4sEw` 00:00] Tag: Linux defect.
- Quotation: "Linux is just too complicated. If they would get rid of all the complexity it would be so much better than every other option." [`t63x3Tv4sEw` 00:00] Tag: complexity.
- See also sections B and C for packaging and loader defects.

### M. Performance of software

- CPU speed does not matter for most uses, because programmers make software slower by orders of magnitude than the hardware permits. [`unx3WCWZwUc` 00:00] Tag: performance.
- A computer can be at least 100 times faster with different software. He compares this to the 40% gain that he cites for the Apple M1. [`unx3WCWZwUc` 00:00, 01:02] Tag: performance.
- The slow software is not a trade for productivity, because the programmers are not productive either. [`unx3WCWZwUc` 00:00] Tag: performance.
- The fast software does not exist for download. Someone must write it. [`unx3WCWZwUc` 02:08] Tag: performance.

### N. Software complexity

- An abstraction layer never abstracts perfectly and never couples tightly to the layers above and below. It always adds "slop". [`6jaVyckxjsA` 00:03] Tag: complexity.
- An abstraction layer is code. It takes time to compile, time to run, and time to understand. [`6jaVyckxjsA` 01:06] Tag: complexity.
- He wants code to be judged as a material: each addition adds weight. The penalty is less than the rocket equation but larger than people admit. [`6jaVyckxjsA` 01:06, 02:06] Tag: complexity.
- A system changes in kind when no single person can understand all of it. Then nobody sees both causes of a problem. [`6jaVyckxjsA` 02:06, 03:08] Tag: complexity. This passage is probably the interviewer. Blow answers "absolutely".
- Quality goes down as soon as a team grows from one person to two. The cost of coordination is paid in quality of understanding, not only in time. [`6jaVyckxjsA` 03:08, 04:09] Tag: complexity.
- A large code base grows more as it grows, because understanding goes down and people then implement by adding. A clear picture is necessary to implement without adding. [`LmriR7AkpDA` 00:01] Tag: complexity.
- The other outcome: nobody understands the code, and it stops growing because progress stops. [`LmriR7AkpDA` 01:02] Tag: complexity.
- Keeping code small must be a priority for this reason. [`LmriR7AkpDA` 00:01, 01:02] Tag: complexity.
- Each problem has a natural amount of global mutable state. For a game it is large. Too much is messy; forcing it to zero also adds complexity. [`ogHl_OwcZWE` 00:03, 01:04] Tag: language, complexity. The subject is program design, not system design.
- Technology degrades when knowledge is not passed between generations. His examples are historical and one hardware case (Multiflow, logic chips). [`fEn2HPGXwj8` 05:19, 08:21] Tag: complexity. No statement about an operating system.

## 1. New relative to blow_verified_statements.md

1. Timer requirement. His operating system gives a sleep with bounded wake-up error, better than 1 millisecond. [`I3Q0cP49OTk` 01:00] This is the only concrete kernel feature in the unread transcripts.
2. A program must not change a global setting that affects other programs. Two cases: microphone volume and the system timer period. [`uzxV_RsL89g` 01:02] [`I3Q0cP49OTk` 02:02]
3. Loader defect to avoid. Address patching in user space forces data segments that contain addresses to be writable. [`iLYJadO9FOA` 00:00]
4. Interface evolution. He approves versioned calls, versioned structs and a size field in a struct. He rejects a size parameter with two meanings and a wrong size with no error. [`llK5tk0jiN8` 01:01] [`zZUnt_XLgrk` 01:00]
5. The two-call memory pattern: ask for the size, allocate in the caller, call again. He presents it as the standard and reliable Windows pattern. [`zZUnt_XLgrk` 00:00]
6. A second code path for a newer system version is a cost: the old path is tested less and breaks. [`I3Q0cP49OTk` 03:03]
7. Graphics feature discovery must not need a separate library with a separate API. [`llK5tk0jiN8` 02:01]
8. A capability name that a driver claims can be false ("DirectX 12 feature level 11"). [`NNlrLNv9byI` 00:00]
9. A program carries its own text drawing and font data to get the same result on every machine. [`oiv4amBUf9Q` 03:03]
10. The historical proof for "copy a program and run it": 1990s Unix workstations with mostly static linking. [`oiv4amBUf9Q` 01:01]
11. Console requirements: a small program, text shown in a reasonable time, smooth scroll of large output. The benchmark is a game at 60 frames per second. [`W5s965qdmyU` 03:03, 04:04]
12. Use of the machine must not depend on a network login to a vendor account, nor on activation. [`QXEAQQueYkk` 02:01, 03:02]
13. An update or a reinstall must not reset the settings of the person. [`AEO2OY1nPhI` 02:02]
14. Installation with administrator access is named as a cause of the security problem, not as a necessity. [`sb1T9205ZY8` 00:00]
15. He rejects libc completely, not in part. [`GXa3wSPn8do` 00:00]
16. The Windows team debugs with WinDbg, not Visual Studio. [`AEO2OY1nPhI` 03:02]
17. The claim that a new operating system is easier than a repair of Windows. [`uzxV_RsL89g` 02:04]
18. Size as a discipline: a code base that is not kept small grows without limit or stops. [`LmriR7AkpDA` 00:01]

Already recorded, with a new citation only:

- Too many executables and background processes. Recorded in §2 from OS-2020. New citation: [`sb1T9205ZY8` 01:00].
- Containers exist because the operating system fails to rerun a program. Recorded in §1 from STAG-2026. New citation: [`oiv4amBUf9Q` 00:01] [`sb1T9205ZY8` 00:00].
- Linux targets differ in C library and versions. Recorded in §9. New citation: [`sb1T9205ZY8` 01:00].
- No time and no money for his own operating system. Recorded in §13. New citation: [`llK5tk0jiN8` 04:02].

## 2. Supports or conflicts with PROPERTIES.md

No statement in the unread transcripts conflicts with a property. Properties 3, 5, 6, 9, 12 and 15 have no applicable statement.

| # | Property | Relation | Statement and citation |
|---|---|---|---|
| 1 | Small kernel, counted interface | Supports | One program must not need thousands of executables and many background processes. [`sb1T9205ZY8` 01:00] Linux without its complexity is better than every other option. [`t63x3Tv4sEw` 00:00] Size must be an explicit priority. [`LmriR7AkpDA` 00:01] |
| 2 | Sandbox by default | Supports | A program must not change the global microphone volume for other programs. [`uzxV_RsL89g` 01:02] |
| 4 | Non-blocking command buffers | Refines | The one wait operation needs a time limit with bounded wake-up error, better than 1 millisecond. [`I3Q0cP49OTk` 01:00] The timer resolution must not be a setting that a program changes. [`I3Q0cP49OTk` 02:02] |
| 4 | Non-blocking command buffers | Supports | Input as a queue of events filled off the main thread is "not a terrible idea". [`I3Q0cP49OTk` 00:00] |
| 7 | No drivers in the kernel, fixed hardware first | Supports | A program can never run on 100% of PC systems. [`NNlrLNv9byI` 01:01] A driver can claim an interface level that the hardware does not have. [`NNlrLNv9byI` 00:00] |
| 8 | No global, shared file system | Supports | The "file system view" is one of the invented problems that Docker remedies. [`oiv4amBUf9Q` 00:01] |
| 10 | One code module, position-independent | Supports | Linux patches addresses in user space, so segments must be writable. [`iLYJadO9FOA` 00:00] The glossary rule "no change to its bytes" removes this defect. |
| 10 | One code module | Refines | A module must be able to keep constant data that contains addresses in read-only memory. The loader design must state how. [`iLYJadO9FOA` 00:00] |
| 10 | One code module | Supports | Static linking made programs portable by copy. [`oiv4amBUf9Q` 01:01] No dependence on a system C library. [`GXa3wSPn8do` 00:00] [`sb1T9205ZY8` 01:00] |
| 11 | Reproducible system, content hash | Supports | Copy a program and run it. No container is necessary. [`oiv4amBUf9Q` 01:01] A wrong library version must not stop a program. [`sb1T9205ZY8` 01:00] |
| 11 | Reproducible system | Refines | A program brings the newer graphics runtime with it, with no system update (the redistributable model). [`llK5tk0jiN8` 04:02] |
| 13 | Data-oriented internals, ZII, record growth | Supports | A record that grows at the end, with a size or version known to the callee, keeps old callers valid. [`zZUnt_XLgrk` 01:00] [`llK5tk0jiN8` 01:01] |
| 13 | Record growth | Refines | A size value must have one meaning. A wrong size must give an error. [`zZUnt_XLgrk` 01:00] Rule 4 of ZII has no size field; the design must state how the callee detects a short or wrong record. |
| 13 | Record growth | Refines | Correct the old operation in place. Do not add a parallel new interface and leave the old one. [`llK5tk0jiN8` 01:01] |
| 14 | Memory supplied by the caller | Supports | The two-call pattern: the callee states the size, the caller allocates. [`zZUnt_XLgrk` 00:00] |
| 16 | Removed concepts | Supports | Installers with administrator access. [`sb1T9205ZY8` 00:00] Many background processes. [`sb1T9205ZY8` 01:00] System-wide mutable settings. [`I3Q0cP49OTk` 02:02] |
| 17 | Trusted boot | Refines | Boot and login must work with no network and no vendor account. Activation is not a concept of the system. [`QXEAQQueYkk` 02:01, 03:02] |
| 18 | One graphics interface | Supports | One interface, with no second library to discover features. [`llK5tk0jiN8` 02:01] No false capability levels. [`NNlrLNv9byI` 00:00] |
| 18 | One graphics interface | Refines | A program draws its own text with its own font data. The system gives a surface, not a text or widget layer that differs between machines. [`oiv4amBUf9Q` 03:03] |
| 18 | One graphics interface | Refines | Two feature paths for old and new systems cause an untested path. Fixed hardware and one feature set avoid it. [`I3Q0cP49OTk` 03:03] |
| 19 | A command is a function | Supports (console only) | The console is a small normal program. [`W5s965qdmyU` 01:00] |
| 19 | A command is a function | Refines | The console has a performance requirement: large output with no visible delay. He measured 100 milliseconds per line as unacceptable. [`W5s965qdmyU` 03:03, 06:12] The typed stream form of property 19 must meet it. |
| 19 | A command is a function | No statement | The unread transcripts say nothing on command line arguments, text pipes or shell languages. |
| 20 | No ambient access | Supports | Global microphone volume changed by one program. [`uzxV_RsL89g` 01:02] |
| 20 | No ambient access | Refines | A possible new line for the table: no system-wide mutable setting. A device setting (volume, timer period, power) is per program or behind a grant. [`I3Q0cP49OTk` 02:02] [`uzxV_RsL89g` 01:02] |
| 20 | No ambient access, line 15 | Supports | An installer with administrator access is a cause of insecurity. [`sb1T9205ZY8` 00:00] |
| 21 | Principals and sessions | Supports | A principal is a local key pair. The machine works with no remote account. [`QXEAQQueYkk` 02:01] |
| 21 | Principals and sessions | Refines | Settings belong to the principal. A system update or reinstall must not reset them. [`AEO2OY1nPhI` 02:02] Recovery of a key must not need a network that the locked machine cannot join. [`QXEAQQueYkk` 03:02] |

### The five subjects that the task names

- Threads and the execution model: one remark only. A background thread that polls and fills an event queue is acceptable. [`I3Q0cP49OTk` 00:00] There is no statement on a thread model or a scheduler. The timer requirement is the related finding.
- Command line arguments, text pipes and shells: no statement. The console statements concern speed and size only. [`W5s965qdmyU`]
- Drivers and graphics APIs: feature discovery through a second SDK, false DirectX 12 levels, and no 100% coverage on PC. [`llK5tk0jiN8` 02:01] [`NNlrLNv9byI` 00:00, 01:01]
- Installers and the file system: administrator installs, DLL and file system view problems, copy-and-run as the working model. [`sb1T9205ZY8` 00:00] [`oiv4amBUf9Q` 00:01, 01:01]
- Windows defects that a new design must avoid:
  1. No accurate sleep. [`I3Q0cP49OTk` 00:00]
  2. A system-wide timer setting that any program changes. [`I3Q0cP49OTk` 02:02]
  3. A program changes the global sound volume. [`uzxV_RsL89g` 01:02]
  4. Old interfaces are never corrected; new parallel interfaces are added. [`llK5tk0jiN8` 01:01]
  5. A size parameter with two meanings and no error on a wrong size. [`zZUnt_XLgrk` 01:00]
  6. Updates and reinstalls reset settings. [`AEO2OY1nPhI` 02:02]
  7. Activation, and a login that needs a remote account and a network. [`QXEAQQueYkk` 01:00, 02:01]
  8. Network setup is blocked before login. [`QXEAQQueYkk` 03:02]
  9. Installers with administrator access that close unrelated programs. [`sb1T9205ZY8` 00:00, 02:00]
  10. A slow console. [`W5s965qdmyU` 06:12]
  11. Bundled programs that start or preload without a request (Explorer preload, Copilot, Teams). [`AEO2OY1nPhI` 01:02, 05:03]

## 3. Transcripts with nothing relevant

- `fEn2HPGXwj8`: a talk extract on lost technologies (Lycurgus Cup, Greek fire, Antikythera mechanism, 1980s logic chips). It gives the general argument that knowledge is lost between generations. No statement on system software.
- `2pJtqDgWXys`: the order of his projects (game, engine, language). One joke answer on an operating system, recorded in section A.
- `ogHl_OwcZWE`: global state in application code, and programming dogma. One general statement, recorded in section N.
- `LKwG0WJfHZY`: a one-minute extract of `W5s965qdmyU`. No additional content.
- `M_6-A8iMeJM`: 29 seconds. One statement that the Linux release of Braid was costly, recorded in section B. No technical detail.

Transcripts with little content for the design, used above for one or two statements: `unx3WCWZwUc` (software speed), `6jaVyckxjsA` (abstraction layers, team size), `LmriR7AkpDA` (code size), `GXa3wSPn8do` (libc), `t63x3Tv4sEw` (Linux complexity).
