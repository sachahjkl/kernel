// The format of the data disk: what the storage service writes, and what a
// tool reads to check or to damage a disk. A disk lives longer than the
// program that wrote it, so its format is a contract. The model (objects,
// trees, stores) is in docs/STORAGE.md.
//
// The disk is a row of blocks of 4096 bytes. Blocks 0 and 1 are the two
// places of the root block. Each other block is free, or it is a store
// block, a node, a list, a block of data, a version index or a version
// leaf. A block names another block with a Pointer: its number and the
// first 8 bytes of the BLAKE3 hash of its 4096 bytes.
//
//   root        the generation, and one Store_Entry for each store
//   store block one for each store: the root node of its tree, the root
//               node of its removal queue, and its counts
//   node        a node of the B+ tree of one tree: a leaf of entries (a name
//               and an Entry), or a branch of children (a name and a Pointer)
//   list        one for each state of an object that has bytes: the Pointers
//               of its data
//   data        the bytes of the object
//   version index, version leaf
//               for each object with versions: the index names the leaves,
//               a leaf holds Version_Entry records, the oldest first
//
// Each tree is its own B+ tree. An entry that names a tree holds the
// Pointer of the root node of that tree: a tree inside a tree. The entries
// of a tree are in the order of the bytes of their names.
//
// Versions (docs/ARCHITECTURE.md, "Versions"): each commit that changes an
// object keeps its state before it as a version. A list or a block of data
// can be named two times: by two versions, or by an object and its clone (a
// shared block). A store block, a node, an index and a leaf are named one
// time. A block is named from one store only.
//
// The rule (copy on write): a commit never writes a block that the root on
// the disk names. It writes each changed block to a free block, then the
// parents up to a new root, then the root in the place of the older of the
// two roots. Between these writes it asks the disk to keep what it wrote
// (Flush), so the blocks are on the disk before the root that names them.
// The root has its own check; at the start the service takes the valid root
// with the highest generation. A root that a stop of the machine cut is not
// valid: the root before it names blocks that no commit changed. So a store
// shows the state of one commit, never a part of one. Each block that a
// root names has its check in its Pointer: the start reads each one, and a
// change on the disk outside the service is found, not used.
//
// A list or a block of data with a wrong check under a valid root is
// damage, not a cut commit: its object is damaged, and the other objects
// are served. A store block or a node with a wrong check, or a node that
// breaks a rule of this format, damages its store.
package store

import "base:intrinsics"
import "contract:blake3"

BLOCK_SIZE :: 4096
ROOT_MAGIC :: u64(0x33454741524F5453) // The bytes "STORAGE3": the format with trees.
STORE_CAPACITY :: 60
LIST_CAPACITY :: 255
NAME_CAPACITY :: 32 // A name of a store: the name that the root service gives, with zero bytes after it.
DISK_BLOCKS_LIMIT :: 1 << 18 // 1 GiB: the service uses no block after this.
OBJECT_BLOCKS_LIMIT :: 32 // The bytes of one object: 128 KiB.

// The name of an entry: 1 to 64 bytes of UTF-8, with zero bytes after it
// in its key. A key of 64 bytes gives 24 entries in a leaf: a store of a
// million objects has its entries in about 60000 blocks, inside the blocks
// of a disk. A name has no zero byte (the padding), no byte '/' and is not
// "." or "..": a name is one step down, so no name reaches past the tree
// that it is looked up in.
ENTRY_NAME_CAPACITY :: 64

// The most levels of the B+ tree of one tree. With nodes a third full, 8
// levels hold more entries than a disk of DISK_BLOCKS_LIMIT blocks can
// name. The open takes a deeper B+ tree for damage, and no walk goes deeper.
TREE_DEPTH_LIMIT :: 8

// The most trees on a path from the root of a store: a place holds the
// names of its path, and a commit rewrites one tree on each level of it.
NESTING_LIMIT :: 32

Pointer :: struct {
	block: u64, // 0: no block.
	check: u64,
}

