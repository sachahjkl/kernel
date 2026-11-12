# Storage

This guide gives the model of the stored data of the system: what a program, a package and a principal keep, and how a program reaches only what it was granted. It also gives the format on the disk, the interface of the storage service, the limits, and the order of construction. Each part says if it is **built** or **not built**.

The terms are in `GLOSSARY.md`, section Storage. The versions and the date are in `ARCHITECTURE.md`, "Versions" and "The date".

## 1. The model

The model has three things, and two concepts that the system has already.

| Thing | What it is | Does it change? |
|---|---|---|
| Object | Bytes, named by their hash (BLAKE3, 32 bytes). A module, a font, a picture, the text of a note: the same thing | Never. A new content is a new object |
| Tree | An object that names other objects and trees: each entry is a name and a hash. A tree holds trees, so the hash of a tree fixes each byte under it | Never |
| Store | A cell that names one tree now. A commit moves it to another tree in one atomic step. The versions of a store are its history | Yes: it is the only thing that changes |

| Concept that exists | Its part |
|---|---|
| Principal | A key pair. It signs trees (a package is a signed tree), and its key encrypts its data (not built) |
| Grant, handle | Access: a handle on a tree or on a store reaches what is under it and nothing above it, with or without the right to change, and its grant can be revoked |

The four needs, in the model:

| Need | Answer |
|---|---|
| Reproducibility | A system is the hash of one tree. Two machines with the same hash run the same bytes |
| Providers of packages | A package is a tree that the key of a principal signs. A provider is a principal: no other concept |
| Data of an application | A store held for a principal, attached to the identity of the package: the key of its signer and its name. Not its hash: an update would lose the data. Not its name alone: any signer could take it |
| Delegated access | A handle on a tree or on a store: what is under it, nothing above; read only or not; revocable |

What the model removes as a concept:

- **The system description is a package.** The system is the tree that holds the trees of its parts.
- **To install is to grant.** A principal adds the tree of a provider to its own tree, and grants it.
- **A folder is a tree.** The system has no other kind of folder, and no path that a program can name from nothing.
- **The boot image is a transport, not a concept.** It carries the objects that the machine needs before the storage service runs, one after the other. An image for a machine with no disk is the same transport with every object. An object can come by any channel: its hash proves it.
- **A package has no format of its own.** It is a signed tree with six facts beside its entries:
  1. its stable identity: the key of its signer and a name;
  2. the module that starts it, and the name that the desktop shows;
  3. the grants that it asks for;
  4. a version number that never goes back: an old signed tree cannot replace a newer one;
  5. where it comes from: the hash of its sources and of the recipe of its build, so that a third party can build it again and compare;
  6. its license.

### 1.1 Installation

Not built. These are rules of the model.

- **An installation runs no code of the package.** It has no script, no hook, and no step that changes the machine. It gets the objects that the tree of the package names and that the machine does not have, verifies each one by its hash, and keeps them. Nothing else changes until a principal adds the tree to what it holds: a grant, one atomic move of a store.
- **So an installation can be prepared before, cached, mirrored, shared between machines, stopped and continued, and undone** by a move of the store back to the tree before it.
- **A third party can build the same package.** The hash of a tree fixes each byte under it, and the build of a module gives the same bytes from the same source (`REPRODUCIBLE_BUILD.md`). A party that builds the package from its sources and its recipe gets the same hash: an object built before and an object built on the machine are the same object.
- **A cache of objects needs no trust.** The hash verifies each object. The signature of the tree says who vouches for the whole set.
- **What an application needs at its first start happens when it runs, inside its own grants:** it makes its data, or converts the data of an older version. Never at installation.

What these rules forbid, so that nobody adds it later:

- A package writes nothing outside its own data.
- A package does not register itself in a table of the machine by code that runs. What the system shows of a package (the module that starts it, the name that the desktop shows, the grants that it asks for) comes from the facts of its tree, read as data.
- A package does not depend on the order of the installations.

### 1.2 The hard points

