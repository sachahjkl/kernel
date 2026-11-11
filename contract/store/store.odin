// The format of the data disk: what the storage service writes, and what a
// tool reads to check or to damage a disk. A disk lives longer than the
// program that wrote it, so its format is a contract.
//
// The disk is a row of blocks of 4096 bytes. Blocks 0 and 1 are the two
// places of the root block. Each other block is free, or it is a table, a
// list or a block of data. A block names another block with a Pointer: its
// number and the first 8 bytes of the BLAKE3 hash of its 4096 bytes.
//
//   root     the generation, and one Store_Entry for each private store
//   table    one for each store: one Object_Entry for each object
//   list     one for each state of an object that has bytes: the Pointers
//            of its data
//   data     the bytes of the object
//   version index, version leaf
//            for each object with versions: the index names the leaves,
//            a leaf holds Version_Entry records, the oldest first
//
// Versions (docs/ARCHITECTURE.md, U5, "Versions"): each commit that
// changes an object keeps its state before it as a version. A list or a
// block of data can be named two times: by two versions, or by an object
// and its clone (a shared block). A table, an index and a leaf are named
// one time. A block is named from one store only.
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
// A block with a wrong check under a valid root is damage, not a cut
// commit: the object of the block is damaged, and the other objects are
// served. See programs/storage/engine.odin, mount.
package store

import "base:intrinsics"
import "contract:blake3"

BLOCK_SIZE :: 4096
ROOT_MAGIC :: u64(0x32454741524F5453) // The bytes "STORAGE2": the format with versions.
STORE_CAPACITY :: 60
OBJECT_CAPACITY :: 39 // 39 entries of 104 bytes in one block.
LIST_CAPACITY :: 255
NAME_CAPACITY :: 32 // A name of a store: the name that the root service gives, with zero bytes after it.
OBJECT_NAME_CAPACITY :: 40
DISK_BLOCKS_LIMIT :: 1 << 18 // 1 GiB: the service uses no block after this.
OBJECT_BLOCKS_LIMIT :: 32 // The bytes of one object: 128 KiB.

Pointer :: struct {
	block: u64, // 0: no block.
	check: u64,
}

Store_Entry :: struct {
	name:  [NAME_CAPACITY]u8, // All zero: the place is free.
	limit: u64, // The most blocks of the store, as the last grant gave it.
	used:  u64, // The blocks of the store: its table, its lists, its data.
	table: Pointer,
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

Object_Entry :: struct {
	name:       [OBJECT_NAME_CAPACITY]u8, // All zero: the place is free.
	size:       u64, // Bytes.
	generation: u64, // The commit of its last change.
	time:       u64, // The time since the format at that commit, in milliseconds.
	date:       u64, // The date of that commit, in seconds since 1970 (UTC). 0: not known.
	list:       Pointer, // No block for an object with no bytes.
	versions:   Pointer, // The version index. No block: the object has no version.
}
#assert(size_of(Object_Entry) == 104)

Table :: struct {
	objects: [OBJECT_CAPACITY]Object_Entry,
	padding: [BLOCK_SIZE - OBJECT_CAPACITY * size_of(Object_Entry)]u8,
}

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
#assert(size_of(Table) == BLOCK_SIZE)
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
