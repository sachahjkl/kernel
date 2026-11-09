# WebGPU from nothing: size, subset, shaders, back ends

Status: research note, 2026-11-09.

This note supports property 18 (`PROPERTIES.md`) and system U8 (`ARCHITECTURE.md`).
The owner decided: WebGPU is the one graphics interface, WGSL is the one shader language, and the project writes the implementation from nothing in Odin.
This note measures the work and proposes an order.

## How to read the numbers

- "Measured" means: `wc -l` on a shallow clone made on 2026-11-09. The count includes comments and blank lines. It excludes test files where the text says "no tests".
- Rust files hold unit tests inside the source file. The Rust counts include these tests.
- "Estimate" means: a number that this note derives. No source publishes it.
- "UNVERIFIED" means: the fact comes from memory or from a page that this study did not fetch.

Commits measured:

| Repository | Commit | Date |
|---|---|---|
| `webgpu-native/webgpu-headers` | `a1dc774` | 2026-09-28 |
| `gfx-rs/wgpu` | `b672a54` | 2026-11-06 |
| `dawn.googlesource.com/dawn` | `70d2947` | 2026-11-09 |
| `google/swiftshader` | `cddb5c9` | 2026-10-14 |
| `gpuweb/cts` | `d116bcc` | 2026-10-23 |
| `mesa/mesa` | `50cbad9` | 2026-11-09 |
| `torvalds/linux` | `7475ea8` | 2026-11-08 |
| `gpuweb/gpuweb` (`spec/index.bs`, `wgsl/index.bs`) | `main` | 2026-11-09 |

## 1. Size of the WebGPU interface

### Standard status

- WebGPU is a W3C Candidate Recommendation Draft. The latest draft is dated 15 September 2026. <https://www.w3.org/TR/webgpu/>
- The Candidate Recommendation Snapshot is dated 19 December 2024. Each later publication is a Candidate Recommendation Draft. <https://www.w3.org/standards/history/webgpu/>
- WGSL has the same status. Its latest draft is dated 6 November 2026. <https://www.w3.org/TR/WGSL/>
- Neither document is a W3C Recommendation. The working group must show each feature in two deployed browsers, measured with the test suite. <https://www.w3.org/TR/webgpu/>
- Consequence: the core interface is stable. New capabilities arrive as optional features and WGSL language extensions.

### The W3C interface (measured in `spec/index.bs`)

Source: <https://github.com/gpuweb/gpuweb/blob/main/spec/index.bs>

| Item | Count |
|---|---|
| Lines of specification source | 18,581 |
| Interfaces (not mixins) | 34 |
| Interface mixins | 6 |
| Dictionaries (descriptors) | 57 |
| Enumerations | 34 |
| Flag namespaces | 5 |
| Texture formats | 105 |
| Optional features (`GPUFeatureName`) | 25 |
| Limits (`GPUSupportedLimits`) | 36 |

Structure of the interface:

- **Discovery**: `GPU` → `GPUAdapter` → `GPUDevice` → `GPUQueue`.
- **Resources**: `GPUBuffer`, `GPUTexture`, `GPUTextureView`, `GPUSampler`, `GPUExternalTexture`, `GPUQuerySet`.
- **Binding**: `GPUBindGroupLayout`, `GPUBindGroup`, `GPUPipelineLayout`.
- **Programs**: `GPUShaderModule`, `GPURenderPipeline`, `GPUComputePipeline`.
- **Recording**: `GPUCommandEncoder`, `GPURenderPassEncoder`, `GPUComputePassEncoder`, `GPURenderBundleEncoder`, `GPURenderBundle`, `GPUCommandBuffer`.
- **Presentation**: `GPUCanvasContext` in the browser. `WGPUSurface` in `webgpu.h`.
- **Errors**: error scopes, uncaptured errors, device loss, compilation messages.

### `webgpu.h` (measured)

Source: <https://github.com/webgpu-native/webgpu-headers/blob/main/webgpu.h>

| Item | Count |
|---|---|
| Lines of `webgpu.h` | 6,774 |
| Lines of `webgpu.yml` (machine-readable source of truth) | 5,532 |
| Object types (opaque handles) | 23 |
| Records (`struct`) | 92 |
| Enumerations | 54 |
| Exported functions | 202 |
| Of these: `AddRef`, `Release`, `SetLabel`, `FreeMembers` | 72 |
| Functions that do real work | 130 |
| Callback function types | 10 |
| Functions that return a `WGPUFuture` | 9 |
| Records with a `nextInChain` field | 59 |
| Extension records (begin with `WGPUChainedStruct chain`) | 16 |
| Uses of `WGPUStringView` | 104 |

Functions that do real work, per object:

| Object | Functions |
|---|---|
| Device | 23 |
| RenderPassEncoder | 20 |
| RenderBundleEncoder | 13 |
| CommandEncoder | 13 |
| Texture | 11 |
| Buffer | 10 |
| ComputePassEncoder | 9 |
| Instance | 6 |
| Surface | 5 |
| Adapter | 5 |
| Queue | 4 |
| QuerySet | 3 |
| ShaderModule, RenderPipeline, ComputePipeline | 1 each |

- The README calls `webgpu.h` "the stable C header". Dawn and Emdawnwebgpu implement it. wgpu-native does not yet implement the stable version. <https://github.com/webgpu-native/webgpu-headers/blob/main/README.md>
- `webgpu.yml` exists so that other projects can generate bindings. The project can generate its own interface description from it. <https://github.com/webgpu-native/webgpu-headers/blob/main/README.md>

### What `webgpu.h` defines as the C ABI

Articles: <https://webgpu-native.github.io/webgpu-headers/> and <https://github.com/webgpu-native/webgpu-headers/tree/main/doc/articles>