**A large object that changes.** An object of 64 GiB is a tree of blocks. A write of a range makes new blocks for the range, and new nodes on the path from them to the root: copy on write, as the store does now. The hash of an object and the check of a block are one mechanism. BLAKE3 is itself a tree of chunks of 1 KiB: the hash of an object is the root of the chaining values of its chunks. If the check of a block is the chaining value of its 4 chunks, the hash of the object comes from the checks of its blocks, and a write of a range computes the hash of the changed blocks and of the parents above them only, about 2 log2(n) compressions of 64 bytes for n blocks. A chaining value depends on the offset of the chunk: two equal blocks at two offsets have two checks. Not built: today the check of a block is the hash of its 4096 bytes alone (8 bytes kept), and an object keeps a second hash of its bytes (section 3). The cost of the hash at each write is measured by the test of section 6: the time of a commit is printed.

**Removal.** Two trees can name one object. A remove takes a name out of a tree: it does not erase the bytes while another tree, or a version, names them. What a remove guarantees: the name is gone from the tree at the commit, and the blocks that nothing else names are free after the removal finishes (section 4.4). To erase bytes for certain needs the end of each version that names them, and then a write of zero bytes over their blocks: not built.

**Collection.** An object that no store reaches, through any tree or any version, can go. The disk counts the names of each block, so most blocks become free at the commit that drops their last name: no walk. The walk is needed only for what the counts cannot see: a shared object that a later step names by its hash from several stores. Its cost is one read of each node of each tree that a store reaches; it runs at the start of the service, which walks every block already to check it (section 3.3). Not built as a separate step.

**Secrecy.** The data of a principal are encrypted under a key of that principal. Then two principals with the same bytes have two different objects: the store does not share them across principals. This is intended: a shared object tells one principal what another one has. Not built.

### 1.3 Where the model does not hold as it was first stated

- **The hash of a tree is not fixed by its entries alone.** A tree on the disk is a B+ tree of nodes, and the form of a B+ tree depends on the order of the changes. Two trees with the same entries can have two different forms. Rule: the hash of a tree is defined on its entries in the order of their names, not on its nodes; a tree that a build writes whole (a system, a package) is written in that one form. A tree in a store that changes has no hash until it is sealed. Not built: no tree has a hash today.
- **A writable handle on a part of a store is a place, not a hash.** A tree never changes, so a handle on a tree is read only by nature. To let another program change a part of a store, the handle names the store and the names of the path from the root of the store to that part. Such a handle reaches what is under that path. If a program with a wider handle renames a tree above the path, the handle names what is at the path now: the handle follows the names, not the bytes.
- **The versions are still kept for each named object, not for the store.** In the model, the versions of a named object are found in the history of its store. The first step keeps the versions of each object of a tree, as the store keeps them now; the history of a store is a later step (section 7).

## 2. What exists, and how it maps on the model

| Today | In the model | State |
|---|---|---|
| A private store: one table of 39 named objects | A store of one program: it names one tree, with trees inside it | Built: section 3 |
| The name of an object (1 to 39 bytes) | A name of an entry of a tree (1 to 64 bytes) | Built |
| An object of a store, with its list of blocks | An entry of a tree that names an object: its hash and, in this step, where its blocks are | Built: the hash is kept; the blocks are still found through the entry, not by the hash |
| The versions of an object, their thinning | The history of a store | Kept for each object; the history of a store is not built |
| The system description (a signed list of hashes) | The tree of the system, signed by the publisher of the system | Not built |
| The boot image | The transport of the first objects | Not built: the image is still the one source of modules |
| The resources of the boot image (pointer themes, glyph caches) that the root service gives | Objects of the tree of the system, granted by handle | Not built |
| The hash of a module (P11) | The name of an object | The same BLAKE3 hash; modules are not in the store yet |
| A grant of the root service: the store of a connection and its limit | A handle on the store of a program, with its budget of blocks | Built: the connection is the handle |

## 3. The format on the disk

Built. The format is the contract `contract/store`, `STORAGE3`. A disk of `STORAGE2` is not read.

### 3.1 The blocks

