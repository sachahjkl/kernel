# Jonathan Blow on designing a new operating system / kernel

> Superseded for design items. The clips were later read at the source.
> Use `blow_verified_statements.md` for what Blow said about OS design, with timestamps.
> This file stays useful for the tweets, the critiques and the rebuttals.

Research date: 2026-11-09. Reliability legend used throughout:

- **[P]** primary source fetched and read by me (Blow's own words, or a page quoting them verbatim).
- **[S]** secondary: a third party's notes/paraphrase of a Blow video or post. The underlying video exists (title/uploader confirmed) but I could NOT read its transcript (YouTube, transcript mirrors, X/Twitter, xcancel and nitter all blocked from this environment).
- **[T]** title/metadata only: the resource exists, content not verified.
- **[U]** uncertain attribution.

Important caveat for the report writer: almost all of Blow's concrete OS design content lives in Twitch streams, re-uploaded as YouTube clips. I could not retrieve any clip transcript. The concrete design list below therefore rests on ONE third-party set of viewing notes (paritybit.ca), which is terse and partly paraphrased. No timestamps could be obtained for any video. Treat every design item as "Blow said this according to a viewer's notes" until someone watches the two clips.

## Which talks/interviews contain OS design content?

### Takeaway
The substantive OS/kernel design material is in two stream clips uploaded by Anton Swifton ("Jonathan Blow on how an operating system should work", "Jonathan Blow on Drivers"), supplemented by a January 2019 tweet chain (Linux kernel fine, userspace is the problem) and an August 2025 X post (people are "too helpless to even conceive of a new OS"). The formal talk "Preventing the Collapse of Civilization" contains OS criticism but, as far as I could verify, no kernel design.

### Cited Findings

Inventory (title / date / URL / what is in it):

- **"Jonathan Blow on how an operating system should work"** — YouTube clip, uploader "Anton Swifton" (@swifton), confirmed via YouTube oEmbed; about 14 minutes per a search listing; upload date and original stream date not retrieved; no timestamps. Content: the main list of design proposals (see next section). [T for metadata, S for content] — [YouTube k0uE_chSnV8](https://www.youtube.com/watch?v=k0uE_chSnV8); notes at [paritybit.ca](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- **"Jonathan Blow on Drivers"** — YouTube clip, same uploader (confirmed via oEmbed); date not retrieved. Content: drivers out of the kernel, DMA, per-process TCP stack, hardware should fit software. [T/S] — [YouTube xXSIs4aTqhI](https://www.youtube.com/watch?v=xXSIs4aTqhI); notes at [paritybit.ca](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- **"Jonathan Blow on What Went Wrong with Operating Systems"** — YouTube clip, from a clips channel whose description links ko-fi.com/jonathanblowclips ("Jonathan Blow on Modern Operating Systems"). Aggregator pages associate it with the phrase "A clarification on drivers". Content not verified. [T] — [YouTube sb1T9205ZY8](https://www.youtube.com/watch?v=sb1T9205ZY8)
- **"Jonathan Blow on Why Operating Systems Stagnated"** — YouTube clip; search snippet of the description: "Jonathan Blow argues that operating systems still rely on decades-old designs that make it hard to r..." (truncated). [T] — [YouTube cKyrT8OVbDo](https://www.youtube.com/watch?v=cKyrT8OVbDo)
- **"Jonathan Blow on why Unix is the wrong base for modern computers"** — YouTube clip, upload date reported by search as 2026-10-19. Only viewer comments were indexed: commenters call his criticism vague ("I wish he would be more specific about what is wrong with Unix") and defend fork+exec and "everything is a file". [T] — [YouTube uF_3aRpyzD8](https://www.youtube.com/watch?v=uF_3aRpyzD8)
- **"Jonathan Blow on why you can't trust your operating system"** — YouTube clip; description links the original stream https://www.twitch.tv/videos/2817109241 (the only clip for which a source VOD id was found; the high id implies a 2026 stream). Content not verified. [T] — [YouTube -oDxMLNvikY](https://www.youtube.com/watch?v=-oDxMLNvikY)
- **"Windows is a trash fire but it's still the best we have (Jonathan Blow)"** — YouTube clip; snippet: "Jonathan Blow laments the current state of operation systems." [T] — [YouTube llK5tk0jiN8](https://www.youtube.com/watch?v=llK5tk0jiN8)
- **"Jonathan Blow on two patterns every Windows programmer runs into"** — YouTube clip, Windows API criticism, content not verified. [T] — [YouTube zZUnt_XLgrk](https://www.youtube.com/watch?v=zZUnt_XLgrk)
- Other clip titles that exist per aggregator listings (content and video IDs not verified): "Jonathan Blow on modern OS projects", "Jonathan Blow on the Windows terminal", "Jonathan Blow on libc", "Jonathan Blow on shipping to Linux", "Jonathan Blow on what's wrong with Linux", "Jonathan Blow on making an operating system". [T] — [search listing](https://old.fbpe.org/jonathan-blow-on-modern-os-projects.html) (low-quality auto-generated aggregator; use only as a pointer to titles)
- **Tweet chain, January 2019** (thread reposted on ResetEra 2019-01-08): Linux kernel is stable, userspace is the problem; "using the Linux kernel and deleting all of userspace and starting over". [P via verbatim repost] — [tweet 1082329608572174336](https://twitter.com/Jonathan_Blow/status/1082329608572174336); [ResetEra repost](https://www.resetera.com/threads/jonathan-blow-game-developer-of-braid-the-witness-on-what-would-help-him-make-the-switch-to-linux-for-developing-video-games.92048/); coverage: [GameRevolution](https://www.gamerevolution.com/news/480649-jonathan-blow-develop-for-linux)
- **X post, August 2025** ("too helpless to even conceive of a new OS"), quoted in full on HN on 2025-08-13. [P via verbatim quote] — [X post](https://x.com/Jonathan_Blow/status/1954574841547464739); [HN quote](https://news.ycombinator.com/item?id=44883488)
- **"Preventing the Collapse of Civilization"**, DevGAMM Moscow 2019 (talk given May 2019; r/programming thread dated 2019-05-18). OS-relevant content is criticism, not design: the OS layer as restrictive, software robustness declining, loss of knowledge. [S: I only read summaries/rebuttals, not the transcript] — [YouTube pW-SOdj4Kkk](https://www.youtube.com/watch?v=pW-SOdj4Kkk); [wiki summary](https://wiki.arnaudcys.com/Preventing%2520the%2520Collapse%2520of%2520Civilization%2520-%2520Jonathan%2520Blow.html)
- **On the Metal S01E09 "Jonathan Blow"**, 2020-01-27, 2:51:26 (Oxide; Cantrill/Frazelle/Tolnay). No transcript on the page. Show notes list "microkernels" and "dynamic linking" among topics discussed, alongside the Collapse talk, so OS-adjacent discussion exists, but I could not extract what Blow said. [T] — [On the Metal](https://onthemetal.transistor.fm/episodes/jonathan-blow)
- **X post, 2024** to @ThePrimeagen: "Unfortunately I have to use Windows because I do video games. But Windows is trying to become unusable as quickly as possible, so it may pretty soon cross the equilibrium point where Linux is actually better." [P via search-index verbatim title] — [X post](https://x.com/Jonathan_Blow/status/1807868275042255078)
- **X post, 2026**: "Windows would never. (This is our source control server)..." with a photo; context unknown. [T] — [X post](https://x.com/Jonathan_Blow/status/2046992148428726592)
- **2013 Hacker News post** by Blow on Linux as a development platform (debugging "terrible", wants a debugger built as a library with an API), as reported by MCV/Develop. [S, via search snippet, article not fetched] — [MCV/Develop](https://mcvuk.com/development-news/jonathan-blow-criticises-linux-dev-tools/)

### Inferences
- The clip titles from 2026 ("why Unix is the wrong base", "why you can't trust your operating system", "Why Operating Systems Stagnated") suggest Blow continued to discuss OS design on stream through 2026, i.e. this is a recurring stream topic, not a one-off.
- "How an operating system should work" and "on Drivers" look like parts of the same stream discussion (same uploader, the second being a "clarification"), but this is not confirmed.

### Gaps
- No transcript, date, or timestamps for any of the clips. Someone needs to watch k0uE_chSnV8 and xXSIs4aTqhI (about 14 min for the first) to convert [S] items to [P].
- I found no evidence of OS design content in a Lex Fridman interview, in Handmade Con sessions, or in a "No Boilerplate" conversation; I did not find such appearances at all. Casey Muratori is not mentioned in the sources I read (his "Thirty Million Line Problem" talk covers similar ground, but that is Muratori, not Blow).
- The Jai community wiki was not found to contain OS design material (not searched in depth).
- On the Metal: what Blow said about microkernels and dynamic linking is unknown.

## What does he propose concretely?

### Takeaway
According to a viewer's notes on the two Swifton clips, Blow sketches a minimal, microkernel-like system: no drivers in the kernel, most work in userspace, processes strongly sandboxed by default and communicating through shared memory mappings rather than syscalls, no installation, no registry, no PATH, position-independent code with one library type. All of this is [S] unless marked otherwise; none of it is a written spec, it is stream talk.

### Cited Findings

From the clip "how an operating system should work" (notes; quoted strings are the note-taker's wording, not necessarily Blow's exact words) — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/), source video [k0uE_chSnV8](https://www.youtube.com/watch?v=k0uE_chSnV8):

- "No drivers" (in the kernel). [S]
- "Most things should happen in userspace". [S]
- "Programs should be able to go over the network without talking through the kernel". [S]
- "Processes communicate through memory mapping/memcpy" (IPC via shared memory rather than kernel-mediated calls). [S]
- "Processes super-sandboxed from each other, basics of how OS works, not additional thing" (sandboxing is the default model, not a bolt-on). [S]
- The core OS should do very little; its interface should be minimal, covering DMA with hardware and handling of memory pages. [S, paraphrase]
- Microkernel-like approach that avoids kernel crossings/syscalls for routine operations, with a performance motivation. [S, paraphrase; whether Blow himself used the word "microkernel" is not verified]
- No installation of software: programs run in their own sandbox and cannot reach anything else. [S, paraphrase]
- "No PATH variable because programs can't arbitrarily read the FS, but maybe more structured folder?" [S]
- "No registry". [S]
- All code position-independent; a single library type that can be linked statically (preferred) or dynamically, tracked so that security patches can identify affected processes. [S, paraphrase]
- Command-line programs and library functions should be the same thing. [S, paraphrase]
- "Batch scripting is not a good idea because it usually turns into programs to just run programs". [S]
- "Don't try to replicate functionality of Linux, Windows, MacOS, etc."; most existing software is unnecessary. [S]
- Diagnosis that motivates the above: current OSes run about 400 processes by default and ship about 4,500 executables. [S, paraphrase]

From the clip "on Drivers" — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/), source video [xXSIs4aTqhI](https://www.youtube.com/watch?v=xXSIs4aTqhI):

- "Communication over DMA" (program talks to the device directly). [S]
- "Each process implements own TCP stack (i.e. it's basically in a library)". [S]
- "What we have now is a mess where drivers from anyone get complete access to the kernel". [S]
- A program connecting to a printer should talk to the printer directly, no middleman. [S, paraphrase]
- Sound should be simple to stream to a device without hundreds of drivers. [S, paraphrase]
- Hardware should be built to fit the software: standard protocols; non-compliant hardware is handled by a userspace translation program with no kernel access. [S, paraphrase]

From the January 2019 tweet chain — [ResetEra verbatim repost](https://www.resetera.com/threads/jonathan-blow-game-developer-of-braid-the-witness-on-what-would-help-him-make-the-switch-to-linux-for-developing-video-games.92048/), [original tweet](https://twitter.com/Jonathan_Blow/status/1082329608572174336):

- Alternative, more pragmatic route: "using the Linux kernel and deleting all of userspace and starting over" in order "to build a system that makes sense in 2020". [P]
- New languages should "not build your structure on the currently-existing userspace shantytown." [P]
- A binary that talks directly to the kernel without libc could run on any distribution, but opening a window gets harder, and he says he does not know how to get hardware-accelerated 3D that way (software rendering floated as a possibility). [P, paraphrased by the fetch tool from the repost]
- A forum repost summarises the same thread as: a fresh start with no compatibility is needed to minimise complexity. [S] — [Quarter to Three](https://forum.quartertothree.com/t/linux-was-20-of-issues-but-0-1-of-sales/139729?page=3)

Checklist of ideas named in the brief, and their verification status:

- Shared-memory message passing between processes instead of syscalls: supported [S].
- No drivers as kernel code: supported [S].
- Per-application sandboxing: supported [S].
- No installers: supported [S].
- No shared-library/DLL hell: partially supported [S] (single library type, static preferred, tracked dynamic linking). No "DLL hell" quote found.
- Per-app file system views: only indirectly ("programs can't arbitrarily read the FS") [S]. No explicit "FS view per app" statement found.
- Drastically smaller syscall surface: supported [S] (minimal interface: DMA and memory pages).
- Removal of terminals/ttys/signals/fork: NOT found. Only "no batch scripting", "no PATH", "no registry" are attested. The 2026 "Unix is the wrong base" clip may cover this, unverified.
- Flat memory / less virtual memory: NOT found. The notes actually imply the kernel still manages memory pages and process isolation.
- New executable format: NOT found beyond "all code position-independent".
- Scheduler design, data-oriented kernel internals, capability model details: NOT found.

### Inferences
- The design described is close to an exokernel / library-OS model (user-level TCP stack, direct device access via DMA-capable mappings, kernel reduced to isolation and page management) more than a classic message-passing microkernel; this label is mine, not Blow's.
- There is a tension between the two routes he has voiced: "keep the Linux kernel, delete userspace" (2019, tweets) versus "tiny kernel with no drivers" (stream clips, undated). Without clip dates I cannot say which is his later position.
- Direct device access by sandboxed processes presupposes hardware-enforced isolation (IOMMU or cooperative hardware); the notes do not record Blow addressing this, and "hardware should be built to fit the software" suggests he assumes hardware vendors change.

### Gaps
- Exact wording and timestamps for every [S] item.
- Whether he specifies how sandboxed processes obtain permissions (prompting, capabilities, manifests), how files are shared between apps, how GPU access works in this model, how scheduling works.
- No written document by Blow on OS design was found (no blog post, no spec).

## What are his criticisms of Linux, Windows (NT), macOS, POSIX, and of complexity in general?

### Takeaway
Blow's consistent complaint is accumulated complexity: too many processes, executables and layers; a Linux userspace he calls a "shantytown" on top of a kernel he considers fine; a Windows that is degrading but still the least bad for games. His Unix/POSIX critique exists (2026 clip title) but I could not verify its content.

### Cited Findings
- Linux: the kernel is fairly stable, the real problem is "the giant mound of userspace garbage"; shipping software on Linux will not improve without a fundamental change of philosophy; he would switch quickly if it let him ship software and work on a stable machine. [P] — [ResetEra repost of tweets, Jan 2019](https://www.resetera.com/threads/jonathan-blow-game-developer-of-braid-the-witness-on-what-would-help-him-make-the-switch-to-linux-for-developing-video-games.92048/)
- Linux (2013): the cost of switching is too high for a game developer; debugging is terrible; IDE/debugger shortcomings hold the platform back. [S, via search snippets] — [MCV/Develop](https://mcvuk.com/development-news/jonathan-blow-criticises-linux-dev-tools/); [Ubuntu Vibes](https://www.ubuntuvibes.com/2013/02/jonathan-blow-cost-of-switching-to.html)
- Windows: "Windows is trying to become unusable as quickly as possible, so it may pretty soon cross the equilibrium point where Linux is actually better." (2024) [P] — [X post](https://x.com/Jonathan_Blow/status/1807868275042255078)
- Windows: clip titled "Windows is a trash fire but it's still the best we have". [T] — [YouTube llK5tk0jiN8](https://www.youtube.com/watch?v=llK5tk0jiN8)
- Linux distributions as "new OS" (2025): "So they have to get excited about a mildly different arrangement of bloatware from That OS From 35 Years Ago. But as long as you give it a Cool Name, everything is good." (context: DHH's Omarchy announcement thread on HN). [P via verbatim quote] — [HN comment by piskov](https://news.ycombinator.com/item?id=44883488)
- Complexity in general: current OSes run about 400 default processes and ship about 4,500 executables; a functional OS should do very little. [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- Collapse talk (2019): as summarised by third parties, the OS is restrictive and removes capabilities of the CPU; because most machines share the same architecture, software targeting hardware directly would run fine; software quality and robustness are declining and knowledge is being lost across generations. [S] — [wiki summary](https://wiki.arnaudcys.com/Preventing%2520the%2520Collapse%2520of%2520Civilization%2520-%2520Jonathan%2520Blow.html); [datagubbe rebuttal quoting the claims](https://datagubbe.se/endofciv/)
- Collapse talk: Blow reportedly says he wants to "mostly not need" an OS (phrase as quoted by the rebuttal's author when pointing out a contradiction with multitasking). [S] — [datagubbe](https://datagubbe.se/endofciv/)
- Unix/POSIX: a clip titled "why Unix is the wrong base for modern computers" was uploaded 2026-10-19; viewers complain his critique is not specific. [T] — [YouTube uF_3aRpyzD8](https://www.youtube.com/watch?v=uF_3aRpyzD8)

### Inferences
- His position on Linux has softened relative to Windows between 2013 ("cost too high") and 2024 ("may soon be better"), driven by Windows getting worse rather than Linux getting better.
- "No registry" and "no installation" are implicit Windows criticisms; "no PATH" and "no batch scripting" are implicit Unix criticisms.

### Gaps
- No verified statement about macOS specifically.
- No verified statement specifically about the NT kernel (as opposed to Windows as a product) or about POSIX APIs (fork, signals, ttys).

## What has he said about drivers, graphics APIs/GPU stack, file systems, linking/loading, executable formats, IPC, security, and hardware vendors in an OS context?

### Takeaway
Drivers and IPC are the best-covered subsystems (out of the kernel; shared memory); linking gets one concrete rule (position-independent code, one library type, static preferred); file systems, executable formats and the GPU stack are barely or not addressed in the sources I could verify.

### Cited Findings
- Drivers: no drivers in the kernel; today "drivers from anyone get complete access to the kernel"; programs talk to devices directly over DMA; non-compliant hardware gets a userspace translation program. [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- Hardware vendors: hardware should be built to fit the software, using standard protocols. [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- Networking: each process has its own TCP stack as a library; programs reach the network without going through the kernel. [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- IPC: processes communicate through memory mapping/memcpy. [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- Security: sandboxing between processes as the base model; dynamic libraries tracked so a security patch can identify affected processes. [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- Linking/loading: all code position-independent; one library type, statically linked by preference. [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- File system: programs cannot arbitrarily read the FS, hence no PATH; "maybe more structured folder?". [S] — [paritybit.ca notes](https://www.paritybit.ca/garden/projects/building-an-operating-system/)
- GPU: in the 2019 tweets he says he does not know how one would get hardware-accelerated 3D when bypassing the Linux userspace, and floats software rendering. [P, paraphrase of repost] — [ResetEra](https://www.resetera.com/threads/jonathan-blow-game-developer-of-braid-the-witness-on-what-would-help-him-make-the-switch-to-linux-for-developing-video-games.92048/)
- Graphics APIs: he was reported in 2017 as open to a Linux port of The Witness with Vulkan "but never with OpenGL". [S, headline only] — [GamingOnLinux](https://www.gamingonlinux.com/2017/01/jonathan-blow-states-he-is-open-to-a-linux-port-of-the-witness-with-vulkan-but-never-with-opengl/page=1/)
- Driver/device support as the obstacle: in 2025 he mocks the objection, "Computer Nerds: Noooooo I can't make an OS because drivers and adoption!!!!1". [P via verbatim quote] — [HN comment](https://news.ycombinator.com/item?id=44883488)

### Inferences
- The GPU is the unresolved hole in his sketch: his own 2019 remark concedes he has no answer for accelerated graphics without the vendor driver stack, and the driver notes do not mention GPUs.

### Gaps
- No verified statements on executable formats (PE/ELF), on file system internals, on shader compilation/GPU driver architecture in an OS context, or on scheduling.
- A search-engine summary of his August 2025 X post attached to it the sentence that there is "no getting around the never-ending archaeological painstaking work of supporting thousands of devices people want to use". I could not open X to see who wrote it; it reads like a reply from another user rather than Blow. [U] — [X post](https://x.com/Jonathan_Blow/status/1954574841547464739)

## Has he ever announced an intention to actually build an OS, or constraints why not?

### Takeaway
No announcement of an OS project was found. His public statements are hypothetical ("if he were to...") or exhortations to others; in August 2025 he framed the usual objections (drivers, adoption) as learned helplessness rather than real constraints.

### Cited Findings
- 2019: phrased as a hypothetical, he would take the Linux kernel, delete all of userspace and start over "to build a system that makes sense in 2020". [P] — [ResetEra repost](https://www.resetera.com/threads/jonathan-blow-game-developer-of-braid-the-witness-on-what-would-help-him-make-the-switch-to-linux-for-developing-video-games.92048/); [GameRevolution](https://www.gamerevolution.com/news/480649-jonathan-blow-develop-for-linux)
- 2025: "The people who would historically be excited about a new operating system can't do that any more, because everyone is too helpless to even conceive of a new OS." followed by the Elon Musk comparison (car company, self-landing rockets, brain chip) versus "Computer Nerds: Noooooo I can't make an OS because drivers and adoption!!!!1". [P via verbatim quote] — [HN comment](https://news.ycombinator.com/item?id=44883488); [X post](https://x.com/Jonathan_Blow/status/1954574841547464739)
- His actual ongoing projects per press coverage are the Jai language, a custom engine and the game Order of the Sinking Star; no OS is mentioned. [P for absence in that interview] — [GamesBeat](https://gamesbeat.com/how-thekla-created-order-of-the-sinking-star-with-1500-puzzles-jonathan-blow-exclusive-intervie/)
- He says he uses Windows because he makes video games ("Unfortunately I have to use Windows because I do video games"). [P] — [X post](https://x.com/Jonathan_Blow/status/1807868275042255078)

### Inferences
- The practical constraint is his business (games ship on Windows/consoles) and his existing commitments (language + game), not a stated belief that an OS is infeasible.
- HN commenters read the 2025 post the same way: "Google couldn't do it (Fuchsia is dead). Blow can't do it."

### Gaps
- The clip titled "Jonathan Blow on making an operating system" might contain a direct statement on whether he would do it; not verified.
- No statement found about writing an OS in Jai.

## What critiques/rebuttals of his OS ideas exist (HN threads, blog posts)?

### Takeaway
The strongest rebuttal comes from John Carmack (August 2025): a new OS "doesn't make any product sense", citing Meta's failed XROS as a best-case attempt. Other critiques target the Collapse talk (the OS adds capabilities, machines are more robust than in the 1980s/90s) and the vagueness of his Unix criticism.

### Cited Findings
- John Carmack, X, late August 2025, replying to what he calls Blow's "Why can't we even conceive of writing a new OS today" post: "I deeply love the ideals of clear, efficient programs that do their job without baggage, and I have always been very sympathetic to efforts like Oberon, Plan 9, and even TempleOS. But building a new operating system today doesn't make any product sense. Meta spent a lot of resources working on a fully custom XROS, over my rather strenuous objections. They had top tier engineering talent, tons of support, and they were producing high quality code and docs. It was a best case scenario from a 'new OS' perspective, and, as one of the engineers put it, 'If we can't do it, who could?'" He also quotes an email from the LIBBA smart-glasses OS founder conceding that "a custom OS rarely justifies itself: cost, shelf life, and developer burden outweigh the benefits." [P, text from search-index copy of the post] — [X post by Carmack](https://x.com/ID_AA_Carmack/status/1961172409920491849); coverage: [WebProNews](https://www.webpronews.com/john-carmack-new-os-development-futile-prioritize-ai-for-xr-breakthroughs)
- Blog post (2025-09-07) siding with Carmack: network effects of Unix-likes and Windows are a near-insurmountable barrier; a customised distribution (Omarchy) is the realistic middle path; only a hardware company could plausibly break the mold. — [jentrialgo](https://jentrialgo.github.io/to-build-a-new-os-or-not-to-build-a-new-os.html)
- HN, 2025-08-13, replies to the Blow quote: mkozlows: "Okay, but you literally can't do it." ... "Google couldn't do it (Fuchsia is dead). Blow can't do it."; hipsterusername: "I'd love to see a new OS." but "how does that get funded? Who actually makes it happen?" — [HN thread](https://news.ycombinator.com/item?id=44847419)
- Carl Svensson, "Is abstraction killing civilization?" (early 2021): "the OS does add to the capabilities of the CPU" (file systems, networking, multitasking); Blow contradicts himself by wanting to "mostly not need" an OS while multitasking; "computers are, by and large, much more robust these days than a couple of decades ago" (memory protection, journaling FS); abstraction aids portability; churn rather than abstraction is the real source of fragility. — [datagubbe.se](https://datagubbe.se/endofciv/)
- HN thread on the Collapse talk (2021-01-15, 139 points, 94 comments): arexxbifs: "It's true that the OS in both abstract and concrete ways removes capabilities from the CPU" but it also adds them; "It's not the OS that removes this capability, it's the work of companies trying to protect their revenue"; he makes "very sweeping, erroneous statements about software and development."; erikbye: "It is false that we as an industry cannot make robust software." Supportive: mikewarot: "There are too many layers of abstraction." — [HN](https://news.ycombinator.com/item?id=25788317)
- r/programming thread (May 2019): a commenter argues scheduling, paging and security features exist to solve problems learned over decades, which Blow avoids only because he builds on that work. [S, via search summary] — [Reddit mirror](https://r.darklab.sh/r/programming/comments/bq1dt6/jonathan_blow_preventing_the_collapse_of/eo1npxf/?context=3)
- YouTube comments on the 2026 Unix clip: criticism is vague; fork+exec and "everything is a file" defended. [S, via search snippet] — [YouTube uF_3aRpyzD8](https://www.youtube.com/watch?v=uF_3aRpyzD8)
- Older HN jab at his credibility on OS matters: "Is that the guy who was unable to install Ubuntu properly, so he declared that s..." (truncated title, thread not read). [T] — [HN](https://news.ycombinator.com/item?id=10987613)

### Inferences
- No technical rebuttal of the specific design (userspace drivers via DMA, per-process TCP, shared-memory IPC) was found; critiques address feasibility/economics (Carmack, HN) or the Collapse talk's historical claims. The obvious technical objections (IOMMU dependence, device multiplexing between sandboxed processes, GPU drivers, similarity to existing exokernel/unikernel/DPDK/io_uring-style work) are my own observations and not sourced.

### Gaps
- Blow's reply to Carmack, if any, was not retrievable (X blocked).
- No dedicated blog post analysing the "how an operating system should work" clip was found, apart from the paritybit.ca notes, which are neutral notes for a hobby OS project rather than a critique.