- **Objects**: opaque pointers with reference counts. Each type has `AddRef` and `Release`.
- **Descriptors**: records passed by address. Most start with `nextInChain`, the head of a linked list of extension records. Each extension record starts with `{next, sType}`.
- **Strings**: `WGPUStringView {data, length}`. The length `WGPU_STRLEN` (`SIZE_MAX`) means "null-terminated".
- **Callbacks**: a `...CallbackInfo` record holds a function address, two `userdata` addresses and a `WGPUCallbackMode`. The caller passes this record by value.
- **Futures**: each asynchronous function returns `WGPUFuture {u64 id}`. The program calls `wgpuInstanceWaitAny` or `wgpuInstanceProcessEvents` to run the callbacks.
- **Callback modes**: `WaitAnyOnly`, `AllowProcessEvents`, `AllowSpontaneous`. A spontaneous callback can fire on any thread at any time.
- **The 9 asynchronous functions**: `InstanceRequestAdapter`, `AdapterRequestDevice`, `BufferMapAsync`, `DeviceCreateRenderPipelineAsync`, `DeviceCreateComputePipelineAsync`, `DevicePopErrorScope`, `DeviceGetLostFuture`, `QueueOnSubmittedWorkDone`, `ShaderModuleGetCompilationInfo`.

### Conflicts with the rules of the system

| Part of `webgpu.h` | Rule that it breaks | Replacement |
|---|---|---|
| Callbacks with `userdata` | The base interface is non-blocking command records and completion records (P4). A callback puts foreign control flow in the program | A completion record with a `u64` tag that the program chose |
| `WGPUFuture` + `WaitAny` | None. This is the same idea as a completion queue | Keep the idea. The future id becomes the tag |
| `CallbackInfo` and `WGPUStringView` passed by value | A record is never passed by value (call form, `MODULE_CONTRACT.md` §4) | Pass the address of the record |
| `nextInChain` linked lists | A record is a fixed layout. A pointer list cannot cross a ring without a walk and a copy | Flat descriptor records. Growth by added fields (ZII) |
| `WGPU_STRLEN` terminator mode | A string is a slice with no terminator | Slice only |
| Non-zero sentinels (`WGPU_WHOLE_SIZE`, `..._UNDEFINED` = all bits set) and `..._INIT` macros. See `SentinelValues.md` | Zero is initialization (P13) | Define each field so that 0 means "default". Example: `mip_level_count = 0` means "all remaining levels" |
| Reference counts (`AddRef`, `Release`) | Resources are handles with a generation | One `destroy` per handle. No shared ownership in the contract |
| `size_t`, `WGPUBool`, bare `enum` | Only base types with a fixed width | `u64`, `bool`, enumerations with a declared width |
| Returned strings and arrays that the callee allocates (`FreeMembers`) | The caller owns all memory (P14) | The caller gives a buffer and a capacity |

- The limit of 6 integer and 8 float parameters is respected by the functions that this study checked: `SetViewport` (1 handle, 6 floats), `CopyBufferToBuffer` (6 integers), `QueueWriteTexture` (6). A check of all 130 functions is UNVERIFIED.
- Conclusion: `webgpu.h` is the correct vocabulary and the wrong ABI. The project keeps the names, the enumerations and the semantics. It defines its own records and exports.

## 2. A minimal subset in layers

The levels follow the spec. A level adds objects and features. It never changes the meaning of an earlier level.

### Level 1: 2D (compositor and UI)

Objects: Instance, Adapter, Device, Queue, Surface, Buffer, Texture, TextureView, Sampler, ShaderModule, BindGroupLayout, BindGroup, PipelineLayout, RenderPipeline, CommandEncoder, RenderPassEncoder, CommandBuffer. This is 17 of the 23 objects.

| Area | Level 1 content |
|---|---|
| Buffers | Usages `VERTEX`, `INDEX`, `UNIFORM`, `COPY_SRC`, `COPY_DST`. `writeBuffer`. `mappedAtCreation` |
| Textures | 2D only. One mip level. One sample. Formats `rgba8unorm`, `bgra8unorm`, their sRGB forms, `r8unorm` (glyph coverage) |
| Sampler | `nearest`, `linear`. `clamp-to-edge`, `repeat` |
| Pipeline | `triangle-list`, `triangle-strip`. Vertex buffers with vertex and instance step. Blend state and write mask. No depth |
| Pass | One color attachment. `load` or `clear`. `store` |
| Pass commands | `setPipeline`, `setBindGroup`, `setVertexBuffer`, `setIndexBuffer`, `setViewport`, `setScissorRect`, `setBlendConstant`, `draw`, `drawIndexed` |
| Copies | `writeTexture`, `copyBufferToTexture`, `copyTextureToTexture` |
| Surface | `configure`, `getCurrentTexture`, `present` |
| Errors | Error scopes. Uncaptured error. Shader compilation messages |
| WGSL | `f32`, `i32`, `u32`, `bool`, vectors, matrices, structures, arrays of fixed size, functions, all control flow, `textureSample`, `textureLoad`, the numeric built-ins |

- With one mip level, `textureSample` needs no derivative. The rasterizer does not need 2×2 pixel groups at this level.
- This level is sufficient for: textured quads, glyph atlases, rounded rectangles and shadows computed in the fragment shader, clipping by scissor, composition of surfaces.

### Level 2: 3D

- Adds: depth and stencil formats and state, depth bias, culling, clipping.
- Adds: MSAA with 4 samples and resolve. WebGPU permits only sample counts 1 and 4. <https://www.w3.org/TR/webgpu/>
- Adds: mip levels, derivatives (2×2 pixel groups), `textureSampleLevel`, `textureSampleGrad`, comparison samplers, anisotropy.
- Adds: cube, array and 3D textures. Float, 16-bit and packed formats.
- Adds: several color attachments, RenderBundle and RenderBundleEncoder, occlusion QuerySet, indirect draws.
- Adds: `mapAsync` for read, `copyTextureToBuffer`, `createRenderPipelineAsync`.
- Adds: the rest of WGSL for render stages.

### Level 3: compute

- Adds: ComputePipeline, ComputePassEncoder, `dispatchWorkgroups`, indirect dispatch.
- Adds: storage buffers, storage textures, read-write access modes.
- Adds: WGSL atomics, `workgroup` variables, runtime-sized arrays, pointer parameters.
- Storage buffers are also useful for 2D. Level 1 uses instance vertex buffers in their place.

### Level 4: conformance

- Adds: all 105 formats that the core requires, all 36 limits at their default values, uniformity analysis, alias analysis.
- Adds: optional features one at a time (timestamp queries, compressed formats, `float32-filterable`, and others).
- Adds: `GPUExternalTexture` only if the system gets a video path.
- Goal: a tracked pass rate on the conformance test suite (section 8).

