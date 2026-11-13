# Vector forms: SSE2

This document says which procedures of the system compute with vectors, in which form, what stays scalar, and how to measure each one. The terms are in `docs/GLOSSARY.md`: scalar form, vector form, usable instruction set, extended state.

**The idea in plain words.** A processor has registers that hold several numbers side by side, and instructions that compute on all of them at once. A procedure that works on many pixels or many words can use them: it does the work of four values with one instruction. That is its **vector form**. The same procedure written with one value for each instruction is its **scalar form**. In this system a procedure that has a vector form also keeps its scalar form, and the two must give the same bytes for every input: the vector form is only faster, never different. Host tests compare the two, so a fault of the vector form shows as a wrong byte, not as a wrong picture.

**What has a vector form today.** Three procedures, all with the 128-bit registers of SSE2:

| Procedure | Scalar form | Vector form | Values for each step |
|---|---|---|---|
| The blend of a glyph | `blend_coverage_row_in_order` (`support/graphics/blend.odin`) | `blend_coverage_row_sse2` (`support/graphics/blend_vectors_amd64.odin`) | 4 pixels |
| The blend of a picture with premultiplied alpha | `blend_premultiplied_alpha_row_scalar` (`support/graphics/blend.odin`) | `blend_premultiplied_alpha_row_sse2` (`support/graphics/blend_vectors_amd64.odin`) | 4 pixels |
| The BLAKE3 hash of a subtree of four chunks | `chunk_value`, four times (`contract/blake3/blake3.odin`) | `four_chunk_values_side_by_side` (`contract/blake3/chunks_side_by_side_amd64.odin`) | 4 chunks |

**What this document is not.** It is not the rule on the vector registers of the kernel. The kernel has no vector instruction at all, and it saves the registers of each thread: `docs/ARCHITECTURE.md`, "The extended state of the processor". It is not the design of the blend in linear light either: `docs/FONTS.md`, "The blend in linear light".

**For whom.** A reader who writes or changes a vector form, and a reader who measures one.

**The map of this document.** Section 1: the rule of the same bytes. Section 2: why one form, SSE2. Sections 3 to 5: the blend of a glyph, the compositor, BLAKE3. Section 6: how to measure on the machine. Section 7: limits.

## 1. The rule of the same bytes

**The rule**: a vector form gives the same bytes as its scalar form, for every input. Two facts of the system need it. The screenshots of the system are compared byte for byte. One source gives one module, and the hash of a module is its identity: a hash that depends on the form is not a hash of the content.

How a vector form keeps the rule:

- **Integers only.** A vector form does the arithmetic of the scalar form in lanes (a lane is the part of a register that holds one value), with the same widths of the intermediate values. It rounds nowhere where the scalar form does not.
- **The scalar form stays beside each vector form.** It has three uses: it is the reference of the host tests, it is the code of a target that is not amd64, and it is the code of the last values of a row that do not fill a group of the vector form.
- **No load and no store outside the slice of the caller.** A vector form loads and stores a group of values only when the whole group is inside the slice. The columns after the last whole group go through the scalar form. It allocates nothing.
- **One public procedure.** The caller does not choose a form. The public procedure chooses at compile time, by the target:

```odin
blend_premultiplied_alpha_row :: #force_inline proc "contextless" (to: [^]Color, from: [^]u32, count: int) {
	when ODIN_ARCH == .amd64 {
		blend_premultiplied_alpha_row_sse2(to, from, count)
	} else {
		blend_premultiplied_alpha_row_scalar(to, from, count)
	}
}
```

**The host tests** compare each vector form with its scalar form on inputs from a generator with a fixed seed, so each host gets the same inputs:

- every length from 0 to 67;
- every place of the input against a boundary of 16 bytes (a pixel is 4 bytes, so 4 places for a row of pixels; 16 places for the bytes of a hash);
- the edge values often: 0, 1, 254 and 255 in each byte, whole words of 0, of all ones and of full coverage;
- guard words before and after each row: a form that writes outside its columns changes them.

