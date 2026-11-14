# Debug information must not change the code

## Purpose

A module is the same bytes with and without debug information. A module is named by the hash of its bytes, and its debug object names that hash. So a module that anyone built with no debug information, also a third party, can get its debug object later: a build of the same sources with debug information gives the same module, and the debug object of that build describes it. The hash of a module also does not depend on whether a developer asked for line tables.

How the build asks for this and how the check proves it is in [`docs/REPRODUCIBLE_BUILD.md`](../../../docs/REPRODUCIBLE_BUILD.md), "8. The debug information". This file records why the form is an option of the compiler, and which forms were refused.

## Constraints

- The option `-debug` of the compiler makes another program. It defines a constant that a source can read, it changes the default optimization mode, and at eight places the compiler makes code only when debug information is written.
- The system calls the code generator of LLVM itself, after the compiler. A difference that LLVM makes is outside the reach of the compiler.
- The same sources with the same options give the same bytes. The fault here is not a fault of the reproducible build: it is a difference between two sets of options.
- Other users of the compiler want the aids for a debugger that `-debug` gives them.

## The chosen form

**A kind of debug information that a build asks for**, as an option of a fork of the compiler: `-debug-info:<none|full|same-code>` (`docs/DECISIONS.md`, D-246). It replaces the first form, which changed what `-debug` does (`docs/DECISIONS.md`, D-239).

- **The rule.** For any other flags, the code that the compiler gives to LLVM with `same-code` is the code with `none`. The rule has no exception for an optimization mode. One predicate in the compiler says "debug information keeps the code", and each of the eight places asks it.
- **The default is untouched.** With no such option, the fork builds what the release builds: `full` with `-debug`, `none` without. So the change can go to the project of the compiler as an addition, and a user of the compiler who does not ask loses nothing.
- **An option of its own, not a value of `-debug`.** `-debug` does three things, and two of them change the program by design: the constant and the default optimization mode. The option names only the third: what is written.
- **The build of the system asks for it.** The compile of a module passes `same-code`. The build with no debug information passes nothing.
- **The code generator gets one direction of its instruction scheduler**, top-down, in both builds. With the default direction, two modules of 88 still differ at the optimization mode of the build.
- **The third build stays a condition of the full check.** The rule of the option ends at the input of LLVM. Only a build proves the machine code.

## The refused forms

- **Change what `-debug` does in optimized builds.** This was the first form. It removes the aids for a debugger from every user of the compiler, for a need that this system has. The project of the compiler has no reason to take it.
- **One build mode only, and no third build.** If every build has debug information, no two builds can differ. It gives up the case of the purpose: a module that a third party built with no debug information.
- **The third build as a measure that the check prints.** The rule would then hold by habit. A measure that nobody reads lets the property decay.
- **A newer LLVM alone.** Measured: 87 of 88 modules are the same bytes. A newer LLVM removes one variance and has one of its own.
- **The direction of the scheduler set inside the compiler.** The interface of LLVM 18 that the compiler uses has no option of the target machine for the scheduler. The other way is the command line options of the LLVM library, which are not stable: the name of this option changes in LLVM 20. It is also a choice of code generation that changes the build with no debug information, so it is not a part of the rule of the option.
- **The mode only above the lowest optimization modes.** The rule would have an exception. The price of no exception is in the subtle points.
- **A patch file in the flake.** The changes are commits of a fork that the flake pins by one commit. A reader sees their history and their reasons there.

## The subtle points

- **The constant "debug build" stays false.** In the mode, the constant has the value that `-debug` gives it, and the build passes no `-debug`. No constant says which kind of debug information is written: a source that reads it can change with it, and the rule is then false.
- **The mode that optimizes least describes no local variable and no parameter.** There, a debug value of a load changes the instruction selection of LLVM. The mode keeps the rule and loses the variables. The system does not build with that mode.
- **The variance of the scheduler is inside LLVM.** For the two modules that differ, the compiler gives the same input and the optimizer gives the same output. The scheduler of machine instructions, bottom-up, orders register copies in another way when debug instructions stand between them. LLVM also has a variance in its inliner, which no module of the system shows today.
- **The check is the proof.** For the machine code, the rule is a measure on the modules of the system with one version of LLVM. A change of a source, of a flag or of LLVM can show a new difference. The full check then fails and names the module.
- **A hash of a deployed module changes** when the option or the flag of the code generator changes. The top-down direction changes the code of 79 of 88 modules against the default direction. The effect on speed is not measured.
- **What a debugger loses.** A variable that is not in a stack slot of its own can read as "optimized out". A label has no block. For the system at the optimization mode of its build, the loss was measured on two modules: none for the kernel, and 0.3 % of the location coverage of the local variables for one program. It was measured by counts of the debug information, not in a session of the debugger of the system.
- **The comparison of the study is on objects**, before the link and the conversion. The check of the system compares module files.
- **A debug object holds paths of sources**, from the root of the repository. A move of a source changes the debug object and not the module. See [repository_layout.md](repository_layout.md).

## State

Built:

- The fork with the option, pinned by the flake. With no option it gives the output of the release, measured on the modules of the system and on the tests of the compiler.
- The build asks for `same-code` and for the top-down direction. The full check passes: every module is the same bytes with and without debug information.
- A debug object names the hash of the module of its own build, and a reader uses it only for a loaded module with that hash.

Left:

- The pull request of the option to the project of the compiler. Until then the system needs the fork.
- LLVM 22, with a new measure of the modules that differ.
- A debug object for a module that another build made. The tool writes a debug object only beside the module of the same build. No command builds the sources again for a deployed module and refuses to write the debug object when the hash of the rebuilt module differs from the hash of the deployed one.