## 3. Size of existing implementations

### wgpu (Rust) — measured

Source: <https://github.com/gfx-rs/wgpu>

| Part | Lines | Role |
|---|---|---|
| `wgpu-core` | 54,054 | Validation, resource tracking, lifetime. Back-end independent |
| `wgpu-core/src/command` | 17,887 | Recording and validation of commands |
| `wgpu-hal` | 59,144 | Unsafe abstraction over the native interfaces |
| `wgpu-hal` Vulkan | 15,438 | |
| `wgpu-hal` Direct3D 12 | 11,741 | |
| `wgpu-hal` OpenGL ES | 11,493 | |
| `wgpu-hal` Metal | 10,009 | |
| `wgpu-hal` noop | 920 | A back end that does nothing. It shows the minimum surface of a back end |
| `wgpu-types` | 16,775 | Shared records and enumerations |
| `naga` | 136,149 | Shader translator (section 4) |
| `wgpu-core-remote` (+ types) | 5,335 | "Remoting version of wgpu-core for browser implementing WebGPU" |

### Dawn and Tint (C++) — measured, no tests

Source: <https://dawn.googlesource.com/dawn>. Structure: <https://dawn.googlesource.com/dawn/+/HEAD/docs/dawn/overview.md>

| Part | Lines | Role |
|---|---|---|
| `src/dawn/native` total | 165,646 | |
| `src/dawn/native` top-level files ("frontend") | 64,809 | Validation, state tracking, command recording. Back-end independent |
| Vulkan back end | 28,225 | |
| Direct3D 12 back end | 19,488 | |
| Direct3D 11 back end | 13,106 | |
| Metal back end | 12,560 | |
| OpenGL back end | 12,467 | |
| Null back end | 1,017 | |
| `src/dawn/wire` | 9,588 | Client-server form of WebGPU (section 6) |
| `src/dawn/node` | 16,640 | Node.js binding (section 8) |
| `src/dawn/tests` | 213,902 | Tests |
| `src/tint` | 280,488 | Shader compiler (section 4) |
| `src/tint` tests | 480,104 | Tests |

- Dawn generates more code from `dawn.json` (4,953 lines). The counts above exclude generated files that are not in the repository. <https://dawn.googlesource.com/dawn/+/HEAD/docs/dawn/overview.md>
- The overview states the split: files in `native` are the "frontend", and subdirectories are "backends".

### What validation costs

- The back-end independent part is 54,054 lines in wgpu and 64,809 lines in Dawn. Most of this code checks arguments, tracks resource usage, and manages lifetime.
- Dawn's native `.cpp` files contain 865 `DAWN_INVALID_IF` checks. Each one is one validation rule or a part of one. (Measured.)
- The test suite holds 43,485 lines of tests for interface validation and 50,231 lines for shader validation (section 8).
- A back end is 10,000 to 28,000 lines in both projects. The null back ends are about 1,000 lines.
- Consequence: the back-end independent part is larger than any one back end. It is written once.

### Parts that are back-end independent

- Handle tables and lifetime.
- All validation of the interface.
- Command recording into a private command stream.
- The WGSL front end and the shader intermediate form.
- Bind group layout and pipeline layout logic.
- Error scopes and device loss.

## 4. WGSL

### Size of the language

Source: <https://github.com/gpuweb/gpuweb/blob/main/wgsl/index.bs> (measured)

- The specification source is 21,740 lines and 109,569 words. It is longer than the WebGPU interface specification.
- The chapter "Built-in Functions" is about 6,700 lines. It has about 130 function entries. Most entries have several overloads.
- The other large chapters: Types (about 3,000 lines), Expressions (about 2,000), Execution (about 2,400), Statements (about 1,500).

### What a front end must do

1. **Scan** the text into tokens.
2. **Discover template lists** before parsing. <https://www.w3.org/TR/WGSL/#template-lists-sec>
3. **Parse** by recursive descent. The specification gives a grammar for this method.
4. **Resolve names**. Declarations at module scope can appear in any order.
5. **Check types** and **resolve overloads** of operators and built-in functions. <https://www.w3.org/TR/WGSL/#overload-resolution-section>
6. **Evaluate constant expressions**. `const` values and `const_assert` need a full evaluator for every built-in function that is permitted in a constant expression. <https://www.w3.org/TR/WGSL/#const-expr>
7. **Validate**: entry point interfaces, attributes, address spaces, no recursion, behaviors (`return`, `break`, `discard` analysis), memory layout of structures.
8. **Analyze uniformity**: a call that computes a derivative must be in uniform control flow. <https://www.w3.org/TR/WGSL/#uniformity>
9. **Analyze aliasing** of pointer parameters.
10. **Report** each error with a source position.

### Features that are hard

- **Template lists**: `<` is both "less than" and the start of a template list (`vec3<f32>`, `array<T, N>`, `var<uniform>`). The specification defines a discovery algorithm that runs over the token stream before the parser. The specification text says that an implementation can also interleave it with the scanner. <https://www.w3.org/TR/WGSL/#template-lists-sec>
- **Abstract numeric types**: a literal such as `1` has type AbstractInt (64 bits). `1.0` has type AbstractFloat (`f64`). The compiler converts them to concrete types late, by rank. The constant evaluator must work on abstract types. <https://www.w3.org/TR/WGSL/#abstract-types>
- **Overloads**: built-in functions have many overloads over scalar type and vector size. Tint describes them in a definition file of 2,315 lines (`core.def`) and generates a table of 17,386 lines from it. (Measured.)
- **Uniformity analysis**: Tint's `uniformity.cc` is 2,384 lines. (Measured.)
- **Constant evaluation**: Naga's `constant_evaluator.rs` is 5,329 lines. Tint's `core/constant` is 6,671 lines. (Measured.)
- **Exact numeric behavior**: the execution tests check the accuracy of each built-in function. The suite has 80,529 lines for shader execution (section 8).

### Sizes of front ends (measured)

