# Vector forms: SSE2

This document says which procedures of the system compute with vectors, in which form, what stays scalar, and how a person measures each one. The terms are in `docs/GLOSSARY.md`: scalar form, vector form.

## 1. The rule of the same bytes

- A vector form gives the same bytes as its scalar form, for every input. The screenshots of the system are compared byte for byte, and one source gives one module.
- The arithmetic is integers only. A vector form does the arithmetic of the scalar form in lanes, with the same widths of the intermediate values: it rounds nowhere where the scalar form does not.
- The scalar form stays beside each vector form. It is the reference of the host tests, the code of a target that is not amd64, and the code of the last values of a row that do not fill a group of the vector form.
- A vector form loads and stores a group of values only when the whole group is inside the slice of the caller. It allocates nothing.
- A host test compares each vector form with the scalar form on inputs from a generator with a fixed seed: every length from 0 to 67, every place against a boundary of 16 bytes, the edge values (0, 1, 254, 255, words of all ones). When a test fails, it gives the first wrong pixel, the value of each form, and the count of pixels changed outside the drawn columns.

## 2. One form: SSE2

The vector forms use the 128-bit registers of SSE2. Every x86-64 processor has SSE2, and every kernel saves these registers (`fxsave`). So a vector form needs no test of the processor and no choice at the start of a program: on amd64 the public procedure runs the SSE2 form, and on another target the scalar form. A module is compiled for the baseline, x86-64 with SSE2: `llc` gets no `-mattr` and no `-mcpu`.

The arithmetic is written with `base:intrinsics` on `#simd[N]T` types (`simd_shuffle`, `simd_select`, `simd_lanes_eq`, `simd_shr`, `simd_extract`, the operators `+ - *`, and `cast` between element widths). The compiler lowers them for the baseline.

### What was measured about AVX2

An AVX2 form of each procedure, behind one choice at the start of a program (CPUID and XGETBV as `asm` templates), was measured by the host tests on a host with AVX2. The host load was 10, above the limit of 8, so these times rank the forms and are not valid measures of speed:

| Measure (host, `-o:speed`) | Scalar | SSE2 | AVX2 |
|---|---|---|---|
| One glyph from the glyph cache | 301 ns | 193 ns | 244 ns |
| BLAKE3 of 390 624 bytes | 835 us | 200 us | 383 us |

The build with no optimisation (the build of the host tests of `kerneltool check`) gave the same order: one glyph 1382 / 813 / 4716 ns in a first run, BLAKE3 5920 / 1904 / 2002 us.

AVX2 lost to SSE2 in both places, and its form of the blend of a glyph gave wrong bytes in the build with no optimisation. So the system has the scalar form and the SSE2 form only: no AVX2 form, no choice at the start of a program, and no package for that choice.

### What an AVX2 form needs

1. The kernel saves the extended state of a program (`xsave`, XCR0 bits 1 and 2) at each switch of threads (`ARCHITECTURE.md`, "The extended state of the processor"). A program reads whether AVX2 is usable with `support/instruction_sets`, once at its start.
2. A form that wins by measure on the machine, with optimisation, on a host with a load under 8. The blend of a glyph reads a table at an index for each channel. The AVX2 gather (`vpgatherdd`) is not faster than single loads on every processor, and on processors from Skylake to Ice Lake and Tiger Lake the correction against Gather Data Sampling (2023) makes it several times slower. A form to measure first: the arithmetic in `ymm` registers with the reads of one byte of the SSE2 form, and no gather.
3. The cause of the wrong bytes understood. The facts: in the build with no optimisation, the AVX2 form gave the byte 03 in some channels. 03 is entry 0 of the table of square roots, so the gather read index 0 in those lanes: the vector of indices that the gather received had zeros where the indices were not 0. The build with optimisation gave the right bytes. One cause is known: an AVX2 procedure that passes vectors of 256 bits by value to procedures without the target feature (section "A lesson"). With the indices passed to the gather procedure through a pointer, the fault stayed. The probable cause: the same kind of fault at another place, where a vector of more than 128 bits passes between two procedures in a build that puts nothing inline. Candidates: the call of the binding `x86._mm256_i32gather_epi32` (a procedure of the C convention that takes and gives a vector of 256 bits), or the vector of 512 bits that the shared arithmetic returned. A fault of the compiler in that build is also possible. The way to know: read the LLVM IR of the test build for the gather procedure and its callers, and compare the vector of indices that is stored with the one that the gather instruction receives.

