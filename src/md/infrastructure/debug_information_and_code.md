# Debug information must not change the code

A module is the same bytes with and without debug information. Then the debug object of a module that was built without it can be made later from the same sources, and the hash of a module does not depend on whether a developer asked for line tables (`docs/DECISIONS.md`, D-239).

How the build checks this is in [`docs/REPRODUCIBLE_BUILD.md`](../../../docs/REPRODUCIBLE_BUILD.md), "8. The debug information". This file records where the property breaks, and what each correction costs.

## What the check found

The full check builds every module a third time with no debug information and compares the bytes. Three modules of 88 differed: the two builds of the kernel, and one program.

This is not a fault of the reproducible build. The same sources with the same options give the same bytes for the 88 modules. It is a fault of the tools: the option that asks for debug information changes the instructions.

## The two layers of the cause

A study of the compiler separated two causes. The method matters as much as the result: compare the input of the optimizer with the debug information stripped, then the output of the optimizer, then the object. Each comparison names one layer.

### The front end of the compiler

With an optimized build, the front end emitted other instructions when debug information was asked. Four places:

1. **A stack slot for a debug variable.** A variable whose address is not a stack slot (a pointer argument, an argument passed by pointer, the context pointer, a named result) got a new slot and a store of its address, only so that a debugger finds it. The store also kept pointers alive that a dead instruction pass deletes otherwise. This is the cause of the program that differed.
2. **A basic block for a label.** A labelled loop, switch, condition or block got one more block and one more jump only with debug information. The control flow graph changed.
3. **A copy of a range value** of one form of loop, for a debugger.
4. **An attribute "do not inline"** on generated procedures, which changes only an optimized build.

A fork of the compiler corrects the four. Places 2, 3 and 4 change no final byte of the system today: they remove differences of the input of the optimizer that the system does not exercise. They stay in the correction, because a change of a source of the system can make them appear.

With the correction, the input of the optimizer is the same with and without debug information, for the 88 modules and for the tests of the compiler. Two modules still differ.

### The code generator of LLVM

The two builds of the kernel differ in one function, by the order of three register moves after one inline assembly. The cause is in the code generator, not in the compiler:

- The input of the optimizer is the same. The output of the optimizer is the same.
- The machine code is the same until one pass: the scheduler of machine instructions. In its bottom-up direction, it places a copy of a physical register in another order when debug instructions stand between the copies.

A second variance exists in the optimizer of the same LLVM: the inliner visits procedures in another order with debug information. No module of the system shows it today.

## The choices that remain

The compiler cannot remove the variance of the code generator through the interface of LLVM that it uses. The system calls the code generator itself, so the system can choose. Each choice was measured on the 88 modules.

| Choice | Result | Cost |
|---|---|---|
| The top-down direction of the scheduler, as an option of the code generator | 88 of 88 equal | The code of 79 modules changes against the default direction. The effect on speed is not measured. It is a result on these inputs, not a guarantee |
| The code generator of the next LLVM, on the intermediate form of this one | 88 of 88 equal | Two versions of LLVM in one build |
| The compiler built against a newer LLVM | 87 of 88: another module differs | Not enough alone: a newer LLVM has a variance of its own |
| A correction of the scheduler in LLVM | Not done | The exact line is located to the pass and the direction, not proven |

No choice is made here. The check stays a condition: the property depends on passes of LLVM that do not guarantee it, so only a build proves it.

## The refused forms

- **The third build as a measure, not a condition.** A measure that nobody reads lets the property decay. The full check fails until the property holds.
- **A patch of the compiler carried in the flake.** An earlier patch of the compiler was removed on purpose. The correction lives in a fork that the flake pins, and goes to the project of the compiler when it is proven on the 88 modules.
- **A newer LLVM as the answer.** Measured: it moves the variance to another module.

## The subtle points

- **What the correction loses.** In an optimized build, a variable of the first kind that no instruction uses can be reported as "optimized out", and the range variable of one form of loop has no debug variable. The debug information was checked by counts of its entries, not in a debugger session.
- **The hash of one deployed module changes** with the corrected compiler: the program that differed. With the top-down direction, the code of 79 modules changes.
- **A constant of the language says "debug build".** A source that tests it gets other code by design. No package of the system reads it, and none must.
- **The comparison of the study is on objects**, before the link and the conversion. The check of the system compares module files.
- **A debug object holds paths of sources**, from the root of the repository. A move of a source changes the debug object and not the module. See [repository_layout.md](repository_layout.md).

## State

The fork exists with its four corrections and is not yet the compiler of the flake. The full check fails on this point only. The choice for the code generator is open.