| Part | Lines |
|---|---|
| Naga `front/wgsl` (scan, parse, lower to IR) | 16,023 |
| Naga `valid` (validation of the IR) | 10,856 |
| Naga `proc` (type resolution, constant evaluation, layout) | 11,680 |
| Naga `back/spv` (SPIR-V output) | 18,702 |
| Naga `src` total (all front ends and back ends) | 124,528 |
| Tint `lang/wgsl` total, no tests | 70,435 |
| Tint WGSL `parser.cc` + `lexer.cc` | 5,186 |
| Tint WGSL `resolver` (types, overloads, validation, uniformity) | 14,394 |
| Tint WGSL `ast` + `sem` | 19,023 |
| Tint WGSL `intrinsic` (generated table) | 17,707 |
| Tint `lang/core` (IR, types, constants) | 85,012 |
| Tint `lang/spirv/writer` | 11,008 |

- Reading: a complete WGSL front end with validation is 30,000 to 40,000 lines in both projects, before any back end.

### Small independent implementations

| Project | Language | Scope | Source |
|---|---|---|---|
| `libwgsl` | C99 | Front end only: scan, template lists, parse, resolve, constant evaluation, type check, validation, uniformity, alias analysis. No code output | <https://github.com/toprakdeviren/libwgsl> |
| `simple_wgsl` | C99 | WGSL to SPIR-V and others through one IR. About 46,000 lines total. WGSL parser 2,432 lines, resolver 1,266, lowering 8,103, SPIR-V writer 3,056 | <https://github.com/manuel5975p/simple_wgsl> |
| `wgslender` | Zig core | Parser, validation, uniformity, reflection. Tested on 11,952 shaders of the Tint suite | <https://github.com/HugoDaniel/wgslender> |
| `gogpu/naga` | Go | WGSL to SPIR-V, MSL, GLSL, HLSL. Compared with Rust Naga on its corpus of 172 shaders | <https://github.com/gogpu/naga> |

- `simple_wgsl` shows a lower bound: about 12,000 lines of C take WGSL to SPIR-V. Its conformance level is UNVERIFIED.
- This study found no WGSL compiler in Odin. UNVERIFIED: the search was not exhaustive.
- These projects are references for structure and for test shaders. The owner decided not to port one.

### WGSL to CPU code for the software back end

Three methods exist.

| Method | Example | Cost | Speed |
|---|---|---|---|
| Interpreter over the IR | Naga has none in the tree. UNVERIFIED for other projects | 3,000 to 5,000 lines (estimate) | Slow per pixel if it runs one pixel at a time |
| JIT to machine code | SwiftShader (Reactor), llvmpipe (LLVM), WARP | 8,000 lines and more for one architecture (estimate). SwiftShader's Reactor is 26,926 lines with two code generators | Fast |
| Ahead of time through a native compiler | None found for WGSL. UNVERIFIED | A translator from the IR to Odin source: about 3,000 lines (estimate) | Fast. Works only for shaders known at build time |

- An interpreter is fast enough if each operation works on a batch of pixels. One dispatch then pays for 8 or 16 pixels (AVX2 or AVX-512), or for a whole span. The inner loops are plain SIMD loops that the Odin compiler builds ahead of time.
- LLVM is not available in the new system. A JIT must therefore be the project's own code generator. SwiftShader shows that this is practical: its second code generator is Subzero, which is much smaller than LLVM. <https://github.com/google/swiftshader/blob/master/README.md>
- A JIT needs memory that a program writes and then executes. The kernel memory system and the module rules (code identified by content hash) must permit this. This is an open design question for the owner.
- The three methods share the front end and the IR. The executor is a replaceable part behind one internal interface: "run this stage for this batch".

### WGSL to SPIR-V

- SPIR-V is needed for Venus (section 6). It is not needed for a native driver, which needs the instruction set of the device (section 7).
- The writer is 11,008 lines in Tint, 18,702 in Naga and about 3,000 in `simple_wgsl` after an 8,103-line lowering pass. (Measured and published.)
- A SPIR-V back end must also add safety transformations: bounds clamps on array access, defined behavior for integer division, loop bounds. `gogpu/naga` lists these. <https://github.com/gogpu/naga>
- Estimate for the project: 6,000 to 10,000 lines of Odin.

## 5. Software rasterizers

### Prior art and size (measured)

| Project | Lines | Notes |
|---|---|---|
| SwiftShader `src` total (no third-party code) | 101,164 | Vulkan 1.3 conformant on CPU. <https://github.com/google/swiftshader/blob/master/README.md> |
| SwiftShader `Reactor` | 26,926 | JIT layer. `LLVMReactor.cpp` 4,596 lines. `SubzeroReactor.cpp` 5,337 lines |
| SwiftShader `Pipeline` | 24,581 | Shader and pixel routines written in Reactor. The SPIR-V files are 12,122 lines |
| SwiftShader `Device` | 11,275 | Rasterizer, blitter, renderer |
| SwiftShader `Vulkan` | 32,102 | The Vulkan object layer |
| Mesa `llvmpipe` | 45,495 | Rasterizer and binning |
| Mesa `gallivm` | 54,019 | LLVM IR generation for shaders, sampling, blending |
| Mesa `lavapipe` | 22,357 | Vulkan layer above llvmpipe |
| Mesa `softpipe` | 17,038 | Reference rasterizer. No JIT |
| tinyrenderer | about 500 | Teaching code. <https://github.com/ssloy/tinyrenderer> |

- **Reactor** is a C++ embedded language that records operations and generates machine code. <https://github.com/google/swiftshader/blob/master/docs/Reactor.md>
- **Chrome**: SwiftShader is the fallback adapter of Dawn. Chromium rejects a CPU adapter for WebGPU unless `--enable-unsafe-webgpu` is set. <https://chromium.googlesource.com/chromium/src/gpu/+/665931fc8f18020bc8102248b8c168fc9cdd27f2>
- **llvmpipe**: shaders, rasterization and vertex processing are compiled with LLVM to x86-64 code. It uses up to 32 threads. The Mesa documentation calls it "the fastest software rasterizer for Mesa". <https://docs.mesa3d.org/drivers/llvmpipe.html>
- **WARP**: a JIT code generator produces SSE2, SSE4.1, AVX, AVX2, AVX-512 and arm64 code. It batches commands and spreads the pipeline over all cores. <https://learn.microsoft.com/en-us/windows/win32/direct3darticles/directx-warp>
- **gogpu/wgpu**: a WebGPU implementation in Go with a software back end. It is the closest prior art for "WebGPU on CPU with no Vulkan below". Its size and speed are UNVERIFIED. <https://github.com/gogpu/wgpu>
- **Redox** uses llvmpipe and lavapipe because it has no accelerated driver. <https://doc.redox-os.org/book/graphics-windowing.html>