- **Root block**: the generation, and one store entry for each store: its name, its limit of blocks, the blocks that it uses, and the pointer of its store block. The disk has two places for the root block.
- **Store block**: one for each store: the root node of its tree, the root node of its removal queue, and its counts (objects, trees, the blocks of the current objects, the nodes of its trees, the trees that the removal queue holds).
- **Node**: a node of the B+ tree of one tree. A leaf holds up to 24 entries; a branch up to 50 children. Each tree of a store is its own B+ tree: a tree inside a tree is an entry whose pointer names the root node of the inner tree.
- **List, data, version index, version leaf**: the blocks of an object and of its versions, as before.

A pointer is a block number and a check: the first 8 bytes of the BLAKE3 hash of the block.

### 3.2 An entry

| Field | An object | A tree |
|---|---|---|
| Name | 1 to 64 bytes, then zero bytes. No zero byte, no byte `/`, not `.` or `..` | the same |
| Kind | object | tree |
| Size | its bytes | its entries |
| Generation, time, date | of its last change | of its last change |
| Hash | BLAKE3 of its bytes | zero (not built) |
| Pointer | its list of blocks | its root node; none when it is empty |
| Versions | its version index | none |

A name is one step: it has no separator, and it never names the tree above. So a name that a program looks up under a place never reaches a node outside it.

In a branch, the name of the record 0 is a bound that the search never reads. It can be larger than the name of the record 1: a smaller name that goes into the child 0 splits it, and the new separator goes to the record 1. So the order of a branch is checked from its record 1.

### 3.3 The commit and the open

A commit is one change of one store. It changes the entries of the trees on one or two paths from the root of the store. Each changed node of each tree is written to a free block, then the node above it, up to the root node of the store, then the store block, then the root block: copy on write, as before. A loss of power leaves the disk with the last commit or the one in flight, never a mix: the tool checks each image that a loss can leave (section 6).

The open of the disk at the start walks each node of each tree once, checks each block, and counts the names of each block. A node that breaks a rule (its count, its level, the order of its keys) is damage, as a wrong check. A wrong node damages its store: the service gives nothing of that store and changes nothing in it. A wrong list or a wrong block of data damages its object only.

### 3.4 The limits

| Limit | Value | Reason |
|---|---|---|
| A name | 1 to 64 bytes | A key of 64 bytes gives 24 entries in a leaf with their hash: a store of a million objects has its entries in about 60000 blocks, inside the 262144 blocks of a disk |
| The levels of one B+ tree | 8 | With nodes a third full, 8 levels hold more entries than a disk can name. The open takes a deeper tree for damage |
| The trees on a path | 32 | A place holds the names of its path; a commit rewrites one tree on each level. 32 bounds both |
| The entries that one call adds | 256 | One commit writes at most 1024 blocks |
| An object | 32 blocks (128 KiB) | Unchanged: large objects are a later step |
| The disk | 262144 blocks (1 GiB) | Unchanged |
| The entries of a tree | No limit but the disk | |

## 4. The interface of the service

Built.

### 4.1 Places

A connection to the storage service is a handle on a store or on a part of it. A **place** is a number that a connection holds: the names of a path from the root of the connection, and the right to change or read only. The place 0 is the root of the connection: no call is needed to have it. Every export that names an entry takes a place and a name. A place is valid on its connection only; a call refuses a place of another connection (Absent, unit Places).

| Export | What it does |
|---|---|
| `open(place, name)` | The place of the tree `name` under `place` |
| `close(place)` | Frees the place |
| `add(place, rows, names)` | Adds up to 256 entries in one commit: each one an empty object or an empty tree. All or none |
| `write(place, name, data)` | Makes the object `name` the bytes of data, in one commit. The state before is a version |
| `read(place, name, result)`, `size(place, name)` | The bytes, the size |
| `list(place, after, rows, names)` | A page of the entries after the name `after`, in the order of the names: a table of rows (the place of the name in `names`, its count of bytes, the kind, the size, the generation) and the bytes of the names. A tree of a million entries is never given whole |
| `rename(place, name, to_place, to_name)` | Moves an entry, in one commit, inside one store. Refused when `to_name` exists, or when a tree moves into itself |
| `remove(place, name)` | Removes an object, or a tree and all under it (section 4.4) |
| `share(place, read_only)` | A new connection whose root is the tree of the place: two handles (its call ring and its call region) for the caller, to give to another program |
| `unshare(share)` | Ends a connection that `share` made |
| `usage()` | The counts of the store of the connection |
| `open_store(store)` | A place on the root of another store, for a caller that may name that store (section 4.2). Such a place reads, restores and clones; `write`, `add`, `remove`, `rename` and `share` refuse it |
| `versions`, `version`, `restore`, `clone`, `compare` | As before, on an object `name` under a place; no argument names a store |