// The cell of one store (docs/STORAGE.md: the one thing that changes).
Store_Entry :: struct {
	name:  [NAME_CAPACITY]u8, // All zero: the place is free.
	limit: u64, // The most blocks of the store, as the last grant gave it.
	used:  u64, // The distinct blocks of the store: its store block, its nodes, its lists, its data, its versions.
	store: Pointer, // The store block.
}

Root :: struct {
	magic:       u64,
	generation:  u64,
	disk_blocks: u64,
	time:        u64, // The time since the format of the disk at this commit, in milliseconds.
	date:        u64, // The date of this commit in seconds since 1970 (UTC). 0: not known.
	reserved:    [3]u64,
	stores:      [STORE_CAPACITY]Store_Entry,
	padding:     [BLOCK_SIZE - 64 - STORE_CAPACITY * size_of(Store_Entry) - 8]u8,
	check:       u64, // The hash of the bytes before it.
}

// The block of one store: the root of its tree, its removal queue, and the
// counts that a commit needs with no walk.
Store_Block :: struct {
	tree:           Pointer, // The root node of the tree of the store. No block: the tree has no entry.
	removals:       Pointer, // The root node of the removal queue: a tree whose entries are trees to free, named by the 8 bytes of next_removal at their remove, big-endian.
	next_removal:   u64,
	objects:        u64, // The objects of the store, with those in the removal queue.
	trees:          u64, // The trees inside the tree of the store, with those in the removal queue.
	// The blocks of the current objects: each list and each block of data
	// of each one, a block that two objects share counted two times. With
	// node_blocks and the store block, the least that the store needs with
	// no version: a change past the limit with no version is refused.
	current_blocks: u64,
	node_blocks:    u64, // The nodes of all the trees of the store, and of its removal queue.
	removing:       u64, // The entries of the removal queue.
	reserved:       [4]u64,
	padding:        [BLOCK_SIZE - 112]u8,
}

Entry_Kind :: enum u64 {
	None   = 0,
	Object = 1,
	Tree   = 2,
}

// The key of an entry: its name, with zero bytes after it. The order of the
// bytes is the order of the entries: a shorter name comes before the names
// that start with it.
Entry_Name :: [ENTRY_NAME_CAPACITY]u8

// What an entry names.
Entry :: struct {
	kind:       Entry_Kind,
	size:       u64, // An object: its bytes. A tree: its entries.
	generation: u64, // The commit of its last change.
	time:       u64, // The time since the format at that commit, in milliseconds.
	date:       u64, // The date of that commit, in seconds since 1970 (UTC). 0: not known.
	hash:       [32]u8, // An object: the BLAKE3 hash of its bytes, its name in the model. A tree: zero.
	pointer:    Pointer, // An object: its list (no block when it has no byte). A tree: its root node (no block when it is empty).
	versions:   Pointer, // An object: its version index. No block: no version.
}

#assert(size_of(Entry_Name) == 64)
#assert(size_of(Entry) == 104)

// A node: the header, then `count` records. A record of a leaf is a name
// and its Entry; a record of a branch is a name and the Pointer of a child.
// In a branch, the name of the record n is at most each name under the
// child n, and more than each name under the child n - 1; the search does
// not read the name of the record 0. A node that a tree names is never
// empty, and its records are in the order of their names, each name once.
NODE_MAGIC :: u32(0x45455254) // The bytes "TREE".

TREE_HEADER_SIZE :: 32
Tree_Header :: struct {
	level:    u32, // 0: a leaf.
	count:    u32, // The records in use.
	magic:    u32, // NODE_MAGIC: a block of another kind is damage.
	reserved: u32,
	unused:   [2]u64,
}
#assert(size_of(Tree_Header) == TREE_HEADER_SIZE)

LEAF_CAPACITY :: (BLOCK_SIZE - TREE_HEADER_SIZE) / (size_of(Entry_Name) + size_of(Entry)) // 24
BRANCH_CAPACITY :: (BLOCK_SIZE - TREE_HEADER_SIZE) / (size_of(Entry_Name) + size_of(Pointer)) // 50

// One version of an object: its state at the commit of `generation`.
Version_Entry :: struct {
	generation: u64,
	size:       u64,
	time:       u64, // The time since the format, in milliseconds.
	date:       u64, // Seconds since 1970 (UTC). 0: not known.
	list:       Pointer, // No block: the object had no bytes.
}
#assert(size_of(Version_Entry) == 48)

