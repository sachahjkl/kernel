title: An object of 8 GiB that holds 13 blocks, and a commit that hashes what changed
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/STORAGE.md

An object of a store is now a tree of blocks, and can hold 4 TiB. A block of zero bytes is a hole: it costs no block and reads as zero bytes. The machine test makes an object of 8 GiB with three writes; it holds 13 blocks. A program writes ranges of an object, then commits them in one step. The commit hashes the blocks that changed and the nodes above them, never the whole object: 1000 small writes spread over the object of 8 GiB, then one commit, hash 1001 blocks and 1018 nodes, and the test checks that bound. An old version still reads its old bytes, and shares its other blocks with the new state. A loss of power in a loop of range commits leaves the last commit or the commit in flight, never a mix.
