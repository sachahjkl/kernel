title: A store holds trees of a hundred thousand objects
date: 2026-11-12
release: next
picture: none
kind: Shown
guide: docs/STORAGE.md

The store of a program now holds trees: a tree names objects and other trees, and has no limit of entries but the disk. Before, a store held 39 objects. A program reaches a tree through a place of its connection, and a name is one step down: no name reaches the tree above. A program can give a part of its store to another program, read only or not, and revoke it. The machine test makes 100000 objects in 1100 trees, lists them in pages of 16, moves a tree of 1000 objects in one commit, removes a tree of 1001 objects, and finds every count and every content again after a new start of the machine. The guide gives the model behind it: objects named by their hash, trees, and stores.