When a test fails, it gives the first wrong pixel, the value of each form, and the count of pixels changed outside the drawn columns. The tests of the blends are in `support/graphics/blend_vectors_test_amd64.odin` (`coverage_forms_give_the_bytes_of_the_scalar_form`, `coverage_forms_meet_each_channel_value`, `premultiplied_forms_give_the_bytes_of_the_scalar_form`, `premultiplied_forms_meet_each_channel_value`). The tests of the hash are in `contract/blake3/chunks_side_by_side_test_amd64.odin` (`sse2_form_gives_the_hash_of_the_scalar_form`, `subtrees_side_by_side_at_each_counter`). `kerneltool check` runs them.

## 2. One form: SSE2

The vector forms use the 128-bit registers of SSE2. Two facts make this form free of conditions:

- **Every x86-64 processor has SSE2.** It is a part of the architecture, not an extension that one processor has and another lacks.
- **The kernel saves these registers for every thread**, at each switch of threads, on every processor (`docs/ARCHITECTURE.md`, "The extended state of the processor").

So a vector form needs no test of the processor and no choice at the start of a program: on amd64 the public procedure runs the SSE2 form, and on another target the scalar form.

**How a module is compiled.** A module is compiled for the plain x86-64 processor, with SSE2: for a module, `llc` gets no `-mattr` and no `-mcpu` (`build_module` in `tools/kerneltool/modules.odin`). The kernel is the one exception, in the other direction: it is compiled with every vector feature off (`KERNEL_TARGET_FEATURES`), and the build refuses a kernel that has a vector instruction outside the save and the restore of the extended state (`tools/kerneltool/vector_check.odin`). No vector form runs in the kernel.

**How a vector form is written.** The arithmetic is written with `base:intrinsics` on `#simd[N]T` types: `simd_shuffle`, `simd_select`, `simd_lanes_eq`, `simd_shr`, `simd_shl`, `simd_bit_and`, `simd_bit_or`, `simd_bit_xor`, `simd_reduce_or`, `simd_reduce_and`, `simd_extract`, `unaligned_load`, `unaligned_store`, the operators `+ - *`, and `cast` between element widths. The compiler lowers them to SSE2 instructions. No form names an instruction of the processor, and no form is written in assembler.

**What SSE2 is not here.** It is not the only instruction set that a program can use. A program can read its usable instruction sets with `support/instruction_sets` (`usable_instruction_sets`) and run AVX2 code where the processor has it and the kernel saves its registers. No vector form of the system does that today: the measures below say why.

### What was measured about AVX2

An AVX2 form of each procedure, behind one choice at the start of a program (CPUID and XGETBV as instruction templates), was measured by the host tests on a host with AVX2. The host load was 10, above the limit of 8, so these times rank the forms and are not valid measures of speed:

| Measure (host, `-o:speed`) | Scalar | SSE2 | AVX2 |
|---|---|---|---|
| One glyph from the glyph cache | 301 ns | 193 ns | 244 ns |
| BLAKE3 of 390 624 bytes | 835 us | 200 us | 383 us |

The build with no optimisation (the build of the host tests of `kerneltool check`) gave the same order: one glyph 1382 / 813 / 4716 ns in a first run, BLAKE3 5920 / 1904 / 2002 us.

AVX2 lost to SSE2 in both places, and its form of the blend of a glyph gave wrong bytes in the build with no optimisation. So the system has the scalar form and the SSE2 form only: no AVX2 form, and no vector form that chooses at the start of a program.

### What an AVX2 form needs

1. **The registers saved, and a way to know it.** This part exists. The kernel saves the extended state of a thread at each switch of threads: with `xsaveopt` when the processor has it, with the `ymm` registers of AVX and the registers of AVX-512 when the processor has them; with `fxsave` else (`kernel/extended_state.odin`; `docs/ARCHITECTURE.md`, "The extended state of the processor"). A program reads whether AVX2 is usable with `support/instruction_sets`, once at its start: CPUID is slow in a virtual machine.
2. **A form that wins by measure** on the machine, with optimisation, on a host with a load under 8. The blend of a glyph reads a table at an index for each channel. The AVX2 gather (`vpgatherdd`) is not faster than single loads on every processor, and on processors from Skylake to Ice Lake and Tiger Lake the correction against Gather Data Sampling (2023) makes it several times slower. A form to measure first: the arithmetic in `ymm` registers with the reads of one byte of the SSE2 form, and no gather.
3. **The cause of the wrong bytes understood.** The facts:
   - In the build with no optimisation, the AVX2 form gave the byte 03 in some channels. 03 is entry 0 of the table of square roots, so the gather read index 0 in those lanes: the vector of indices that the gather received had zeros where the indices were not 0. The build with optimisation gave the right bytes.
   - One cause is known: an AVX2 procedure that passes vectors of 256 bits by value to procedures without the target feature (section "A lesson"). With the indices passed to the gather procedure through a pointer, the fault stayed.
   - The probable cause: the same kind of fault at another place, where a vector of more than 128 bits passes between two procedures in a build that puts nothing inline. Candidates: the call of the binding `x86._mm256_i32gather_epi32` (a procedure of the C convention that takes and gives a vector of 256 bits), or the vector of 512 bits that the shared arithmetic returned. A fault of the compiler in that build is also possible.
   - The way to know: read the LLVM IR of the test build for the gather procedure and its callers, and compare the vector of indices that is stored with the one that the gather instruction receives.