### A lesson for later: vectors of more than 128 bits across procedures

A procedure with the target feature `avx2` and a procedure without it pass a vector of more than 128 bits in different places: one `ymm` register, against two `xmm` registers or memory. A call by value between the two gives the callee other bytes. A build with no optimisation puts no procedure inline, so each such call is real. The rule for a later AVX2 form: such a vector crosses between the two kinds of procedure only through a pointer, and a host test of the AVX2 form runs in the build with no optimisation and in the build with optimisation. A vector of 128 bits or less is passed in one `xmm` register by both kinds.

### SSSE3, SSE4.1 and AVX-512

No form uses SSSE3 or SSE4.1. `pshufb` (SSSE3) would do a rotation of 8 bits in one instruction in place of three in BLAKE3; `pmulld` and `pblendvb` (SSE4.1) have SSE2 forms of one to three instructions that the compiler writes. The gain is a few instructions in loops whose cost is elsewhere (the reads of the table, the 7 rounds). Such a form needs a test of the processor at the start of a program.

AVX-512 would give 512-bit registers (16 pixels, 16 chunks of BLAKE3 side by side), mask registers (the last pixels of a row with no scalar tail), and a gather of 16 lanes. It needs XCR0 bits 5, 6 and 7 in the kernel and an `xsave` area of about 2.7 KB in place of 0.8 KB for each thread, the same test of the processor as AVX2, and a measure first: on some processors a 512-bit instruction lowers the clock of the core for a while.

## 3. The blend of a glyph (`support/graphics`)

The hot loop is `blend_coverage_row_in_order` (`support/graphics/blend.odin`): for each pixel with partial coverage, three channels, each `square_root[(d * d * (255 - a) + c * c * a) >> 12]`. `docs/FONTS.md`, section 5, gives its cost: a glyph from the glyph cache costs about 9 times a glyph of Spleen.

The SSE2 form is `blend_coverage_row_sse2` in `support/graphics/blend_vectors_amd64.odin`, 4 pixels at a time.

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

The scalar form keeps the channels of the previous pixel, with a flag for "no previous pixel". The value `0xFFFFFFFF` cannot mean "no previous pixel": a first pixel `0xFFFFFFFF` is then blended as black. A canvas of the system holds `0x00RRGGBB` only. The host test `coverage_scalar_form_reads_a_pixel_of_all_ones` keeps the flag.

### Fill and copy

They have no vector form of their own:

- `graphics.copy` calls `intrinsics.mem_copy_non_overlapping`, which is `copy_bytes_without_overlap` of `runtime/memory.asm` (moves of 16 bytes and `rep movsb`).
- `graphics.fill` is a loop of 32-bit stores, and the compiler makes it a vector loop: the code of the compositor has `pshufd $0x0` (the color in the four lanes) and stores of 16 bytes in `interface::execute_in_rectangle` (`objdump -d build/modules/compositor/linked.elf`). A fill of 32-bit pixels is not a fill of bytes: `fill_bytes_with_value` does not apply.

## 4. The compositor

