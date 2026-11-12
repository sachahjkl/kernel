title: The module graph, on the site and in the running system
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

The reference of the site has a page for the module graph: each module and program of the build is a bar as long as its bytes, and each import is a line from the importer to the module that it imports. The columns follow the depth of the imports; the modules with no import and no importer are in a band under them. A pointer or the focus on a module marks its lines and its neighbours and shows its identity card: its hash, its size, its counts of exports and imports, its license and its purpose. A table under the picture gives every import. Each module page shows its own card and a small figure of its neighbours. In the running system, `manual.edges()` gives the same graph for what is loaded now: which program holds which module, which module imports it, and which import a replacement changed.