### A lesson for later: vectors of more than 128 bits across procedures

A procedure with the target feature `avx2` and a procedure without it pass a vector of more than 128 bits in different places: one `ymm` register, against two `xmm` registers or memory. A call by value between the two gives the callee other bytes. A build with no optimisation puts no procedure inline, so each such call is real.

The rule for a later AVX2 form:

- Such a vector crosses between the two kinds of procedure only through a pointer.
- A host test of the AVX2 form runs in the build with no optimisation and in the build with optimisation.

A vector of 128 bits or less is passed in one `xmm` register by both kinds. That is why the SSE2 forms have no such fault.

### SSSE3, SSE4.1 and AVX-512

No form uses SSSE3 or SSE4.1. `pshufb` (SSSE3) does a rotation of 8 bits in one instruction in place of three in BLAKE3; `pmulld` and `pblendvb` (SSE4.1) have SSE2 forms of one to three instructions that the compiler writes. The gain is a few instructions in loops whose cost is elsewhere (the reads of the table, the 7 rounds). Such a form needs a test of the processor at the start of a program (`support/instruction_sets`).

AVX-512 gives 512-bit registers (16 pixels, 16 chunks of BLAKE3 side by side), mask registers (the last pixels of a row with no scalar tail), and a gather of 16 lanes. The kernel already saves its three state components on a processor that has them: the extended state area of each thread has 2688 bytes for that (`EXTENDED_STATE_CAPACITY`). A form still needs the same test of the processor as AVX2, and a measure first: on some processors a 512-bit instruction lowers the clock of the core for a while.

## 3. The blend of a glyph (`support/graphics`)

**What it is.** A glyph of the vector font is a rectangle of coverage words from the glyph cache: for each pixel, how much of each color stripe of the screen the shape covers. The blend mixes the text color over the pixels of the canvas with that coverage, in linear light (`docs/FONTS.md`, "Subpixel bands"; `docs/FONTS.md`, "The blend in linear light"). It is the cost of every text of the system.

**The hot loop** is `blend_coverage_row_in_order` (`support/graphics/blend.odin`): for each pixel with partial coverage, three channels, each `square_root[(d * d * (255 - a) + c * c * a) >> 12]`, with `d` the pixel, `c` the color and `a` the coverage. `docs/FONTS.md`, section 5, gives its cost: a glyph from the glyph cache costs about 9 times a glyph of Spleen.

**The SSE2 form** is `blend_coverage_row_sse2` in `support/graphics/blend_vectors_amd64.odin`, 4 pixels at a time. Each byte of the four pixels gets one lane of 16 bits (16 lanes, which the compiler splits in two registers), because the product of two bytes fits in 16 bits.

| Part | Form |
|---|---|
| The split of 4 pixels and 4 coverage words into 16 lanes of 16 bits (one lane for each byte) | vector: a widening conversion |
| The order of the stripes (red-green-blue, blue-green-red, none) | vector: one shuffle of lanes, chosen at compile time |
| `d * d`, `255 - a`, the two products, the sum, `>> 12` | vector: 16-bit squares, 32-bit products and sum |
| The read of `square_root` | 12 reads of one byte for 4 pixels: SSE2 has no gather |
| The choice of each channel (coverage 0: the pixel; 255: the color; else the table) and of each pixel (a word of 0: the pixel whole; a word that covers the three stripes: the color whole) | vector: comparisons and selects, no branch |
| A group of 4 words of 0, or of full coverage | one test for the group, before the arithmetic |
| The last 0 to 3 columns of a row | the scalar form |