| Work of a frame | Form |
|---|---|
| The copy of the background and of a surface into the frame, and of the frame into the screen | `copy_bytes_without_overlap` of `runtime/memory.asm`: already vector moves |
| The swap of red and blue when the screen is blue-green-red | the compiler makes it a vector loop (`psrld $0x10`, `pand`, `por` on 16 bytes, in `entry` of the compositor) |
| The blend of the pointer picture (`blend_premultiplied_alpha`) | SSE2 form, `blend_premultiplied_alpha_row_sse2` |
| Rectangles (`Rectangle` records), vertical gradients (a fill for each line) | `graphics.fill`: a vector loop of the compiler |
| Horizontal gradients (`graphics.gradient`: one row of colors, then a copy for each line) | scalar: one row for each record, then copies |

The blend of the pointer picture computes each channel in its own lane of 16 bits: `t = d * (255 - a) + 128`, then `(t + t >> 8) >> 8`. The scalar form computes red and blue in two lanes of 16 bits of one word: the lanes have the same values. The source is then added as words of 32 bits, as in the scalar form: a source that is not premultiplied carries from one channel into the next in both forms. A group of four transparent pixels is not read.

## 5. BLAKE3 (`contract/blake3`)

The root service checks the hash of each resource and each module at its start; the loader checks the hash of each module that it loads.

The form is the one of the reference implementation of BLAKE3 for many chunks: the chunks of a subtree side by side, one chunk in each lane. The compression of one block of one chunk with the 16 words in 4 vectors (one row in each) gives less: the message words must be moved between lanes at each round.

- `contract/blake3/chunks_side_by_side_amd64.odin`: the 16 words of the state of 4 chunks in 16 vectors of 4 words. A round is the 8 mixes of the scalar form, each on whole vectors. The words of a block of the 4 chunks are turned with a transpose of 4 x 4 words (shuffles). The counter of each chunk is computed for each lane in 64 bits, so a low word that passes 2^32 between two lanes is right.
- `subtree_value` takes this path for a subtree of exactly 4 chunks. The left part of a tree is always a power of two of whole chunks, so every input of more than 4096 bytes has such subtrees. The parents of the chunk values are the scalar form.
- Scalar: an input of 4096 bytes or less, the last part of a tree that is not a power of two of chunks, the parents, the root.

The rotations by 16, 12, 8 and 7 bits are written as two shifts and an or; the compiler can write the rotation by 16 as shuffles of 16-bit lanes. The object code is not read yet.

## 6. How to measure on the machine

Each command runs the main machine test; each line is in `build/test_output.txt`. A measure is valid when `uptime` shows a load under 8.

```
flock -o <the lock of the worktree> nix develop -c kerneltool test main
grep "vector_glyphs: one glyph" build/test_output.txt
grep "compositor: the blend of the arrow" build/test_output.txt
grep "root: the resource glyph_cache" build/test_output.txt
```

| Line | The number | The scalar form |
|---|---|---|
| `vector_glyphs: one glyph ...` | after "from the glyph cache:": one glyph in ns, the least of 50 batches | 309 ns, Spleen 35 ns (`docs/FONTS.md`, section 5) |
| `compositor: the blend of the arrow of 32x32 ...` | the blend of the arrow in ns, and a copy of the same size | 824 to 1008 ns, a copy 151 to 153 ns |
| `root: the resource glyph_cache (390624 bytes, its hash checked in N us) ...` | the hash of the glyph cache in us | 796 to 966 us (`docs/FONTS.md`, section 5) |

On the host, with the optimisation of a module:

```
nix develop -c odin test support/graphics -o:speed -vet -collection:contract=contract -collection:support=support -define:ODIN_TEST_NAMES=graphics.glyph_draw_cost_of_each_form
nix develop -c odin test contract/blake3 -o:speed -vet -collection:contract=contract -collection:support=support -define:ODIN_TEST_NAMES=blake3.hash_cost_of_each_form
```

## 7. Limits

- The horizontal gradient and the outline renderer (`support/vector_font`, at build time) stay scalar.
- The object code of the SSE2 forms is not read yet: the measures say if the compiler lowered the 16-bit products to `pmullw` and `pmulhuw`.
