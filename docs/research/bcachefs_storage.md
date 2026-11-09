# bcachefs and modern copy-on-write filesystem design: fork, port, or reimplement the ideas?

Research date: 2026-11-09. Primary source for architecture is the current bcachefs manual ("bcachefs: Principles of Operation", PDF fetched from bcachefs.org on 2026-11-09, 131 pages; cited below as **PoO** with section numbers). Anything marked **[background, unverified]** comes from the researcher's prior knowledge and was not confirmed against a source in this session; it is confined to Inferences/Gaps sections.

---

## 1. bcachefs architecture — and which parts are cache-conscious / data-oriented

### Takeaway
bcachefs is a transactional key-value store ("filesystem on top of a relational database") built on two primitives — large log-structured B+tree nodes and generational buckets — with the filesystem proper expressed as keys in 28 btrees. The explicitly cache-line-aware parts are concentrated in the intra-node search code (eytzinger-layout auxiliary search trees with 4-byte nodes, one per cacheline of keys; per-node bkey packing), plus batching layers (journal, key cache, write buffer); these are the ideas most worth stealing and they are small relative to the whole codebase.

### Cited Findings

**Overall model**
- "bcachefs is architected more like a filesystem on top of a relational database, with tables for the different filesystem data types - extents, inodes, dirents, xattrs, et cetera." — [PoO §1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- "The entire filesystem is built on two primitives: btrees and buckets. All filesystem state is a key-value pair in a btree... There are no separate inode tables, bitmap allocators, or per-inode extent trees... Everything else in bcachefs is built on this transactional key-value store over generational bucket storage." — [PoO §1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- There are **28 btrees**. Core data: `extents`, `inodes`, `dirents`, `xattrs`, `reflink`. Allocation: `alloc` (one key per bucket), `freespace`, `need_discard`, `bucket_gens`, `backpointers`. Snapshots: `subvolumes`, `snapshots`, `snapshot_trees`, `subvolume_children`, `deleted_inodes`. Background work: `reconcile_work`, `reconcile_hipri`, `reconcile_pending`, `reconcile_scan` (+ `_phys` variants). Other: `quotas`, `stripes`, `bucket_to_stripe`, `stripe_backpointers`, `lru`, `logged_ops`, `accounting`. — [PoO §9.8, §9.8.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- New btree types can be added without on-disk format changes; erasure-coding stripes, backpointers and accounting were all added that way. — [PoO §9.8.8.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**B-tree node design (inherited from bcache)**
- The btree is "not a conventional b+ tree but more of hybrid, taking concepts from compacting data structures: btree nodes are very large, log structured, and compacted (resorted) as necessary in memory." Nodes are 128K–256K, so trees are "typically 2–3 levels even at petabyte scale". — [PoO §1.1, §9.8.2](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- bcachefs runs **its own btree node cache**, not the Linux page cache: "Other COW filesystems use the Linux page cache for metadata, which limits them to 4K btree nodes; bcachefs manages its own btree node cache, so we can use 128K–256K nodes and tune reclaim independently of the page cache." — [PoO §1.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- A node holds multiple sorted sets (**bsets**): new keys are appended, not inserted in place; written bsets are re-sorted in memory so a node has "at most a few (typically three) bsets in memory: the one currently being inserted into (at most 8–16K), and the rest roughly forming a geometric progression in size." — [PoO §9.8.4](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Consequences of the log-structured node: writes are sequential, and "a node can be written to disk under a read lock rather than a write lock, since new data is only appended." Deletion is a whiteout key (`KEY_TYPE_deleted`), dropped at the next full node rewrite. — [PoO §9.8.3, §9.8.4](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**Auxiliary search trees (the explicitly cache-line-aware part)**
- Read-only bsets get "a binary search tree in an array (same layout as is used for heaps) where each node corresponds to one cacheline of data in the original bset". Read-write bsets get a simpler flat table "with one entry per cacheline of data". — [PoO §9.8.7](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- The layout is chosen for prefetching: "at every iteration the children of the current node are adjacent in memory (and all the grandchildren, and all the great grandchildren)—meaning unlike with a binary search it's possible to prefetch." — [PoO §9.8.7](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Node-shrinking tricks: (1) store only the key's offset within its cacheline; the cacheline index is recomputed from the node's array position by `eytzinger1_to_inorder()` ("mostly just shifts and bit operations"); (2) store only the bits between where the bounding keys `l`/`r` first differ and where the pivot differs from its predecessor: "The full struct bkey has 160-bit keys, but 16-bit keys in the auxiliary search tree will suffice > 99% of the time." Nodes are fixed-size; a failed construction is flagged and falls back to comparing the full key. — [PoO §9.8.7](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Auxiliary tree nodes are four bytes, so 16 fit on a cacheline, and four levels can be prefetched ahead (per Overstreet's design notes as surfaced in search). — [evilpiepirate.org FAST draft, usenix2019.tex](https://www.evilpiepirate.org/cgit/FAST.git/plain/usenix2019.tex)
- Claimed benefit: "On random lookups with a large btree the auxiliary search trees are easily over an order of magnitude faster" than the earlier simple binary search. — [PoO §9.8.7](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Overstreet's kernel patch promoting the eytzinger helpers to `include/linux/`: eytzinger trees are "a bit more expensive to setup, but lookups perform much better assuming the tree isn't entirely in cache. Binary search is a worst case scenario for branch prediction and prefetching". — [LKML, "eytzinger: Promote to include/linux/" (Jan 2024)](https://lkml.iu.edu/2401.3/04308.html)
- Academic basis: Khuong & Morin, "Array Layouts for Comparison-Based Searching", found eytzinger search beat B-tree-style array layouts across the sizes tested. — [arXiv:1509.05053](https://arxiv.org/pdf/1509.05053)
- A Feb 2026 project blog post: "every btree node uses an eytzinger-layout auxiliary search tree to find keys. Every lookup, every file creation, every extent check walks this tree." (Note: this blog is the LLM-authored "ProofOfConcept" blog, see §2/§7.) — [poc.bcachefs.org, "The Tree You Can't See"](https://poc.bcachefs.org/blog/implicit-trees.html)

**bkey packing**
- Keys are packed per btree node: "a per-bset format descriptor records which" fields need how many bits; fields constant across a node "can be stored in zero bits. The packed key retains only the 3-byte header (u64s, format, type) followed by the variable-length packed fields". Packed and unpacked keys can coexist in one node via the per-key `format` field. — [PoO §9.8.5](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- The on-disk format takes Cap'n Proto as an inspiration (listed on the project homepage). — [bcachefs.org](https://bcachefs.org/)

**Transactions and iterators**
- "All btree operations go through a transaction layer (btree_trans) that provides atomic multi-key updates with optimistic concurrency control." Commit order: journal reservation → write-lock affected nodes in sorted order → apply → release locks once the journal has accepted the change. "btree locks are held only for in-memory operations, never across IO." — [PoO §1.2](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Deadlock handling is database-style cycle detection; the victim "drops all its locks and restarts from the beginning", which requires "all transaction code to be idempotent and prepared for restarts at any point." Node sequence numbers allow cheap relocking. — [PoO §1.2](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Triggers: transactional triggers generate further updates before commit (e.g. backpointers); atomic triggers run under the journal lock for accounting. Unbounded operations (truncate, insert/collapse range) use the `logged_ops` btree and are replayed after a crash. — [PoO §1.2](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- "The btree interface is iteration-oriented rather than lookup-oriented... The fundamental operation is: position an iterator, then peek at or advance through keys." A `btree_iter` holds one `btree_node_iter` per tree level. — [PoO §9.8.7, §9.8.8.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Latency is an explicit goal: "one major goal of bcachefs is to be the first general purpose soft realtime filesystem." — [PoO §1.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**Six locks**
- Btree nodes use SIX locks (shared / intent / exclusive): intent conflicts with other intents but not with readers, so a multi-node update (e.g. a split) holds intent locks throughout and upgrades to write only for each in-memory modification. — [PoO §1.2, §9.8.6](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**Journal, key cache, write buffer (batching)**
- "unlike other COW btrees, btree updates are journalled... btree writes are only done when we have a large block of updates, or when required by memory reclaim or journal reclaim." — [PoO §1.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Recovery replays the journal in commit order; bsets with a journal sequence newer than the last written journal entry are blacklisted (a 64-sequence pad covers in-flight writes). — [PoO §1.3](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Key cache: a hash table of hot keys (mainly `alloc`) updated without a btree traversal and flushed by journal reclaim. Write buffer: backpointer, LRU and accounting updates are buffered, sorted and flushed in bulk, "amortizing the cost of btree traversal across many updates." — [PoO §9.8.10](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Frequently-read counters are "maintained in percpu arrays for lock-free reads"; the `bucket_gens` btree packs 256 bucket generation numbers into one key for the RCU read path. — [PoO §9.2 (lines on percpu / bucket-gens)](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**Allocator, buckets, copygc**
- Disk is divided into buckets, "typically 512k to 2M". Buckets and pointers carry generation numbers, so a bucket of cached data can be reused by bumping the generation without finding and rewriting its pointers. A bucket is written sequentially once and not rewritten until invalidated. — [PoO §1.5](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- This needs a copying GC for internal fragmentation and reserved space; a fragmentation LRU btree lets copygc find the emptiest buckets directly. Backpointers answer "what data lives in this bucket?" without scanning extents; they underpin copygc, device evacuation, scrub and reconcile. — [PoO §1.5](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Zoned storage: "The same algorithms are intended to be used for managing SMR ... and zoned hard drives directly"; buckets "map naturally to zones". — [PoO §1.5](https://bcachefs.org/bcachefs-principles-of-operation.pdf). Overstreet told an LSFMM session that bcachefs "already has native zoned-device support" thanks to bucket allocation — [LWN (LSFMM report, article 897263)](https://lwn.net/Articles/897263/). These two statements conflict on whether zoned support is done or intended; treat as **not confirmed shipping**.

**Snapshots, subvolumes, reflink**
- Snapshots are "not based on cloning of COW btrees as with btrfs, but instead are based on versioning of individual keys in the btrees." Four btrees are snapshot-aware (extents, inodes, dirents, xattrs); each key position includes a snapshot ID. Creation is O(1); "Many thousands or millions of snapshots can be created". — [PoO §2.4, §9.4.1, §9.4.3](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- A subvolume = root inode number + snapshot ID; the snapshot tree is binary (up to two children per node) with a skiplist for ancestor queries. Snapshots are writable by default. — [PoO §9.4.2](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Quotas "do not currently apply to snapshot subvolumes"; writes to snapshot subvolumes bypass quota enforcement. Recursive snapshot creation is "still to be implemented". — [PoO §2.4, §2.5](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Reflink moves the shared extent to a separate `reflink` btree with a refcount; "reads through a reflinked extent require two btree lookups instead of one", and the transformation is one-way (an extent once reflinked "permanently pays the double-lookup cost"). — [PoO §2.3](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**Checksumming, compression, encryption, erasure coding, multi-device**
- Checksums live in the btree alongside pointers (extent-granular), forming a chain of trust from superblock/journal to extents. — [PoO §2.1, §9.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Encryption is AEAD ChaCha20/Poly1305 with nonce and MAC stored with each data pointer; consequently encryption is hard-incompatible with nocow, and mounting an externally-snapshotted encrypted volume read-write causes nonce reuse. — [PoO §2.1.2, §2.1.2.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Erasure coding is Reed-Solomon over whole buckets, exploiting bucket allocation and copygc. — [PoO §2.2 / §9.9](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Feature list on the homepage: COW, full data+metadata checksumming, multiple devices, replication, erasure coding, caching and data placement, compression, encryption, snapshots, scrub, nocow mode, reflink, xattrs/ACLs/quotas. — [bcachefs.org](https://bcachefs.org/)
- Crash semantics are specified as a prefix property; overwriting `rename` waits for the source file's data writeback, which the manual says is stronger than ext4/btrfs/XFS but costs package-manager-style workloads. — [PoO §1.4](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

### Inferences
- The data-oriented content of bcachefs is concentrated in a few separable ideas: (a) big append-only nodes re-sorted in memory into ≤3 runs; (b) an implicit (eytzinger) index with one 4-byte entry per cacheline of keys, built per immutable run; (c) per-node key packing with a format descriptor; (d) batching of small updates through journal + key cache + write buffer; (e) generation numbers instead of pointer rewrites. None of these depends on Linux, on POSIX, or on the rest of bcachefs.
- The "everything is keys in a few btrees" model fits a data-oriented kernel well: it is essentially a struct-of-tables design with uniform transaction and recovery machinery, and new record types (e.g. capability grants, per-program store descriptors) could be added as new btrees.
- The optimistic-restart transaction model forces all code to be idempotent. That is a pervasive discipline, not a library feature; adopting the model means adopting the discipline everywhere.
- The design assumes kernel-side locking (six locks, per-node locks, cycle detection across many threads). A kernel that keeps itself out of the I/O path and favours per-core, shared-nothing or ring-based designs might prefer a single-writer or per-core partitioned variant rather than bcachefs's lock-heavy concurrency.

### Gaps
- No published, reproducible lookups-per-second or cache-miss benchmark for the auxiliary search trees was found; the "order of magnitude" claim is the author's own. Overstreet's unfinished FAST paper repo has a TODO for benchmarks against other btrees.
- The older bcachefs.org "Architecture" wiki page returned HTTP 404 in this session; the manual (PoO) now carries that content.
- Exact wording of "16 nodes per cacheline, prefetch four levels" was only seen via a search summary of the FAST draft, not read in full.

---

## 2. Current status up to November 2026

### Takeaway
bcachefs was merged for Linux 6.7, marked "externally maintained" in 6.17, and deleted from mainline in 6.18; since late 2025 it ships only as an out-of-tree DKMS module (Linux 6.16+), has dropped its "experimental" label by the maintainer's own declaration (June 2026, v1.38.6), and remains essentially a single-maintainer, Patreon-funded project.

### Cited Findings

**Timeline (dates as given by sources)**
- 21 Aug 2015: bcachefs announced. 2017: Patreon funding begins. Mid-2018: on-disk format settles. — [Wikipedia: Bcachefs](https://en.wikipedia.org/wiki/Bcachefs)
- October 2023: merged for Linux 6.7; January 2024: Linux 6.7 released. — [Wikipedia: Bcachefs](https://en.wikipedia.org/wiki/Bcachefs); [The Register, 1 Jul 2025](https://www.theregister.com/2025/07/01/bcachefs_may_get_dropped/)
- 7 Apr 2024: Torvalds — if anyone thought bcachefs was stable, he has "a bridge to sell you". August 2024: Torvalds — "nobody sane uses bcachefs and expects it to be stable". 29 Aug 2024: the Debian maintainer orphans bcachefs-tools. — [Wikipedia: Bcachefs](https://en.wikipedia.org/wiki/Bcachefs)
- August 2024: Torvalds "pushed back ... as well as expressing regret for merging BcacheFS into mainline Linux." — [Hackaday, 10 Jun 2025](https://hackaday.com/2025/06/10/the-ongoing-bcachefs-filesystem-stability-controversy)
- November 2024: the kernel Code of Conduct Committee restricts Overstreet's pull requests for the 6.13 cycle (Phoronix 20 Nov; patch thread 22 Nov). 21 Jan 2025: bcachefs changes merge normally for 6.14. — [Wikipedia: Bcachefs](https://en.wikipedia.org/wiki/Bcachefs)
- June 2025 (6.16-rc): Overstreet sends a `journal_rewind` feature inside a "fixes" pull during the rc phase. Torvalds first declines (rc3), then merges it for 6.16-rc4 while writing: "I think we'll be parting ways in the 6.17 merge window" and "You made it very clear that I can't even question any bug-fixes and I should just pull anything and everything." — [Phoronix](https://phoronix.com/news/Bcachefs-One-Week-Later-Merge); [The Register, 1 Jul 2025](https://www.theregister.com/2025/07/01/bcachefs_may_get_dropped/). Wikipedia dates the announcement 26 June 2025 — [Wikipedia](https://en.wikipedia.org/wiki/Bcachefs). Some outlets (Linux Magazine, Linuxiac) describe this as the code being "dropped" rather than merged; Phoronix's account (merged in rc4, with the parting-ways warning) is the more precise.
- August 2025: no bcachefs updates merged for 6.17; MAINTAINERS status changed from "Supported" to "Externally maintained". — [Wikipedia](https://en.wikipedia.org/wiki/Bcachefs)
- 11 Sep 2025: Overstreet announces DKMS distribution. — [Wikipedia](https://en.wikipedia.org/wiki/Bcachefs)
- 30 Sep 2025 (LWN date): Torvalds removes bcachefs entirely for 6.18 (commit f2c61db29f27): "It's now a DKMS module, making the in-kernel code stale, so remove it to avoid any version confusion." LWN's editor noted Torvalds "did not make it alone, and it followed a long series of public and private discussions." — [LWN, "Bcachefs removed from the mainline kernel"](https://lwn.net/Articles/1040120/)

**Out-of-tree distribution**
- "As of 6.18, bcachefs is no longer being distributed with the kernel." "The DKMS package supports Linux 6.16 and later." Packages: apt.bcachefs.org (Debian/Ubuntu), Fedora COPR, openSUSE OBS; Nix and Arch carry it in distro packages. — [bcachefs.org (page last edited 24 Jul 2026)](https://bcachefs.org/)
- The filesystem source now lives inside the **bcachefs-tools** repo (`fs/` directory): "ships as a DKMS kernel module built from this tree"; `scripts/install-to-kernel.sh` can install `fs/` into a kernel tree. — [github.com/koverstreet/bcachefs-tools](https://github.com/koverstreet/bcachefs-tools)
- DKMS transition began with Linux 6.17 and bcachefs-tools 1.31.5; openSUSE disabled in-kernel bcachefs from 6.18. — [Linuxiac](https://linuxiac.com/linux-kernel-6-18-to-ship-without-bcachefs/)
- Out-of-tree risk raised by kernel developers in the LWN thread: mainline will not keep internal APIs stable for an external module; removal stops bcachefs selecting `XARRAY_MULTI`, `CLOSURES`, `MIN_HEAP`; comparison made to ZFS losing access to kernel symbols. — [LWN comments](https://lwn.net/Articles/1040120/)
- Breakage in practice: a CachyOS thread reports a kernel update (6.18.9-2, early 2026) breaking bcachefs boot. — [CachyOS forum](https://discuss.cachyos.org/t/update-to-6-18-9-2-breaks-bcachefs-and-limine/22638/8)

**Releases and format versions (from the manual's own version table)**
- On-disk metadata versions: 1.31 `btree_node_accounting` (2025-09); 1.32 (2025-11); **1.33 `reconcile` (2025-11)**; 1.34 (2025-12); 1.35, 1.36 (2026-01); **1.37 `erasure_coding` (2026-03) "First release with fully supported erasure coding"**; 1.38 (2026-03); **1.39 `per_dev_fragmentation_lru` (2026-07)**. — [PoO §11.6](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- 1.33 was described as the "biggest new feature in the past ~2 years" (reconcile). — [Linuxiac](https://linuxiac.com/?p=203140)
- 1.37 (March 2026) added Linux 7.0 support and marked erasure coding stable. — [Phoronix](https://phoronix.com/news/bcachefs-1.37-released)
- **June 2026, v1.38.6 ("the performance release")**: Overstreet: "We're no longer experimental. I took the label off the website" — removed "a few months ago", announced belatedly ("Consider this the belated official announcement :)"). The Register covered it 19 Jun 2026; Linuxiac 20 Jun 2026; Phoronix benchmarked it 22 Jun 2026. — [Linuxiac](https://linuxiac.com/bcachefs-is-no-longer-experimental-but-caution-still-applies/); [Phoronix review](https://phoronix.com/review/bcachefs-1386)
- Conflicting note: a July 2026 blog claims the project's Kconfig still labelled the filesystem experimental and that only erasure coding lost the tag. Single low-authority source; unresolved. — [youngju.dev, 16 Jul 2026](https://www.youngju.dev/blog/2026-07-16-bcachefs-erasure-coding-not-experimental.en)

**On-disk format stability**
- Forward compatibility: "a newer release can always mount a filesystem an older release made", upgrading in place by running recovery passes. Backward by default; only an explicit `version_upgrade=incompatible` is one-way, and `bcachefs downgrade` can revert it. "Support for the very oldest formats is eventually dropped". — [PoO §3](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- The format is still changing: nine metadata version bumps between 2025-09 and 2026-07 (see table above). — [PoO §11.6](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**Funding, team, direction**
- Homepage: "we need funding!", directing to Patreon; paid support and feature-development contracts offered by email; no sponsor list. — [bcachefs.org](https://bcachefs.org/)
- Rust: userspace tools already rewritten in Rust; plan to add Rust bindings to the DKMS module, first for unit/performance tests as an optional dependency. — [Linuxiac](https://linuxiac.com/bcachefs-is-no-longer-experimental-but-caution-still-applies/). The repo contains `Cargo.toml`, `bch_bindgen/`, `bcachefs-shim/`, and a `verus-proofs/` directory. — [bcachefs-tools repo](https://github.com/koverstreet/bcachefs-tools)
- In 2026 the project runs an LLM-authored blog ("ProofOfConcept") presented as an AI co-developer of bcachefs; commenters largely read it as a joke or a worrying sign. — [Tildes discussion](https://tildes.net/~tech/1tpi/rat_park). Secondary reports say Overstreet stated on Patreon that the assistant is conscious; not verified against the Patreon post itself.
- "Full online fsck, check and repair (in progress)" is still listed as in-progress on the homepage. — [bcachefs.org](https://bcachefs.org/)

### Inferences
- "No longer experimental" is a self-declaration by the maintainer, not a third-party certification; no distribution or vendor was found treating bcachefs as a supported production filesystem.
- For a fork, the status history matters less than two facts: the code base is alive and moving fast (format bumps roughly every 1–2 months), and its governance is one person with a record of process conflicts. A fork would have to either track a fast-moving upstream or freeze a snapshot and own it forever.
- Removal from mainline has a silver lining for third-party reuse: the filesystem now lives in a self-contained tree (`bcachefs-tools/fs/`) that already builds against multiple kernel versions and against a userspace shim, i.e. it is already more decoupled from a single kernel version than an in-tree filesystem.

### Gaps
- No verified information on releases or events between August and 9 November 2026 (Wikipedia, last edited 31 Oct 2026, lists none). The latest confirmed format version is 1.39 (2026-07).
- Exact merge day for 6.7 (**[background, unverified]** ~30–31 Oct 2023) and 6.7 release day (**[background, unverified]** 7 Jan 2024) were only confirmed to the month.
- Linux 6.18's exact release date was not verified (**[background, unverified]** late Nov/early Dec 2025).
- Number of paid developers, Patreon income and any corporate sponsors: no reliable figures found.
- Phoronix pages returned HTTP 403 to direct fetch; Phoronix facts are from search summaries.
- One report puts the code removed from mainline at ~117k lines; not traced to a primary source.

---

## 3. Licensing

### Takeaway
bcachefs is GPL-2.0; copying its code into the kernel proper would make the combined kernel a GPL-2.0 work regardless of the repo's current MIT licence, so a "fork into the kernel" is a licence change in practice. Reimplementing the ideas (which are not copyrightable) or isolating GPL code in a separate user-space storage server are the only ways to keep an MIT kernel.

### Cited Findings
- The target repo's `LICENSE` file is the MIT License ("Copyright (c) 2026 Sacha"). — local file `/home/user/kernel/LICENSE` (inspected 2026-11-09)
- bcachefs / bcachefs-tools are GPL-2.0 (`COPYING` in the repo; SPDX `GPL-2.0` headers, e.g. `eytzinger.h`). — [bcachefs-tools repo](https://github.com/koverstreet/bcachefs-tools); [eytzinger.h in Linux 6.14 tree](https://gbmc.googlesource.com/linux/+/refs/heads/linux-6.14.y/fs/bcachefs/eytzinger.h)
- Per notes from a Jan 2024 call with Hurd developers: bcachefs is GPLv2; "many of Kent's previous employers, including Google, own patents"; Kent is "ok with potentially making the license GPLv2+" (paraphrase by the Hurd author, not a commitment). — [bug-hurd, Jan 2024](https://lists.libreplanet.org/archive/html/bug-hurd/2024-01/msg00097.html)
- Combining permissive code with GPLv2 code is allowed, but the combined binary must be distributed under GPL terms with complete corresponding source for the entire work. — [Software Freedom Conservancy, "GPL Violations Related to Combining ZFS and Linux"](https://sfconservancy.org/blog/2016/feb/25/zfs-and-linux/)
- ZFS is CDDL; SFC holds that CDDLv1 is incompatible with GPLv2 for a combined kernel binary, SFLC and Canonical took the opposite view for loadable modules; the question is described as unsettled. — [SFC](https://sfconservancy.org/blog/2016/feb/25/zfs-and-linux/); [LWN coverage](https://lwn.net/Articles/676860/)
- RedoxFS is MIT-licensed: "Being MIT licensed, RedoxFS can be bundled on GPL-licensed operating systems". — [docs.rs/redoxfs](https://docs.rs/crate/redoxfs/latest)
- lwext4 illustrates the contamination problem at file granularity: mostly BSD-3-Clause, but `ext4_extents.c` and `ext4_xattr.c` are GPLv2 and the repo LICENSE was changed to GPL2 in 2017; a BSD build requires removing those files. Its Rust wrapper is MIT/Apache by default and GPL-2.0 when the GPL features are enabled. — [lwext4 README](https://git.carlh.net/cgit/lwext4/tree/README.md); [docs.rs ext4-lwext4](https://docs.rs/crate/ext4-lwext4/0.1.1)
- Fuchsia's Fxfs lives in the Fuchsia tree (`//src/storage/fxfs`), written in Rust. — [Fuchsia RFC-0136](https://fuchsia.dev/docs/contribute/governance/rfcs/0136_fxfs)

### Inferences
- Licence matrix for "can I copy code into an MIT kernel and stay MIT?": bcachefs (GPL-2.0) no; btrfs (GPL-2.0, **[background]**) no; OpenZFS (CDDL, file-level weak copyleft) — CDDL files must stay CDDL but can be combined with MIT code, which is why FreeBSD/illumos/macOS/Windows ports exist; HAMMER2 (BSD, **[background]**) yes; RedoxFS (MIT) yes; Fxfs (BSD-style Fuchsia licence, **[background]**) yes; APFS closed source, only a read-oriented format reference published (**[background]**).
- Because the target kernel keeps storage in user space, a GPL filesystem server running as an isolated process and speaking the kernel's IPC/ring protocol is the cleanest legal structure: the kernel stays MIT, the server is GPL, and they are separate works communicating at arm's length. This is the same boundary argument used for user-space programs on Linux; it is an inference, not legal advice, and the IPC ABI headers would have to be MIT.
- Even in that structure, the "default system image" would ship a GPL component. If the project's goal is a fully permissive stack (as Fuchsia, Redox and the BSDs chose), bcachefs code is disqualified and only its ideas are usable.
- Patent exposure noted in the Hurd thread is an additional, unquantified risk of taking the code rather than the published ideas.

### Gaps
- No primary FSF statement was fetched for the GPLv2-into-MIT case; the direction of compatibility is well established but should be confirmed against the FSF licence list/FAQ before a decision.
- HAMMER2, Fxfs, btrfs and APFS licence statements were not individually verified in this session.
- Whether Overstreet would actually relicense (e.g. dual-license) for a non-Linux kernel is unknown; contributor copyright is spread across many authors, which normally makes relicensing impractical.

---

## 4. Portability: coupling to Linux, the userspace shim, and precedents for porting filesystems

### Takeaway
bcachefs already compiles and runs most of its kernel code in user space on top of a Linux-API shim (used for fsck, format, and a FUSE mount), which proves the core is separable — but the shim *is* a re-implementation of a wide slice of Linux kernel API (bio, block devices, workqueues, kthreads, shrinkers, wait queues, timers, percpu, RCU via liburcu). No completed port to a non-Linux kernel was found; the only documented attempt (GNU Hurd, 2024) stalled for lack of manpower.

### Cited Findings

**The userspace build / shim**
- "90% of the Bcachefs filesystem code builds and runs in userspace"; the shim maps kernel locking primitives to pthreads and the kernel I/O API to AIO. — [bug-hurd, Jan 2024 (notes of a call with Overstreet)](https://lists.libreplanet.org/archive/html/bug-hurd/2024-01/msg00097.html)
- bcachefs-tools has a `linux/` directory with files including `bio.c`, `blkdev.c`, `kthread.c`, `workqueue.c`, `shrinker.c`, `wait.c`, `timer.c`, `sched.c`, `percpu.c`, `preempt.c`, `mempool.c`, `semaphore.c`, `llist.c`, `kobject.c`, `fs.c`, `fs_parser.c`, `generic-radix-tree.c`, `printk.c`, `atomic64.c`, zstd wrappers and a `unicode/` dir (file roles inferred from names). — [bcachefs-tools/linux](https://github.com/koverstreet/bcachefs-tools/tree/master/linux)
- fsck: "can run fsck in userspace (-K), in the kernel at mount time (-k), or online on a mounted filesystem... In all cases the exact same fsck implementation runs". — [PoO §5.3](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- `bcachefs fusemount` exists as a subcommand; distributions package an "experimental implementation of bcachefs leveraging FUSE" providing `mount.fuse.bcachefs`. — [PoO command list](https://bcachefs.org/bcachefs-principles-of-operation.pdf); [openSUSE bcachefs repo package list](https://rsync.opensuse.org/repositories/filesystems%3A/bcachefs%3A/release/xUbuntu_25.10/Packages)
- Overstreet was "not certain" FUSE is a good way to run bcachefs in userspace; he wanted it mainly for debugging (attach GDB to a live filesystem). — [bug-hurd, Jan 2024](https://lists.libreplanet.org/archive/html/bug-hurd/2024-01/msg00097.html)
- Size: about 100,000 lines for bcachefs versus 150,000 for btrfs; the "core database transaction library" about 25,000 lines (figures as cited by the Hurd author, 2024). — [bug-hurd, Jan 2024](https://lists.libreplanet.org/archive/html/bug-hurd/2024-01/msg00097.html)

**Linux coupling visible in the manual**
- Own btree node cache integrated with Linux memory reclaim via a shrinker (`btree_cache_shrinker_seeks` tunable; node states "shrinker-eligible"). — [PoO §9.8.6 and options list](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- RCU/SRCU: btree node hash lookups use `rhashtable_lookup_fast` and are "RCU-safe"; key-cache entries "must wait for an SRCU barrier to complete before being freed". — [PoO §9.8.6 and debug counters](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Closures (refcounted async continuations) are embedded in btree updates; workqueue scheduling delay is a tracked latency source; read path uses `bio`s. — [PoO debug/time-stats sections](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- File data goes through the Linux page cache (buffered IO, dirty writeback delay, readahead "reads entire extents into the page cache"); casefolding uses the Linux Unicode subsystem (`CONFIG_UNICODE`); encryption keys come from the Linux kernel keyring; reflink flags depend on the VFS. — [PoO §1.4, §2.7, §9.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Kernel symbols bcachefs depends on that mainline may no longer keep for it: `XARRAY_MULTI`, `CLOSURES`, `MIN_HEAP`, `start_removing_user_path_at()`. — [LWN comments](https://lwn.net/Articles/1040120/)

**Attempted port: GNU Hurd**
- Proposal (Jan 2024) to port bcachefs to the Hurd because ext2 there has no journal. Options discussed: FUSE (bcachefs uses the low-level libfuse API; Hurd's libfuse described on IRC as "clearly broken"), libdiskfs, or netfs. Overstreet "ok with us merging a shim layer for libstore that maps to the Unix filesystem API." Status: "There are currently no concrete plans to do so due to lack of developer man power." — [bug-hurd](https://lists.libreplanet.org/archive/html/bug-hurd/2024-01/msg00097.html); tracking page: [hurd open_issues/bcachefs](https://hurd.ion.nu/open_issues/bcachefs.html)
- A targeted search found no bcachefs port to FreeBSD, Redox, or any other non-Linux kernel. — search performed 2026-11-09 (no positive result; absence of evidence)

**Precedents: how other filesystems cross kernels**
- OpenZFS: one code base with per-OS glue under `module/os/<platform>/` and the SPL ("Solaris Porting Layer") providing Solaris kernel APIs (kmem, taskq, condvar, cred, atomics) on the host. FreeBSD 13.0 switched to the unified OpenZFS 2 code base. — [OpenZFS SPL tree (FreeBSD contrib mirror)](https://src.rcs.uwaterloo.ca/xref/freebsd-src/sys/contrib/openzfs/module/os/linux/spl); [OpenZFS wiki history](https://openzfs.org/wiki/Special:MobileDiff/149)
- OpenZFS on macOS required enhancing the SPL with "a memory management layer based on the illumos kmem and vmem allocators". — [O3X SPL description](https://kandi.openweaver.com/c/openzfsonosx/spl)
- OpenZFS on Windows: a 2017 proof-of-concept ("ZFSin") had the core working with large parts missing; in May 2026 the project wiki still says "current status: beta release candidate" (zfswin-2.4.x rc builds) — roughly nine years from PoC to still-beta. — [openzfsonwindows wiki](https://github.com/openzfsonwindows/openzfs/wiki); [OpenZFS Summit 2017 slides](https://openzfs.org/w/images/f/f9/06-Porting_with_OSX.pdf)
- HAMMER2 (DragonFly): ported by one developer (Tomohiro Kusumi) to FreeBSD, NetBSD and OpenBSD as separate GitHub repos; ports started read-only, write support deferred/"experimental"; the OpenBSD repo README says it will be abandoned once another target is stabilized with write support. — [Phoronix on the NetBSD port](https://www.phoronix.com/news/NetBSD-HAMMER2-Port); [FreshPorts filesystems/hammer2](https://freshports.org/filesystems/hammer2); [DragonFly users list, Oct 2023](https://lists.dragonflybsd.org/pipermail/users/2023-October/452206.html)
- lwext4: a from-scratch ext2/3/4 library for microcontrollers, embedded by several small OSes (RIOT, XiUOS, rCore via `lwext4_rust`) — an independent reimplementation of an on-disk format rather than a port of kernel code. — [lwext4 on GitHub mirrors](https://github.com/mudita/lwext4); [rcore-os/lwext4_rust](https://github.com/rcore-os/lwext4_rust)
- LKL (Linux Kernel Library): compiles the Linux kernel into an object linkable into POSIX and Windows user-space programs; `lklfuse` mounts Linux filesystem images without root; flagged experimental with a data-corruption warning. — [github.com/lkl/linux](https://github.com/lkl/linux)
- Rump kernels / anykernel (NetBSD): unmodified kernel drivers, including filesystems, run as user-space servers; costs include slower synchronous metadata paths. — [Wikipedia: Rump kernel](https://en.wikipedia.org/wiki/Rump_kernel); [Kantee thesis, Aalto](https://aaltodoc.aalto.fi/items/e3be8d40-47c4-4f87-87d2-7c663175e176/full)

### Inferences
- Three distinct technical routes exist for "using bcachefs" on a new kernel:
  1. **Port via the existing userspace shim**: implement the `linux/` shim's back end (threads, block I/O, memory, timers, RCU substitute) on the new kernel's native primitives and run bcachefs as a user-space storage server. This matches the target kernel's "kernel out of the I/O path" principle and is the lowest-effort way to get a working, compatible bcachefs. It inherits the Linux concurrency model (pthreads + locks + workqueues) wholesale, which is the opposite of a data-oriented, ring-based design, and the FUSE path it resembles is the least-loved, least-tested part of bcachefs.
  2. **Fork**: take `fs/` and rewrite the Linux-facing layers (VFS glue, page cache, bio, shrinkers, closures) natively. This means owning ~100k+ lines of intricate concurrent C whose upstream changes its on-disk format every 1–2 months.
  3. **Reimplement the ideas** on a new on-disk format with no compatibility goal.
- The ZFS precedent shows a porting layer works when the original OS API is small and stable (Solaris kernel API) and many funded people maintain it; even so, Windows is still beta after ~9 years. The HAMMER2 precedent shows a single skilled developer can get *read-only* ports quickly and that write support is where ports stall.
- The Linux kernel API that bcachefs targets is explicitly unstable; a shim tracking upstream bcachefs must also track Linux API churn indirectly (e.g. folio conversions), which is the same treadmill the DKMS module is now on.
- The page cache dependency does not transfer: a kernel without a global page cache/VFS needs its own answer for buffered file data, mmap, and writeback; bcachefs's metadata engine (which avoids the page cache by design) is the portable part, its data path is not.

### Gaps
- The `linux/` shim file listing was partial and file roles were inferred from names; whether `six.c`, `closure.c`, `rhashtable.c` live there or elsewhere in the tree was not confirmed. The "90% builds in userspace" figure is from January 2024.
- No quantified effort estimate (person-months) for any bcachefs port exists in the sources.
- Current write-support status of the HAMMER2 BSD ports (two FreshPorts descriptions conflict) was not checked against the repos.
- Whether the bcachefs FUSE mount is functional in 2026 releases was not verified.

---

## 5. Alternatives and inspirations

### Takeaway
For a sandboxed, user-space-storage, permissively-licensed kernel, the closest existing design is not bcachefs but Fuchsia's Fxfs (a user-space, Rust, LSM-tree object store addressed by object ID with directories optional) combined with SPDK-style polled user-space NVMe access; bcachefs contributes the best-documented cache-conscious B-tree and bucket/generation allocator, ZFS and HAMMER2 the pooled-storage/dataset and cheap-snapshot models.

### Cited Findings

**Fuchsia Fxfs**
- Proposed in RFC-0136 (accepted; design dated Oct 2021) to replace Minfs, which is single-threaded, uses a physical journal with high write amplification, and has hard limits on directory size and inode count. — [Fuchsia RFC-0136](https://fuchsia.dev/docs/contribute/governance/rfcs/0136_fxfs)
- Metadata lives in LSM trees ("Mutations are written out sequentially in batches, rather than piecemeal"); in-memory layer is a skip list; immutable layers need no locking. Stated downsides: "all operations require metadata space, even deletions", and slower reads with many layers. — [RFC-0136](https://fuchsia.dev/docs/contribute/governance/rfcs/0136_fxfs)
- Objects are "identified by a 64-bit unsigned integer that is unique within the store"; directories are optional: "it is possible to use an object store and just refer to objects using object IDs." Stores are hierarchical (root parent store in memory → root store → child stores holding user data). — [RFC-0136](https://fuchsia.dev/docs/contribute/governance/rfcs/0136_fxfs)
- Logical (not physical) journal for multi-object atomic transactions; COW data with checksums; allocator is reference-counted extents in an LSM tree ("Initially Fxfs will only support reference counts of one"); snapshots and clones listed as things it "might eventually want" (not implemented in the RFC). Written in Rust for "Memory safety — fewer crashes and fewer security issues." — [RFC-0136](https://fuchsia.dev/docs/contribute/governance/rfcs/0136_fxfs)

**ZFS / OpenZFS**
- CDDL-licensed; portable across illumos, FreeBSD, Linux, macOS, Windows through the SPL (see §4). — [SFC](https://sfconservancy.org/blog/2016/feb/25/zfs-and-linux/); [OpenZFS SPL tree](https://src.rcs.uwaterloo.ca/xref/freebsd-src/sys/contrib/openzfs/module/os/linux/spl)
- bcachefs positions itself against it: "copy on write (like zfs)"; and claims "a cleaner, simpler, higher performance design" than ZFS and btrfs. — [bcachefs.org](https://bcachefs.org/); [PoO §1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**btrfs**
- bcachefs contrasts itself: btrfs snapshots clone COW btrees, bcachefs versions individual keys; btrfs/ZFS-style COW filesystems use 4K page-cache-backed metadata nodes. — [PoO §1.1, §2.4](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- btrfs gained basic zoned (host-managed SMR) support in Linux 5.12; ZNS active-zone management was still being stabilized in 2022. — [btrfs zoned talk abstract](https://www.pagure.io/flock/issue/339); [linux-nvme list, Sep 2022](https://lists.infradead.org/pipermail/linux-nvme/2022-September/034889.html)

**HAMMER2 (DragonFly BSD)**
- Design by Matthew Dillon, v1 dated 08 Feb 2012, revisions through v6 (08 Dec 2018); default DragonFly filesystem. COW block tree of `blockref`s; a snapshot is made by "copying the volume header's root block table (4 blockref entries)"; each blockref tracks `modify_tid` and `mirror_tid`; the freemap does not reference-count allocations (it tracks free blocks), which is what makes writable snapshots cheap. — [HAMMER2 DESIGN](https://gitweb.dragonflybsd.org/dragonfly.git/blob/9b8b748f5ae6af42fcdda02fba2b052633d7dfac:/sys/vfs/hammer2/DESIGN); [dragonflybsd.org/hammer](https://dragonflybsd.org/hammer/)

**APFS**
- Volumes in one container share a single free-space pool; clones are COW file copies (`clonefile`) that initially share blocks. — [Wikipedia: Apple File System](https://en.wikipedia.org/wiki/Apple_File_System); [Apple APFSCloning sample](https://developer.apple.com/library/archive/samplecode/APFSCloning/Listings/README_md.html)

**RedoxFS**
- Default filesystem of Redox OS, "inspired by ZFS and adapted to a microkernel architecture"; COW, data+metadata checksums, transparent encryption; runs as a user-space daemon, also mountable on Linux via FUSE; MIT; latest crate 0.9.1. — [docs.rs/redoxfs](https://docs.rs/crate/redoxfs/latest)

**SPDK / blobstore (kernel out of the I/O path)**
- Blobstore is "designed for asynchronous, uncached, parallel reads and writes to groups of blocks on a block device called 'blobs'"; a blob is an ordered list of fixed-size clusters; metadata operations are confined to one thread because "Blobstore is designed to be lock-free"; supports thin provisioning, read-only snapshots, clones, and "external snapshots". — [SPDK doc/blob.md](https://src.rcs.uwaterloo.ca/xref/spdk/doc/blob.md)

**TigerBeetle-style deterministic storage**
- Explicit storage fault model: "detects and recovers from latent sector errors, disk corruption, and misdirected I/O where firmware or filesystem bugs might read or write the wrong sector." — [TigerBeetle docs: safety](https://docs.tigerbeetle.com/concepts/safety/)
- Deterministic Simulation Testing injects network and storage faults (misdirected/corrupt reads and writes) against the consensus protocol and LSM engine; on-disk determinism (identical grid across replicas) is exploited for block-level repair; an "LSM forest" of separate trees per index. — [TigerBeetle docs: data file](https://docs.tigerbeetle.com/about/internals/data_file)

**LSM vs B-epsilon (BetrFS)**
- BetrFS (FAST '15) is "the first in-kernel file system to use a write-optimized index"; the authors report it still needed tuning to match general-purpose filesystems on "deletes, directory renames, and large sequential writes." — [USENIX FAST '15](https://www.usenix.org/conference/fast15/technical-sessions/presentation/jannen)
- Earlier write-optimized filesystems in user space suffered because FUSE "superimposes many reads on a write-intensive workload". — [BetrFS TOS paper (Jannen et al.)](https://www.cs.unc.edu/~porter/pubs/a18-jannen.pdf)

**Twizzler (object/capability, data-centric)**
- USENIX ATC 2020: "removes the kernel from the I/O path", gives programs memory-style access to persistent objects using 64-bit object-relative cross-object pointers; YCSB 1.1–2.9× faster than SQLite back ends on NVM. — [USENIX ATC '20, Bittman et al.](https://www.usenix.org/conference/atc20/presentation/bittman)

**Zoned storage**
- f2fs is cited by the kernel docs as "a regular POSIX-compliant file system with native zoned block device support"; zonefs instead exposes each zone as a file; XFS also has zoned support. — [kernel.org zonefs documentation](https://www.kernel.org/doc/Documentation/filesystems/zonefs.rst)

### Inferences
- **B-tree with journalled updates (bcachefs) vs LSM (Fxfs, TigerBeetle) vs Bε-tree (BetrFS)** all solve the same problem — turning random metadata updates into sequential writes. bcachefs's node is effectively a tiny LSM inside each B-tree node (append-only bsets, in-memory compaction into ≤3 runs), keeping B-tree read latency while getting batched writes. For a latency-sensitive desktop kernel this hybrid is attractive because it avoids global compaction stalls and bloom-filter machinery; the Fxfs RFC itself lists read cost and space-for-deletes as LSM downsides.
- Fxfs's "object store by 64-bit ID, directories optional, stores nested per consumer" matches "no global namespace; each program has its own store" far more directly than a POSIX filesystem with subvolumes bolted on.
- SPDK blobstore shows a workable minimal layer for a kernel-bypass design: single-threaded lock-free metadata, async polled I/O, blobs with snapshots/clones — but no checksums, directories, or transactions across blobs; it is a foundation, not a filesystem.
- TigerBeetle's main transferable idea is methodological: design the storage engine to be deterministic and single-threaded-per-core so the whole thing can be fuzzed under simulated disk faults. bcachefs's reliability problems (§7) were found in the field by users; a new filesystem for a new kernel cannot afford that route and has no user base to do it.
- Candidate synthesis for the target kernel: bcachefs-style node format (large append-only nodes + eytzinger aux index + packed keys) and generation-numbered buckets; Fxfs-style object stores keyed by ID with per-program stores; key-versioned snapshots (bcachefs) or root-copy snapshots (HAMMER2); SPDK-style polled user-space device access; TigerBeetle-style deterministic simulation testing.

### Gaps
- Not researched to source level in this session (time budget): WAFL, F2FS internals, SerenityOS's filesystem, KeyKOS, Venti/Fossil, Nix store, OSTree, git-like stores, io_uring NVMe passthrough (`uring_cmd`), ZFS ARC and send/receive documentation. **[background, unverified]** pointers for the writer: WAFL originated write-anywhere + snapshot-by-root-copy (Hitz et al., USENIX 1994); Venti (Quinlan & Dorward, FAST 2002) is a write-once store addressed by SHA-1 with Fossil as the mutable front end; Nix store and OSTree are immutable content/hash-addressed trees shared by hard links/checkouts; KeyKOS provided orthogonal persistence via system-wide checkpoints with capabilities ("keys") as the only naming; SerenityOS uses its own ext2 implementation; io_uring passthrough exposes NVMe commands via `IORING_OP_URING_CMD` (Linux 5.19+). None of these statements were verified here.
- No head-to-head benchmark of bcachefs vs Fxfs vs ZFS metadata engines exists in the sources consulted.
- TigerBeetle's use of direct I/O was not confirmed by the sources found.

---

## 6. Per-application storage views in sandboxed systems, and mapping subvolumes/snapshots/reflinks onto "one private store per program"

### Takeaway
Every mainstream sandboxed system implements per-app storage as a *policy layer over one shared filesystem* (per-app directories plus namespace/ACL/mediator enforcement), not as per-app filesystems; Fuchsia is the cleanest model (the framework hands each component a handle to its own subdirectory and nothing else). COW features map well onto this: a subvolume or object store per program, reflink/clone as the zero-copy "grant a copy" primitive, and snapshots as per-program versioning — but bcachefs-specific limits (quota bypass on snapshots, one-way reflink indirection, encryption nonce constraints) show the mapping is not free.

### Cited Findings

**Fuchsia (capability-routed storage)**
- A storage capability "allocate[s] per-component *isolated* storage within a filesystem directory"; this "prevents component instances from accessing files belonging to other components, including their own children." — [Fuchsia docs: storage capabilities](https://fuchsia.dev/docs/concepts/components/v2/capabilities/storage)
- Mechanism: a provider declares a `backing_dir` (a directory capability); on first access "the framework generates a unique subdirectory inside the backing directory for that component", named by a 256-bit instance ID (stable across moves: "Instance IDs allow a component's storage to persist across changes to the component's moniker") or by moniker. — [Fuchsia docs](https://fuchsia.dev/docs/concepts/components/v2/capabilities/storage)
- Stated escape hatch: "The backing directory capability can also be routed directly to other components. Providing this capability allows components to access all the isolated storage directories it contains." — [Fuchsia docs](https://fuchsia.dev/docs/concepts/components/v2/capabilities/storage)
- Storage classes with different durability contracts: `data` (never deleted by the system), `cache` ("may be deleted by the system at any time, even while the component is running"), `tmp` (may be deleted between runs). — [Fuchsia docs](https://fuchsia.dev/docs/concepts/components/v2/capabilities/storage)

**iOS / macOS containers**
- At install time the system creates container directories in the app's sandbox; the data container holds app and user data, and an app is "generally prohibited from accessing or creating files outside its container directories." — [Apple File System Programming Guide: File System Basics](https://developer.apple.com/library/ios/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
- APFS volumes in a container share free space; clones are COW copies. — [Wikipedia: APFS](https://en.wikipedia.org/wiki/Apple_File_System)

**Android scoped storage**
- "In Android 11 or higher, SDCardFS is deprecated and MediaProvider becomes the file system handler (for FUSE) for external storage". — [AOSP: Scoped storage](https://source.android.com/docs/core/storage/scoped)
- On Android 11, "apps can no longer access files in any other app's dedicated, app-specific directory within external storage." — [Android developers: storage updates in Android 11](https://developer.android.com/about/versions/11/privacy/storage)
- Internal app-private storage (`/data/data`) and external private dirs (`Android/data`, `Android/obb`) bypass FUSE (per the localized AOSP page; not confirmed in the English text). — [AOSP: Scoped storage](https://source.android.com/docs/core/storage/scoped?hl=it)

**Plan 9**
- Namespaces are per process and manipulable by ordinary users through `bind` and `mount`; fork flags allow shared, blank, or restricted namespaces (no further mounts). — [OLS 2005 paper on Plan 9-style namespaces for Linux](https://www.kernel.org/doc/ols/2005/ols2005v2-pages-229-242.pdf); [Plan 9 bind(2)](https://mail.typewritten.org/Manual/Bell/Plan9/4ed/man2/bind.html)

**bcachefs primitives relevant to the mapping**
- Subvolume = independent directory tree (root inode + snapshot ID); O(1) writable snapshots; "millions" feasible. — [PoO §9.4](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Quotas: user/group/project; project quotas can act as subdirectory quotas; "Writes to snapshot subvolumes bypass quota enforcement entirely." — [PoO §2.5](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Reflink: shared extents live in a refcounted `reflink` btree; one-way indirection with a permanent two-lookup read cost. — [PoO §2.3](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- A subvolume and its snapshots can set different per-file I/O options (compression, replicas, targets) on shared data. — [PoO §2.4, §7.2.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- Single master key per filesystem for encryption (external snapshots "share the same master key"). — [PoO §2.1.2.1](https://bcachefs.org/bcachefs-principles-of-operation.pdf)

**Fxfs primitives relevant to the mapping**
- Child object stores hold user data separately; objects are addressed by ID with directories optional. — [RFC-0136](https://fuchsia.dev/docs/contribute/governance/rfcs/0136_fxfs)

### Inferences
- **Common pattern**: one pool, one allocator, one filesystem; isolation comes from *what handle the program is given* (Fuchsia), *kernel sandbox profile + container path* (iOS), *UID + a mediating user-space daemon* (Android), or *a per-process mount table* (Plan 9). None gives each app its own block-level filesystem; sharing one free-space pool is universally preferred.
- A kernel with no global namespace is closest to Fuchsia's model, minus the escape hatch: the store service holds the only reference to the whole pool and hands each program a capability to its own store root.
- **Mapping COW features onto "one private store per program, sharing only by explicit grant"**:
  - *Store per program* → a subvolume (bcachefs/btrfs), dataset (ZFS), volume (APFS) or child object store (Fxfs). Needs per-store quota/accounting; bcachefs's per-snapshot accounting btree and backpointers help, but its quota model is UID/project-based and bypassed in snapshots, so a per-store quota would have to be designed, not inherited.
  - *Grant by copy* → reflink/clone: the receiver gets an independent COW copy at near-zero cost; no ongoing shared mutable state, which fits a sandbox model well. In bcachefs this imposes a permanent extra lookup on the donor's extents.
  - *Grant by reference (live sharing)* → hand out a capability to a specific object or sub-tree, read-only or read-write (Fuchsia directory capabilities; Plan 9 `bind`). This is a namespace/capability feature, independent of the on-disk format.
  - *Snapshots* → per-program undo/versioning, atomic app updates, and safe "run this program against a throwaway snapshot of my documents" (writable snapshot granted, then discarded or merged). Key-versioned snapshots (bcachefs) make per-store snapshots O(1) and cheap in large numbers.
  - *Immutable shared data* (program binaries, libraries, assets) → content-addressed or reflinked read-only objects shared across stores, deduplicated by construction.
  - *Per-store encryption* → wants a key per store (as iOS-style per-app protection would); bcachefs has one master key per filesystem, so this would need new design; Fxfs anticipated per-file/per-volume keys as a future goal.
  - *Storage classes* (Fuchsia `data`/`cache`/`tmp`) map naturally onto per-store I/O options (replication, durability, evictability) — bcachefs's per-inode/per-subvolume options and "cached data in generation-numbered buckets" give a precedent for system-reclaimable cache stores.
- POSIX semantics (paths, hard links across directories, rename atomicity, UID/GID/mode) account for a significant share of bcachefs's complexity (dirents, quotas, casefolding, 32-bit inode compatibility, rename-overwrite writeback rules). A kernel without a global POSIX namespace can drop much of it at the store layer and offer POSIX only as a compatibility library inside a program's own store.

### Gaps
- Flatpak portals (document portal / FUSE at `/run/user/$UID/doc`) and Windows AppContainer (per-package `LocalAppData\Packages` directories + capability SIDs) were not researched to source level; **[background, unverified]** both follow the same "private per-app directory + brokered access to user-chosen files" pattern.
- What Fuchsia does with a component's storage when the instance is destroyed is not stated on the page consulted.
- Whether iOS data containers use APFS-level features (per-file keys, clones) beyond directories + sandbox profiles was not confirmed from Apple documentation.
- No source was found describing anyone using bcachefs subvolumes as a per-application sandbox mechanism.

---

## 7. Blunt assessment: effort and risk of forking vs reimplementing, and reliability criticisms

### Takeaway
The sources support neither a fork nor a direct port as a foundation for a new permissively-licensed, data-oriented kernel: bcachefs is GPL-2.0, ~100k+ lines of Linux-idiom concurrent C with a still-moving on-disk format, one maintainer, and a contested reliability record. The defensible options are (a) run upstream bcachefs unmodified as an optional, isolated GPL user-space server via its shim for compatibility, and/or (b) reimplement a deliberately small subset of its ideas natively.

### Cited Findings

**Reliability criticisms**
- Torvalds (Apr and Aug 2024): if anyone thought bcachefs was stable he has "a bridge to sell you"; "nobody sane uses bcachefs and expects it to be stable"; expressed regret for merging it. — [Wikipedia](https://en.wikipedia.org/wiki/Bcachefs); [Hackaday](https://hackaday.com/2025/06/10/the-ongoing-bcachefs-filesystem-stability-controversy)
- Hackaday (10 Jun 2025): "it has become clear that BcacheFS is rather unstable, with frequent and extensive patches being submitted"; "at best an experimental Alpha-level filesystem implementation"; "should probably not be used with important data or systems"; "if you want a reliable COW filesystem in Linux, you are best off using btrfs or ZFS." (Journalistic opinion based largely on a YouTube summary and one corruption report.) — [Hackaday](https://hackaday.com/2025/06/10/the-ongoing-bcachefs-filesystem-stability-controversy)
- The Debian maintainer orphaned bcachefs-tools in Aug 2024; Debian later removed the package and the project set up its own APT repo. — [Wikipedia](https://en.wikipedia.org/wiki/Bcachefs); [bcachefs.org](https://bcachefs.org/)
- Process criticism: feature code (`journal_rewind`, a recovery tool to roll the filesystem back) submitted as rc-phase "fixes"; Torvalds: "You made it very clear that I can't even question any bug-fixes". — [The Register](https://www.theregister.com/2025/07/01/bcachefs_may_get_dropped/); [Phoronix](https://phoronix.com/news/Bcachefs-One-Week-Later-Merge)
- June 2026 coverage of the "no longer experimental" declaration still advises caution: "it's still wise to be careful" for important data. — [Linuxiac](https://linuxiac.com/bcachefs-is-no-longer-experimental-but-caution-still-applies/)
- Out-of-tree fragility: kernel updates have broken bcachefs boots for DKMS users (early 2026). — [CachyOS forum](https://discuss.cachyos.org/t/update-to-6-18-9-2-breaks-bcachefs-and-limine/22638/8)

**Maintainer's counter-position**
- Overstreet (LWN comments, Oct 2025): many bcachefs users migrated from btrfs after data loss; calls the "meme filesystem" framing unfair; says DKMS usage increased after the announcement. His claims are unsupported by hard data in the thread. — [LWN comments](https://lwn.net/Articles/1040120/)
- Overstreet's rationale for the label removal: bug reports slowing and looking less serious. — [Linuxiac](https://linuxiac.com/bcachefs-is-no-longer-experimental-but-caution-still-applies/)
- Design-level robustness arguments in the manual: idempotent restartable transactions make recovery itself crash-safe; the same fsck code runs offline, at mount, and online; `errors=fix_safe` default since 1.19; extensive self-healing sections per subsystem. — [PoO §1.2, §5.3](https://bcachefs.org/bcachefs-principles-of-operation.pdf)
- The project runs its own CI/test infrastructure (ktest, public CI dashboard) and has a `verus-proofs/` directory in the tree. — [bcachefs.org](https://bcachefs.org/); [bcachefs-tools repo](https://github.com/koverstreet/bcachefs-tools)

**Effort indicators**
- Size: ~100k lines (2024 figure), of which the core transactional btree library ~25k. — [bug-hurd](https://lists.libreplanet.org/archive/html/bug-hurd/2024-01/msg00097.html)
- Time-to-maturity: announced Aug 2015 as "more or less feature complete"; merged Oct 2023; declared non-experimental June 2026 — about 11 years from announcement, by a full-time author who had already written bcache. — [Wikipedia](https://en.wikipedia.org/wiki/Bcachefs); [Linuxiac](https://linuxiac.com/bcachefs-is-no-longer-experimental-but-caution-still-applies/)
- The only documented cross-kernel port attempt (Hurd) made no progress "due to lack of developer man power". — [bug-hurd](https://lists.libreplanet.org/archive/html/bug-hurd/2024-01/msg00097.html)
- Comparable port: OpenZFS on Windows, PoC 2017, still "beta release candidate" in May 2026. — [openzfsonwindows wiki](https://github.com/openzfsonwindows/openzfs/wiki)
- Fuchsia chose to write a new filesystem (Fxfs, Rust, user-space-oriented object store) rather than port an existing one, and expected performance to be "the most difficult to achieve and where most effort will be spent." — [RFC-0136](https://fuchsia.dev/docs/contribute/governance/rfcs/0136_fxfs)

### Inferences

**Option A — Fork bcachefs into the new kernel: not recommended.**
- Licence: converts the kernel (or at least its distributed image) to GPL-2.0, contradicting the repo's MIT licence.
- Architecture mismatch: bcachefs is built around a Linux in-kernel model (VFS + page cache + bio + workqueues + shrinkers + RCU, lock-based concurrency across many threads) and POSIX semantics. The target kernel rejects almost every one of those (no global namespace, kernel out of the I/O path, ring/batch-based, data-oriented). A fork would keep the on-disk format and the btree core and rewrite most of the rest — i.e. the cost of a reimplementation plus the cost of understanding 100k lines, plus permanent divergence from a fast-moving upstream with a single maintainer.
- Risk: inherits a reliability record that is disputed at best, with no ability to draw on upstream's bug-fix stream once diverged.

**Option B — Port upstream bcachefs as a user-space server via its Linux shim: feasible as an optional compatibility component, not as the native store.**
- Technically the most realistic way to get a full-featured COW filesystem quickly: implement the back end of the `linux/` shim (threads, locks, block I/O, timers, memory, an RCU substitute) on the new kernel and run the existing code unmodified, tracking upstream. Licence stays contained in a separate GPL process.
- Costs: requires POSIX-thread-like primitives and a Linux-like blocking I/O model on a kernel designed to avoid them; the user-space/FUSE path is the least exercised configuration of bcachefs (its own author was unsure it is a good way to run it); performance and data-oriented goals are not served; still a GPL dependency in the default image if it is the main store.
- Reasonable use: interoperability (read/write disks formatted on Linux), not the system's own storage.

**Option C — Reimplement the ideas in a small native store: the option the evidence favours.**
- Ideas are free to reuse and are thoroughly documented in the 131-page manual (on-disk format chapter included), unlike most filesystems.
- A minimal subset that captures most of the value for a desktop-class, single-device-first system: (1) transactional KV store with large append-only B-tree nodes, eytzinger aux index and packed keys; (2) journal + write buffer batching; (3) extents with checksums stored in the keys; (4) generation-numbered buckets with backpointers (keeps zoned devices and device evacuation possible later); (5) key-versioned snapshots and per-program stores as first-class objects; (6) reflink as the grant-by-copy primitive. Explicitly deferrable: erasure coding, multi-device tiering/reconcile, nocow, POSIX quotas, casefolding, in-place format upgrade/downgrade machinery, online fsck.
- What the subset cannot defer: crash consistency, a from-day-one fsck/repair story, and a deterministic fault-injection test harness (TigerBeetle-style), because a new kernel has no user base to shake out bugs. The bcachefs history (2015 → 2026) is the realistic warning about how long filesystem hardening takes even for an expert working full time; a reduced scope and a simpler concurrency model (single writer / per-core partitioning rather than six locks + cycle detection) are the available levers to shorten that.
- Risk: years of work before the store can be trusted with real user data; mitigations are a small format, simulation testing, and possibly Option B or a simple non-COW store as an interim.

**Decision summary for the reader**

| Criterion | Fork | Port (shim, user-space server) | Reimplement subset |
|---|---|---|---|
| Keeps kernel MIT | No | Yes (GPL isolated in a separate process; image still ships GPL code) | Yes |
| Fits no-global-namespace / capability model | Poor (POSIX VFS design) | Poor inside, can be wrapped | Native |
| Fits kernel-bypass, ring-based, cache-line-aware I/O | Poor outside the btree core | Poor | Native |
| Time to first working COW store | Long | Shortest | Long |
| Upstream dependency risk (single maintainer, format churn, governance) | High, then orphaned | High, continuous | None |
| Reliability burden | Inherit contested record + own divergence | Inherit upstream's, in its least-tested mode | Entirely self-made; needs simulation testing |
| Linux disk compatibility | Yes until divergence | Yes | No |

### Gaps
- No independent, quantitative reliability data exists for bcachefs (LWN itself notes nobody has hard numbers on filesystem reliability); all assessments are anecdote, maintainer claims, or commentary.
- No source gives a person-month estimate for forking, porting, or reimplementing; the effort judgments above are inferences from code size, project history and the precedents cited.
- Post-removal code quality signals (bug-tracker volume, CI pass rates in late 2026) were not examined.
- The claim that Overstreet called his AI assistant conscious, and its implications for project governance, rests on secondary reports only.