The table is kept: 12 reads of one byte cost less than a square root computed in lanes (a search of 8 steps for each channel).

**The flag of the scalar form.** The scalar form keeps the channels of the previous pixel, with a flag for "no previous pixel" (`previous_known`). The value `0xFFFFFFFF` cannot mean "no previous pixel": a first pixel `0xFFFFFFFF` is then blended as black. A canvas of the system holds `0x00RRGGBB` only, but the blend must be right for every word. The host test `coverage_scalar_form_reads_a_pixel_of_all_ones` keeps the flag.

**The blend table is a third path, not a vector form.** For a text over one flat color, `graphics.blend_glyph_rows` reads the result of each channel from a blend table: three loads and a store for a pixel, with no arithmetic (`docs/FONTS.md`, "Where the time goes, and the fast blend"). The two paths meet in this way:

- A row of a glyph whose two end pixels have one color takes the blend table of that color.
- A row whose two ends differ (a gradient across, a picture) takes the form of the target: the SSE2 form on amd64.
- A lone pixel of another color inside a row of the table takes the scalar form: the SSE2 form gives a lone pixel to the scalar form anyway.

The three give the same bytes: the host test `three_blends_give_the_same_bytes_for_each_cache` compares the blend table, the SSE2 form alone and the scalar form alone.

### Fill and copy

They have no vector form of their own:

- `graphics.copy` calls `intrinsics.mem_copy_non_overlapping`, which is `copy_bytes_without_overlap` of `runtime/memory.asm`. That procedure already moves 16 bytes at a time in `xmm` registers: two or four moves that overlap for 16 to 64 bytes, a loop of 64 bytes above, and `rep movsb` from 2048 bytes to 1 MiB. It uses no AVX: the same file runs in the boot program and on a processor where AVX is not usable.
- `graphics.fill` is a loop of 32-bit stores, and the compiler makes it a vector loop: the code of the compositor has `pshufd $0x0` (the color in the four lanes) and stores of 16 bytes in `interface::execute_in_rectangle` (`objdump -d build/modules/compositor/linked.elf`). A fill of 32-bit pixels is not a fill of bytes: `fill_bytes_with_value` does not apply.

The kernel links another form of `runtime/memory.asm` (`WITHOUT_VECTOR_REGISTERS`): general registers, `rep movsb` and `rep stosb` only.

## 4. The compositor

The compositor draws each frame of the screen. This table says, for each kind of work of a frame, which form does it:

| Work of a frame | Form |
|---|---|
| The copy of the background and of a surface into the frame, and of the frame into the screen | `copy_bytes_without_overlap` of `runtime/memory.asm`: already vector moves |
| The swap of red and blue when the screen is blue-green-red | the compiler makes it a vector loop (`psrld $0x10`, `pand`, `por` on 16 bytes, in `entry` of the compositor) |
| The blend of the pointer picture (`blend_premultiplied_alpha`) | SSE2 form, `blend_premultiplied_alpha_row_sse2` |
| Rectangles (`Rectangle` records), vertical gradients (a fill for each line) | `graphics.fill`: a vector loop of the compiler |
| Horizontal gradients (`graphics.gradient`: one row of colors, then a copy for each line) | scalar: one row for each record, then copies |

**The blend of the pointer picture.** A pointer picture has one alpha for each pixel, premultiplied (`docs/POINTERS.md`, "3. The format of the system: one pointer theme file"). For each channel, with `d` the pixel and `a` the alpha of the source:

- `t = d * (255 - a) + 128`, then `(t + t >> 8) >> 8`: a division by 255 that is exact for each 16-bit product.
- The SSE2 form computes each channel in its own lane of 16 bits. The scalar form computes red and blue in two lanes of 16 bits of one word, and green alone: the lanes have the same values.
- The source is then added as words of 32 bits, as in the scalar form: a source that is not premultiplied carries from one channel into the next in both forms. The validation of a pointer theme file refuses such a pixel, so the compositor never draws one.
- A group of four transparent pixels is not read. A source with alpha 255 needs no case of its own in the SSE2 form: `255 - a` is 0, and the result is the source without its alpha.

## 5. BLAKE3 (`contract/blake3`)

