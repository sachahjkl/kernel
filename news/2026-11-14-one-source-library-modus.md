title: A program names the system by one name, modus
date: 2026-11-14
release: next
picture: none
kind: Decided
guide: docs/MODULE_CONTRACT.md

Everything that becomes the system is now in one folder of the repository, `src`: the kernel, the boot program, the programs, the modules, and the code that the programs share. That shared code is one source library. Its name is `modus`, and its folder is `src/library`. A source imports a package of it with one line, such as `import "modus:support/system"` or `import "modus:contract/ring"`. The first word after the name says what the package is: `contract` is what two parties agree on, and `support` is what a program compiles in to use the contracts. The compiler gets the library with one flag, `-collection:modus=src/library`. A program in another repository writes the same lines and gives the same flag. The kernel imports the contract packages only. The tool reads each import of the kernel and of the contract packages before each build, and a build stops on an import that this rule refuses.