VERSION_LEAF_CAPACITY :: 85
VERSION_INDEX_CAPACITY :: 254
VERSIONS_LIMIT :: VERSION_LEAF_CAPACITY * VERSION_INDEX_CAPACITY // 21590 versions of one object.

Version_Leaf :: struct {
	count:    u64,
	reserved: u64,
	entries:  [VERSION_LEAF_CAPACITY]Version_Entry, // The oldest first; count of them are used.
}

Version_Index :: struct {
	leaf_count:     u64,
	version_count:  u64, // The entries of all its leaves.
	retention_time: u64, // The time since the format of the last application of the retention rule to this object.
	reserved:       u64,
	leaves:         [VERSION_INDEX_CAPACITY]Pointer, // The oldest leaf first; leaf_count of them are used. No leaf is empty.
}

List :: struct {
	data:    [LIST_CAPACITY]Pointer,
	padding: [BLOCK_SIZE - LIST_CAPACITY * size_of(Pointer)]u8,
}

#assert(size_of(Root) == BLOCK_SIZE)
#assert(size_of(Store_Block) == BLOCK_SIZE)
#assert(size_of(List) == BLOCK_SIZE)
#assert(size_of(Version_Leaf) == BLOCK_SIZE)
#assert(size_of(Version_Index) == BLOCK_SIZE)

// check gives the check of a block: the first 8 bytes of its BLAKE3 hash.
check :: proc "contextless" (bytes: []u8) -> u64 {
	hash := blake3.hash(bytes)
	return intrinsics.unaligned_load((^u64)(&hash[0]))
}

// root_check gives the check of a root: the check of the bytes before its
// field check.
root_check :: proc "contextless" (value: ^Root) -> u64 {
	return check(([^]u8)(value)[:offset_of(Root, check)])
}

// root_valid says if a root block is one that a commit finished.
root_valid :: proc "contextless" (value: ^Root, disk_blocks: u64) -> bool {
	return value.magic == ROOT_MAGIC && value.check == root_check(value) && value.disk_blocks >= 2 && value.disk_blocks <= disk_blocks
}

// entry_name gives the key of a name. The name must have passed
// name_refusal, or be a name of the removal queue.
entry_name :: proc "contextless" (name: string) -> (key: Entry_Name) {
	copy(key[:], name)
	return key
}

// name_of gives the name of a key: its bytes before the first zero byte.
name_of :: proc "contextless" (key: ^Entry_Name) -> string {
	count := 0
	for count < ENTRY_NAME_CAPACITY && key[count] != 0 {
		count += 1
	}
	return string(key[:count])
}

// removal_name gives the name of an entry of the removal queue: the number
// of the remove, big-endian, so that the queue is in the order of the
// removes. It is no name of an entry that a program makes: it has zero
// bytes.
removal_name :: proc "contextless" (number: u64) -> (key: Entry_Name) {
	for index in 0 ..< 8 {
		key[index] = u8(number >> uint(56 - 8 * index))
	}
	return key
}

Name_Refusal :: enum {
	None,
	Empty,
	Too_Long, // More than ENTRY_NAME_CAPACITY bytes.
	Bad_Byte, // A zero byte or a byte '/': at `offset`. "." and "..": offset 0.
}

// name_refusal says why a name cannot be the name of an entry, or None. A
// name is one step down in a tree: it has no separator and does not name
// the tree above, so a name looked up under a place never reaches an entry
// outside it.
name_refusal :: proc "contextless" (name: string) -> (refusal: Name_Refusal, offset: int, byte: u8) {
	if len(name) == 0 {
		return .Empty, 0, 0
	}
	if len(name) > ENTRY_NAME_CAPACITY {
		return .Too_Long, 0, 0
	}
	for index in 0 ..< len(name) {
		if name[index] == 0 || name[index] == '/' {
			return .Bad_Byte, index, name[index]
		}
	}
	if name == "." || name == ".." {
		return .Bad_Byte, 0, '.'
	}
	return .None, 0, 0
}