### Techniques that make a CPU rasterizer fast

1. **Binning into tiles**: sort triangles into screen tiles (for example 64×64 pixels). Each tile fits in the L1 or L2 cache. llvmpipe and WARP do this.
2. **One thread per tile**: tiles are independent. The work scales with cores and needs no lock on the target.
3. **SIMD across pixels**: evaluate edge functions and the fragment shader for 4, 8 or 16 pixels in one step.
4. **Specialized code per pipeline state**: generate or select one routine for the exact format, blend state and shader. This removes branches from the pixel loop. All three large projects use a JIT for this.
5. **Fast paths for rectangles**: an axis-aligned quad with a scissor is a span fill. It needs no edge test per pixel.
6. **Deferred execution**: record the pass, then execute it when it ends. A cleared target and hidden draws cost nothing.
7. **Fixed-point edge functions and hierarchical tests**: reject or accept whole blocks. Reference: <https://fgiesen.wordpress.com/2013/02/10/optimizing-the-basic-rasterizer/> (UNVERIFIED: not fetched in this study).

### Published performance

- WARP ran Crysis at 800×600 with lowest settings at 7.36 frames per second on an 8-core Core i7 at 3.0 GHz. A 4-core Penryn reached 5.69. <https://learn.microsoft.com/en-us/windows/win32/direct3darticles/directx-warp>
- Microsoft states that low-end discrete hardware was 4 to 5 times faster than WARP on its benchmarks. Same source.
- These numbers are for a 3D game on processors of 2009. They are a lower bound, not a prediction for 2D.
- This study found no published measurement of a 2D desktop on llvmpipe or SwiftShader at 4K. UNVERIFIED.

### Estimate for a 2D desktop

| Mode | Pixels | Bytes per full layer (4 bytes per pixel) | Bytes per second at 60 Hz |
|---|---|---|---|
| 1080p | 2.07 million | 8.3 MB | 0.5 GB/s |
| 4K | 8.29 million | 33.2 MB | 2.0 GB/s |

- A full-screen pass at 4K writes 2 GB/s per layer. Memory bandwidth, not shader arithmetic, is the limit for simple composition.
- Estimate: a textured, blended quad costs 1 to 3 ns per pixel on one core with AVX2. A full redraw at 4K then costs 8 to 25 ms on one core, and 1 to 4 ms on 8 cores. This estimate is UNVERIFIED until the project measures it.
- Damage tracking is the main tool. A desktop that redraws only changed rectangles rarely touches the full screen.
- Conclusion: 1080p at 60 Hz is realistic on one or two cores. 4K at 60 Hz is realistic with tiles on several cores and with damage tracking. Full-screen effects (blur, large shadows) at 4K are not.
- The UEFI Graphics Output Protocol gives a mode and a framebuffer address. It gives no vertical blank signal and no page flip. The software back end must draw into its own target and copy the damaged rectangles. <https://uefi.org/specs/UEFI/2.10/12_Protocols_Console_Support.html> (UNVERIFIED: not fetched in this study.)

## 6. virtio-gpu

Specification: Virtual I/O Device (VIRTIO) 1.3, section 5.7 "GPU Device". <https://docs.oasis-open.org/virtio/virtio/v1.3/csd01/virtio-v1.3-csd01.html#x1-3960007>

### The device

- The device has two device queues: `controlq` for commands and `cursorq` for cursor updates.
- Feature bits: `VIRGL` (0), `EDID` (1), `RESOURCE_UUID` (2), `RESOURCE_BLOB` (3), `CONTEXT_INIT` (4).
- The Linux guest driver is 6,972 lines. Its protocol header is 469 lines. (Measured: `drivers/gpu/drm/virtio`, `include/uapi/linux/virtio_gpu.h`.)

### 2D mode

The commands (from the header):

1. `GET_DISPLAY_INFO`, `GET_EDID`: read the display modes.
2. `RESOURCE_CREATE_2D`: create a host resource with a format and a size.
3. `RESOURCE_ATTACH_BACKING`: give the guest pages that hold the pixels.
4. `SET_SCANOUT`: connect a resource to a display.
5. `TRANSFER_TO_HOST_2D`: copy a rectangle from guest pages to the host resource.
6. `RESOURCE_FLUSH`: show a rectangle.
7. `UPDATE_CURSOR`, `MOVE_CURSOR` on `cursorq`.

- This mode gives no acceleration. The guest draws with its CPU.
- It gives three things that the UEFI framebuffer lacks: a mode change, damage rectangles, and a hardware cursor.
- Guest code: one device service of about 1,000 to 2,000 lines (estimate). The software back end does not change.

### 3D modes

A 3D mode adds contexts (`CTX_CREATE`), 3D resources, blob resources and `SUBMIT_3D`, which carries an opaque command stream. The capability set selects the protocol of that stream. The header defines 6 sets:

| Capability set | Stream | Host side | What the guest must implement |
|---|---|---|---|
| `VIRGL` (1), `VIRGL2` (2) | Gallium state and TGSI or GLSL shaders | virglrenderer translates to OpenGL | A Gallium-shaped encoder and a WGSL to GLSL path. Mesa's guest driver is 10,584 lines |
| `GFXSTREAM_VULKAN` (3) | Vulkan and GLES calls, "forwarded with minimal modification" | rutabaga with gfxstream | A gfxstream encoder. Device `virtio-gpu-rutabaga` |
| `VENUS` (4) | Serialized Vulkan commands | virglrenderer replays on the host Vulkan driver | A Venus encoder, a Vulkan-shaped back end, WGSL to SPIR-V. Mesa's guest driver is 27,257 lines |
| `CROSS_DOMAIN` (5) | Wayland passthrough | Host compositor | Not relevant |
| `DRM` (6) | The Linux kernel interface of one host driver (native context) | virglrenderer forwards to the host kernel driver | The user-side driver of that exact GPU |