**Where the hash runs.** The root service checks the hash of each resource before it gives it to a program, and the loader checks the hash of each module that it loads. The hash of a module is its identity, so every start of a program pays this cost.

**How BLAKE3 cuts its input.** The input is cut in chunks of 1024 bytes. Each chunk gives a chaining value of 8 words, and the chaining values are joined two by two in a tree, up to the root. The chunks do not depend on each other: several can be compressed at the same time.

**The form** is the one of the reference implementation of BLAKE3 for many chunks: the chunks of a subtree side by side, one chunk in each lane. The other candidate, the compression of one block of one chunk with the 16 words in 4 vectors (one row in each), gives less: the message words must be moved between lanes at each round.

- `contract/blake3/chunks_side_by_side_amd64.odin` (`four_chunk_values_side_by_side`): the 16 words of the state of 4 chunks in 16 vectors of 4 words. A round is the 8 mixes of the scalar form, each on whole vectors (`mix_lanes`). The words of a block of the 4 chunks are turned with a transpose of 4 x 4 words (shuffles). The counter of each chunk is computed for each lane in 64 bits, so a low word that passes 2^32 between two lanes is right.
- `subtree_value` takes this path for a subtree of exactly 4 chunks. The left part of a tree is always a power of two of whole chunks, so every input of more than 4096 bytes has such subtrees. The parents of the chunk values are the scalar form.
- Scalar: an input of 4096 bytes or less, the last part of a tree that is not a power of two of chunks, the parents, the root.

`blake3.hash` and `blake3.subtree_chaining_value` take the SSE2 form on amd64 with no parameter of the caller. The host tests reach both forms through `hash_in_form`, which is private to the package.

The rotations by 16, 12, 8 and 7 bits are written as two shifts and an or (`rotate_lanes_right`); the compiler can write the rotation by 16 as shuffles of 16-bit lanes. The object code is not read yet.

## 6. How to measure on the machine

A measure is a line that a program of the system writes on the log. Each command runs the main machine test; each line is in `build/test_output.txt`. A measure is valid when `uptime` shows a load under 8. No test fails on a time: a measure is printed, never asserted (`docs/TOOLS.md`, "The bounds of the tests").

```
flock -o <the lock of the worktree> nix develop -c kerneltool test main
grep "vector_glyphs: one glyph" build/test_output.txt
grep "compositor: the blend of the arrow" build/test_output.txt
grep "root: the resource glyph_cache" build/test_output.txt
```

| Line | The number | The scalar form |
|---|---|---|
| `vector_glyphs: one glyph ...` | after "from the glyph cache:": one glyph in ns, the least of 50 batches; after "Spleen 8x16:": one glyph of Spleen | 309 ns, Spleen 35 ns (`docs/FONTS.md`, section 5) |
| `compositor: the blend of the arrow of 32x32 ...` | the blend of the arrow in ns, and a copy of the same size | 824 to 1008 ns, a copy 151 to 153 ns |
| `root: the resource glyph_cache (its size, its hash checked in N us) ...` | the hash of the glyph cache in us | 796 to 966 us for 390 624 bytes (`docs/FONTS.md`, section 5) |

On the host, with the optimisation of a module. Each test prints the time of each form, and fails only when the forms give different bytes:

```
nix develop -c odin test support/graphics -o:speed -vet -collection:contract=contract -collection:support=support -define:ODIN_TEST_NAMES=graphics.glyph_draw_cost_of_each_form
nix develop -c odin test contract/blake3 -o:speed -vet -collection:contract=contract -collection:support=support -define:ODIN_TEST_NAMES=blake3.hash_cost_of_each_form
```

`graphics.text_speed_of_each_blend` gives the time of one glyph with the blend table, with the SSE2 form alone and with the scalar form alone, in the same way.

## 7. Limits

- The horizontal gradient and the outline renderer (`support/vector_font`, at build time) stay scalar.
- The object code of the SSE2 forms is not read yet: the measures say if the compiler lowered the 16-bit products to `pmullw` and `pmulhuw`.
- The cryptography of the system has no vector form: it keeps the portable implementations of its origin (`docs/CRYPTOGRAPHY.md`).
- No vector form uses a usable instruction set above SSE2. The package `support/instruction_sets` has two users, the test programs `extended_state` and `return_fault`.