### 4.2 No way up

- A name is one step (section 3.2): `..`, `.`, a name with `/`, and a name that starts with `/` are refused with the byte that breaks the rule.
- The store of a connection comes from the grant of the root service, or from the share that made the connection. One procedure of the service (`may_name_store`) decides if a caller may name another store, for `open_store` and for the lines of `stores`: a caller that acts for principal N names the stores of principal N only (the principal of a store is in its name: `principals.store_name_principal`); principal 0 names no store of a named principal; a caller that does not act for a principal, and a share, name their own store only.
- A place of another connection is refused.

### 4.3 Read only, and revocation

- A connection that `share` made with `read_only` refuses each change (No_Grant, unit Changes).
- `unshare` revokes the two handles of the connection: the kernel ends each holding that came from them, in each program (`Handle_Revoke`), and the service frees the connection and its places. A call on it gives Gone.
- When the grant of the store of a connection ends (the root service revokes it, or the connection closes), each connection that it shared ends too, at its next call.

### 4.4 The removal of a tree

A remove of a tree is one commit: its entry leaves its tree, and the tree goes into the removal queue of the store. The name is gone at that commit. The blocks under it stay counted in the store until the service frees them, in steps: each step is one commit that removes up to 64 entries of the first tree of the queue (an inner tree goes into the queue in its turn). The service runs a step when no call waits. So the cost of the call is one commit, whatever the size of the tree; the work after it is bounded for each commit, and a loss of power loses no step: the queue is on the disk. `usage` gives the trees in the queue.

### 4.5 Budgets

The limit of blocks of a store holds as before: it counts the nodes of its trees, its lists, its data and its versions. A limit for a part of a store is not built.

## 5. Not built: the next steps

Each step is one tested capability on a system that works.

1. **Large objects and ranges.** An object is a tree of blocks with no limit of 32 blocks; `read` and `write` of a range; a sparse object (a hole is a block that nothing names); the check of a block is its BLAKE3 chaining value, and the hash of the object comes from the checks (section 1.2). The disk past 1 GiB.
2. **The history of a store.** A version is a tree that a store named; the versions of an object are found in it. The thinning applies to the history of the store. The versions of each object go.
3. **Objects by their hash.** An index of the store from a hash to the blocks of an object: an object that two entries name is kept one time. The hash of a tree on its entries (section 1.3).
4. **The first objects from storage.** The boot image carries only what the storage service needs; the root service loads the other modules, the fonts and the pointer themes from the tree of the system, by hash.
5. **Packages.** A signed tree with its six facts; the store of the data of an application, attached to the identity of the package.
6. **Encryption for a principal.**
7. **The network as a channel.** An object comes from a peer; its hash proves it.

## 6. The tests

- Host tests of the B+ tree (`support/storage_tree`): inserts in a random order that split leaves and branches, a branch whose record 0 keeps a stale name, removes that merge and rebalance, the order of the keys, the pages of a listing, copy on write (the tree before a commit is still whole), the sizes of the format, the names that are refused.
- Host tests of the open (`support/storage_mount`): damage of a node and of a list, the recount of a store.
- The machine test of `hierarchy`: 100000 entries in trees inside trees, the listing in pages, a rename, the removal of a tree, 6000 names added to one tree in a fixed scrambled order (leaves and branches split in their middle) and half of them removed in another order (merges), then a second machine that opens the same disk and checks the counts and the contents. Each refusal of the confinement (`..`, `/`, a place of another connection, a change through a read-only share, a call after `unshare`). The time of the commits is printed as a measure.
- The losses of power (`kerneltool test power`): each image that a loss can leave opens, and gives the commit before or the commit in flight, each entry and each version byte for byte.