Sources: <https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html>, <https://docs.mesa3d.org/drivers/venus.html>, <https://www.collabora.com/news-and-blog/blog/2025/01/15/the-state-of-gfx-virtualization-using-virglrenderer/>

- **Venus**: "a Virtio-GPU protocol for Vulkan command serialization". Shaders travel as SPIR-V. It needs Vulkan 1.1 on the host and blob resources. <https://docs.mesa3d.org/drivers/venus.html>
- **Venus isolation**: the Venus renderer runs in a separate host process. Collabora describes it as a thin layer with performance close to native. (Collabora link above.)
- **Native context**: it works at the level of the kernel driver interface. It is thinner and faster than virgl and Venus. It needs one guest driver per host GPU. (Collabora link above.)
- **No WebGPU capability set exists**. The header defines only the 6 sets above.

### QEMU status

Source: <https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html>

- virgl: `-device virtio-gpu-gl`.
- Venus: `-device virtio-gpu-gl,hostmem=8G,blob=true,venus=true`. It needs virglrenderer 1.0.0 or later and a Linux 6.13 or later host.
- Native context: `-device virtio-gpu-gl,hostmem=8G,blob=on,drm_native_context=on`. The patch was merged on 2026-03-07 in the pull request tagged for QEMU 11.0. <https://github.com/qemu/qemu/commit/893598209fde32ca5f013a012b120af3a458bcae>
- Native context for Intel i915 needs virglrenderer 1.3.0 or later on the host.
- gfxstream: `-device virtio-gpu-rutabaga,gfxstream-vulkan=on,...`.
- The QEMU release that first shipped Venus is UNVERIFIED. The 10.2 documentation already describes it. <https://qemu.weilnetz.de/doc/10.2/system/devices/virtio/virtio-gpu.html>

### WebGPU as a command stream: prior art

- **Dawn Wire** is "an implementation of WebGPU as a client-server architecture". Chromium uses it between the page process and the GPU process. <https://dawn.googlesource.com/dawn/+/HEAD/docs/dawn/overview.md>
- Dawn Wire is 9,588 lines of written code, plus code generated from `dawn.json` and `dawn_wire.json` (343 lines). (Measured.)
- Its source tree shows the design: a command serializer in chunks, an object store on the client, a memory transfer service for buffer mapping, an event manager for asynchronous results. (Measured: file names in `src/dawn/wire`.)
- UNVERIFIED: the client chooses the object identifiers, so that an object creation needs no reply. This is the known design of Dawn Wire; this study did not read the code.
- **wgpu-core-remote** is the same idea in wgpu: 5,335 lines. (Measured.)
- Lesson: WebGPU serializes well. The interface has few return values, and creation can be asynchronous. This is the form that property 4 requires.

### Smallest path to acceleration under QEMU

1. **2D mode first**. It is small and gives modes, damage and cursor.
2. **Venus second**. It is the only 3D path that needs no change on the host and carries a modern shader format.
3. Venus guest work: a Venus command encoder (the protocol is generated from the Vulkan registry), a WebGPU-to-Vulkan back end (15,438 lines in wgpu, 28,225 in Dawn), and a SPIR-V writer.
4. virgl is the wrong shape: it carries OpenGL state and needs GLSL or TGSI shaders.
5. A custom WebGPU stream needs a host program that the project also writes and a change to the QEMU device. It removes the SPIR-V writer and the Vulkan back end from the guest. It adds a dependency on Dawn or wgpu on the host. This path is smaller in the guest and larger in total.

- Note: the Venus work (SPIR-V, Vulkan-shaped back end) is not reused by a native driver (section 7). It is useful only under a virtual machine.

## 7. Real GPUs without a vendor driver stack

### Size of the open drivers (measured)

Linux kernel side:

| Driver | Lines | Notes |
|---|---|---|
| `i915` | 400,824 | Of these: `display` 206,806, `gt` (engines, submission, power) 94,222, `gem` (memory) 21,632 |
| `xe` | 143,187 | New Intel driver. It reuses the display code of `i915` |
| `amd` without register headers | 1,445,602 | Of these: `amdgpu` 398,839, `display` 651,275, `pm` 186,814 |
| `virtio` | 6,972 | For comparison |

Mesa user side:

| Driver | Lines | Notes |
|---|---|---|
| Intel `iris` (OpenGL) | 40,472 | |
| Intel `anv` (Vulkan) | 116,982 | |
| Intel shader compiler | 225,145 | From Mesa's IR to the instruction set of the execution units |
| Intel `isl` (surface layout) | 19,371 | |
| Intel `blorp` (blits and resolves) | 13,816 | |
| Intel `genxml` | 30,056 lines of XML | Machine-readable description of every command and state packet, per generation |
| `src/intel` total | 476,743 | |
| AMD `radeonsi` (OpenGL) | 70,742 | |
| AMD `radv` (Vulkan) | 117,508 | |
| AMD `aco` shader compiler | 61,764 | |
| AMD `common` | 88,364 | |
| `src/amd` total | 440,492 | |

- The user side is larger than the kernel side when display code is set apart.
- The shader compiler for the device is the largest single part: 225,145 lines for Intel (several generations), 61,764 for AMD.
- Display (modeset) is half of `i915` and almost half of `amd`.

### Documentation

- **Intel** publishes Programmer's Reference Manuals per generation. <https://www.intel.com/content/www/us/en/docs/graphics-for-linux/developer-reference/1-0/overview.html> (UNVERIFIED: the page refused the fetch of this study with HTTP 403.)
- The lead developer of Redox wrote a modeset driver for Intel from these manuals: "a few nights of reading through thousands of pages of PRMs". <https://www.osnews.com/story/143952/redox-takes-first-baby-steps-towards-a-modesetting-driver-for-intel-graphics/>
- Redox's driver sets modes on Tiger Lake and later. It has no acceleration. <https://doc.redox-os.org/book/graphics-windowing.html>
- The OSDev wiki documents Intel modeset for old generations and names `i915` as the reference. No emulator emulates an Intel GPU, so tests need a real machine. <https://osdev.wiki/wiki/Native_Intel_graphics>
- Haiku developers report the cost: each generation has its own thousands of pages, and board makers wire outputs differently. <https://discuss.haiku-os.org/t/ideas-for-gpu-drivers/18831>
- **Intel `genxml`** in Mesa is a second, machine-readable source for command formats. (Measured above.)
- **AMD**: the open drivers are the documentation. Public register manuals for current AMD GPUs are UNVERIFIED; this study found none.

### Firmware

- Intel GPUs from generation 9 contain a microcontroller (GuC). Linux `i915` does not load it on generations before 12, and not on Tiger Lake and Rocket Lake. Those machines submit work through "execlists" registers with no firmware. <https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/i915/gt/uc/intel_uc.c>
- From Alder Lake-P, the default is submission through the GuC firmware. <https://wiki.archlinux.org/title/Intel_graphics>
- The `xe` driver enables the GuC by default. (Arch wiki, same link.)
- AMD GPUs need several firmware files to start. UNVERIFIED: this study did not cite a source for the list.

### What a device service that owns the GPU must do at minimum

1. **Map the device**: PCI configuration, the register region, the aperture.
2. **Power**: wake the render engine and keep it awake while work runs. Intel calls this forcewake.
3. **Memory**: build GPU page tables. Give each program its own GPU address space, so that one program cannot read the memory of another. Pin and unpin pages.
4. **Contexts**: create the per-program state image that the device saves and restores.
5. **Submission**: put a batch address in the submission registers (execlists) or send it to the firmware scheduler (GuC). Order the work of several programs.
6. **Completion**: handle the interrupt, then write a completion record.
7. **Recovery**: detect a hang, reset the engine, mark the guilty context as lost. WebGPU has "device lost" for this.
8. **Display**: at first, keep the mode that the firmware set and change only the address of the visible plane. A full modeset (clocks, links, panels) is the large part, and it can come later. UNVERIFIED: this study did not confirm that a plane address change works on each generation without a full modeset.

- On an integrated GPU, GPU memory is system memory. The service needs no separate video memory manager. This removes one large part.
- With one GPU address space per program, the program's library can build batch buffers itself. The service checks memory mappings, not commands. This matches property 5 (kernel and service off the data path). UNVERIFIED: this study did not cite the Linux rule that generation 8 and later need no command check.

### The most tractable first target

**Intel integrated graphics of generation 9 to 12 (Skylake to Tiger Lake).**

- Public manuals and a machine-readable packet description exist.
- Submission needs no firmware on these generations.
- Memory is system memory.
- Tiger Lake is the newest generation with these properties, and Redox already sets modes on it.
- One fixed machine first, as property 7 requires. Each added generation costs new display code.

AMD is second: no public manuals found, firmware is required, and the kernel driver is 3 times larger. Nvidia was not studied.

## 8. The conformance test suite

Source: <https://github.com/gpuweb/cts> (measured)

| Part | Files | Lines of TypeScript |
|---|---|---|
| `src/webgpu` total | 907 | 244,041 |
| `api/validation` | 139 | 43,485 |
| `api/operation` | 81 | 33,060 |
| `shader/validation` | 221 | 50,231 |
| `shader/execution` | 375 | 80,529 |
| `src/common` (framework and runtimes) | 60 | 9,565 |
| Test specification files (`*.spec.ts`) | 698 | |

- The suite is TypeScript. It calls the JavaScript interface (`navigator.gpu`).
- The framework has four runtimes: command line, standalone page, web platform tests, server. (Measured: `src/common/runtime`.)

### How non-browser implementations run it

- **Dawn** builds `dawn.node`, a Node.js module that provides `navigator.gpu`. The command `./tools/run run-cts --bin=<build>` runs the suite. It can run against SwiftShader. <https://dawn.googlesource.com/dawn/+/HEAD/src/dawn/node/README.md>
- **wgpu** runs the suite on Deno's WebGPU binding with the `cts_runner` crate. It keeps a list of 545 selected test paths and a list of 151 expected failures. (Measured.) <https://github.com/gfx-rs/wgpu/tree/trunk/cts_runner>
- Both need a JavaScript engine and a binding from JavaScript objects to the native interface. Dawn's binding is 16,640 lines. (Measured.)

### What a system without JavaScript can do

1. **Run the suite on a development machine, not on the new system.** The front end, the WGSL compiler and the software back end are plain CPU code. Build them as a Linux library. This tests every layer except the device services.
2. **Bind that library to an existing JavaScript runtime on Linux.** Write a thin `webgpu.h` adapter above the project's interface, for tests only. Then reuse a binding that speaks `webgpu.h`. UNVERIFIED: this study did not confirm that `dawn.node` or Deno accepts a foreign implementation without changes.
3. **Convert data-driven tests to flat tables.** Most `shader/execution` tests are tables of inputs and expected intervals. Generate them once on the development machine. Run them on the new system with a native runner.
4. **Use shader corpora for the WGSL front end.** The Tint test suite has 11,952 shaders (count from `wgslender`). Naga has a corpus of 172 shaders with expected output (count from `gogpu/naga`). Each shader has a known verdict: valid or invalid.
5. **Compare pixels with a reference.** Render the same scene with the project's back end and with Dawn on SwiftShader. Compare within a tolerance.
6. **Later, if a JavaScript engine exists on the system**, the suite can run there. QuickJS is a small engine in C. <https://bellard.org/quickjs/> (UNVERIFIED: not fetched in this study.)

## 9. WebGPU mapped to the rules of the system

### Direct matches

| WebGPU | System |
|---|---|
| `GPUCommandEncoder` records commands | A command buffer in memory that the program owns (P4, P14) |
| `GPUQueue.submit` | One command record on a ring, or one direct call for the software back end |
| Every object | A handle: index and generation. Handle 0 is "none" |
| Descriptors | Records, passed by address, all-zero is valid |
| Labels, WGSL source, entry point names | String slices |
| `GPUSurface` texture | A surface in shared memory with the compositor |
| "Device lost" | A completion record. Also the result of a revoked grant |

### Asynchronous operations as completion records

Each asynchronous function takes a `u64` tag from the program. The result is one completion record with that tag.

| WebGPU operation | Completion record |
|---|---|
| `requestAdapter`, `requestDevice` | `{tag, status, handle}` |
| `mapAsync` | `{tag, status}`. The mapped range is then readable at an address in the program |
| `createRenderPipelineAsync`, `createComputePipelineAsync` | `{tag, status, handle}` |
| `popErrorScope` | `{tag, error kind, message offset, message count}` |
| `onSubmittedWorkDone` | `{tag, status}` |
| `getCompilationInfo` | `{tag, count}`, then the program reads the messages into its own buffer |
| Device lost, uncaptured error | A record with a reserved tag |

- The program reads the completion queue when it chooses. It can wait on the queue with the normal wait operation of the kernel (K4).
- No code of the library runs unless the program calls it. No thread runs a callback.
- This is the "WaitAnyOnly" mode of `webgpu.h` with the callback removed.
- A language binding can build promises, futures or callbacks above the queue. The contract does not contain them.

### Synchronous creation

- WebGPU creates buffers, textures, bind groups and pipelines with a synchronous call that returns an object at once. An invalid descriptor gives an "invalid object", and the error goes to the error scope.
- This fits a ring: the library chooses the handle, sends the creation record, and needs no reply. Dawn Wire uses this design (section 6).
- For a call across a ring, the library must own a range of handle indexes that the service accepts.

### Where validation runs

Three kinds of check exist. They have different owners.

| Check | Purpose | Runs in |
|---|---|---|
| WebGPU validation (all the rules of the specification) | Correct programs and useful errors. Identical behavior on every back end | The library, inside the program |
| Memory safety of a back end | A draw cannot read or write outside its resources | The library for the software back end. The device (GPU page tables) or the host for the others |
| Isolation between programs | One program cannot read, write or stall another | A service. Never the library |

- **The library is not trusted.** A program can link a changed library or write records by hand. Every check inside the program protects only that program.
- **Software back end**: all drawing happens in the program's address space with the program's CPU time. A wrong library damages only its own program. The compositor must check the surface record: size, format, stride and damage rectangles. It must treat pixels as untrusted data.
- **virtio-gpu**: the device has one control queue. A device service owns it and gives each program one context. The service checks resource identifiers and sizes. It does not need to understand the Venus stream; the host renderer process isolates each context. UNVERIFIED: this study did not confirm that the host isolates two contexts of one guest from each other.
- **Real GPU**: the device service gives each program its own GPU address space. The page tables are the isolation. The service checks mappings and submission records. It does not check drawing commands.
- **Shared resources** are the place where full checks must run in a service: a surface, or a texture that one program gives to another. The compositor samples them, so it must know their true size and format.
- **Contrast with browsers**: a browser validates everything in a trusted GPU process, because it does not trust the vendor driver below. The new system owns the code below and uses page tables in place of that process. The cost: the device service and the software rasterizer must have no memory error of their own.

### Language independence

- The contract is: the list of exports (scalars and record addresses), the records, the enumerations, the ring records. It is generated from one description, derived from `webgpu.yml`.
- The Odin library is one implementation of this contract. A program in C, Rust or Zig calls the same exports.
- WGSL text is data. It does not depend on a language.
- The pass encoders are the hot path. A draw call must be a direct call that writes a few words in a command buffer of the program. It must not cross a ring.

## Recommendation

- **First subset**: level 1 of section 2. It has 17 objects, one color attachment, 2D textures with one mip level, blending, scissor, instancing and copies. Build the compositor and the first UI on it and on nothing else.
- **Contract**: keep the names and semantics of `webgpu.h`. Replace its ABI: flat records with zero as default, handles, slices, completion records with a tag. Generate the description from `webgpu.yml`.
- **Shader front end**: write the WGSL front end to the full grammar from the start (template lists, abstract numerics, overload table from a definition file). Limit the first version by rejecting features, not by a different parser.
- **Shader execution, software back end**: start with an interpreter over the project's IR that executes each operation on a batch of pixels with SIMD. Put it behind one internal interface. Add an x86-64 JIT later, only after measurements show that the interpreter limits the desktop.
- **Rasterizer**: tiles, one thread per tile, a rectangle fast path, deferred passes, and damage rectangles from the first version. These decide 2D speed more than the shader executor does.
- **Order of back ends**: (1) software into the UEFI framebuffer, (2) the same software back end on virtio-gpu 2D mode, (3) Intel generation 9 to 12 on one fixed machine, (4) Venus only if accelerated graphics in a virtual machine becomes a goal.
- **Reason to move Venus last**: its SPIR-V writer and Vulkan-shaped back end are not reused by a native driver. The owner's order (virtio-gpu second) is kept by the 2D mode.
- **Validation**: full WebGPU validation runs in the library, always on. Isolation runs in services: the compositor checks surface records, device services check memory mappings and submissions. No service trusts the library.
- **Testing**: build the library for Linux as well. Run the conformance suite and pixel comparisons there. Run flat-table tests and shader corpora on the new system.
- **Size estimate, level 1** (Odin lines, estimate): contract records and handle tables 3,000; front end with validation 8,000 to 12,000; WGSL front end and IR 15,000 to 22,000; interpreter 3,000 to 5,000; rasterizer, sampling, blending, formats 8,000 to 12,000; surface and framebuffer presentation 1,000 to 2,000. Total 40,000 to 55,000.
- **Size estimate, later** (estimate): levels 2 to 4 on software add 40,000 to 60,000. An x86-64 JIT adds 8,000 to 12,000. virtio-gpu 2D adds 1,500. An Intel device service adds 15,000 to 30,000, its user-side back end 20,000 to 30,000, and its shader compiler 20,000 to 40,000. Venus adds 25,000 to 40,000.
- **Risk 1**: WGSL. The language specification is larger than the interface specification, and numeric conformance is strict. The front end is the largest part of level 1.
- **Risk 2**: the shader compiler for a real GPU. It is the largest part of the Intel work, and no manual describes how to write it; Mesa is the only reference.
- **Risk 3**: CPU speed at 4K. The estimate of section 5 is not measured. Measure a full-screen blend on the target machine before the compositor design is fixed.
- **Risk 4**: scope. The total for a conformant implementation with one real GPU is 150,000 to 250,000 lines. Each level must ship a working desktop before the next level starts.
