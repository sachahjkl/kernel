# Cryptography

The cryptography of the system serves QUIC and TLS 1.3 (`docs/NETWORK.md`).

## 1. The rule: proven code, in the forms of the system

The system does not write cryptography from nothing. It takes existing code and adjusts it, with wrapper functions and a compatibility layer, so that the code uses the primitives of this system: tables and modules.

What it means here:

- **Proven code is the source.** The primitives come from existing code with a permissive license. Their arithmetic and their constant-time code stay as they are.
- **The code is in the repository.** It is not an opaque import of the collection of the compiler.
- **Only the shell changes.** The changes are listed, and a check proves them (section 4).
- **The forms of the system.** The code becomes a module with exports, a description and a hash (properties 10 and 11). The caller supplies the memory (property 14). An error is a value (`errors.Error_Record`). Batches go over tables where that form fits.

## 2. The origin, and its license

- **Origin**: Odin's `core:crypto`, from the compiler that the flake pins: the release `dev-2026-11a` of Odin, which `flake.nix` fetches by its tag and its hash. When the compiler changes, `kerneltool cryptography-take` takes the files again.
- **License of Odin, and of `core:crypto`** (its README: "This library is made available under the zlib license"): the zlib license, in `support/cryptography/LICENSE.odin.txt`. Its second clause, "Altered source versions must be plainly marked as such", is met by the first line of each file that is taken.
- **fiat-crypto**: the field arithmetic of `core:crypto/_fiat` is a port of fiat-crypto, which gives three licenses. Odin chose BSD-1-Clause; its text is in `support/cryptography/LICENSE.fiat-crypto.txt`, with the first part that is taken.
- **Review**: the README of `core:crypto` says that the packages "have not received independent third party review". The system relies on the RFC test vectors (section 5) and on the timing rules of the origin. It does not claim more.

## 3. The layout

| Path | What it is |
|---|---|
| `support/cryptography/<name>/` | The files that are taken, with the folder names of the origin (`_chacha20`, `chacha20`, `_subtle`, ...), so that the import paths of the origin need one rule only |
| `support/cryptography/compatibility_crypto`, `compatibility_endian`, `compatibility_bits`, `compatibility_bytes` | The compatibility layer: the helpers of the origin (`zero_explicit`, `compare_constant_time`, the little-endian loads, `rotate_left32`, `add_u64`, `alias_inexactly`) over the primitives of this system. The packages have their own names; the import keeps the name of the origin as its alias |
| `support/cryptography/chacha20/chacha20_implementation_portable.odin` | A file of this system in the place of `chacha20_impl.odin` of the origin: that file chooses among three implementations with `core:sys/info`, which a module does not have. The one implementation here is the portable one of the origin, unchanged |
| `support/cryptography/origin.manifest` | One line for each file that is taken: the file, the file of the origin, the BLAKE3 hash of the origin file |

**`erase_secret_bytes`** (`runtime/memory.asm`): the compatibility `zero_explicit` calls it.
- **Why the compiler cannot remove it**: the code of a module calls it by its symbol, in an object that nasm made. The modules link with no link-time optimization, so LLVM does not see its body and must take the call as a read and a write of the memory that the pointer reaches. A store of zeros that the compiler emits itself (to a variable that is dead after it) can be removed; this one cannot.
- The origin used a volatile `memset` and a fence: that is also not removable, but it depends on how the compiler treats volatile stores.

## 4. The proof of what changed

`kerneltool cryptography-origin` (also in `kerneltool check`) reads the manifest. For each file:

- the origin file, under `ODIN_ROOT` of the compiler that built the tool, has the BLAKE3 hash of the manifest. If not, the compiler of the flake changed;
- the origin with the listed changes is the file of the repository, byte for byte.

The listed changes, all in `tools/kerneltool/cryptography_origin.odin` (`cryptography_import_changes`, applied in this order):
1. The first line: "// Altered source: Odin dev-2026-11a, <origin path>; only its imports changed (...)".
2. `"core:crypto"` becomes `crypto "support:cryptography/compatibility_crypto"`.
3. `"core:crypto/hash"` becomes `hash "support:cryptography/compatibility_hash"` (before the next rule, which would send it to a copy of the origin package).
4. `"core:crypto/` becomes `"support:cryptography/`.
5. `"core:encoding/endian"`, `"core:math/bits"` and `"core:bytes"` become the compatibility packages, with the name of the origin as their alias.

The check also covers the folders, not only the listed files: Odin compiles each `.odin` file of a package folder, so a new file in a folder of a copy would change the code with no line of a manifest.
- It walks each folder of `support/cryptography`. Each `.odin` file must be a line of `origin.manifest` or a line of `system_files.manifest`, and no file is in both or two times.
- `system_files.manifest` lists the files that the system wrote (the compatibility layer, the files in the place of a hardware dispatch, the tests), each with its BLAKE3 hash. A change of one of them fails the check until a person writes its new hash: `kerneltool cryptography-system-hashes` prints the lines.
- An origin path starts with `core/crypto/` and holds no `..`; a file of the repository starts with `support/cryptography/` and holds no `..`. A line cannot take a file from another part of Odin or of the host.
- A symbolic link anywhere under `support/cryptography` fails the check: a folder of a copy that points elsewhere would bring `.odin` files that no list names.
- A file that is not a `.odin` file, a `LICENSE.*` file of the top folder or one of the two manifests fails the check: a `#load` or a `foreign import` could read it, and no list has its hash.
- The system list is a tripwire, not a proof of review: whoever changes a file of the system also writes its new hash. The review of the change reads it.

A new file comes with `kerneltool cryptography-take <origin> <file>`, which writes it and prints its line of the manifest.

### Listed adjustments

A taken file can also have listed adjustments: `cryptography_adjustments` in `tools/kerneltool/cryptography_origin.odin` names, for one file of the origin, lines of the origin and the lines in their place. The lines of the origin must be in the origin exactly one time: when the origin changes them, the check fails and a person reads the adjustment again. The first line of an adjusted file says so.

There is one correction, as five adjustments of `_chacha20/chacha20.odin` and four lines of the system's own `chacha20/chacha20_implementation_portable.odin`. The fault of the origin: `check_counter_limit` refused the block with the counter 2^32 - 1, which RFC 8439 allows, and its branch for the counter of 64 bits allowed a call that wraps the counter. QUIC header protection (RFC 9001, section 5.4.4) takes the counter from the ciphertext of a packet, so a peer could stop a program with one datagram. The correction allows a call that ends on the last block, refuses a call that goes past it, refuses each call after it until `seek` or `init`, and puts back the first word of the IV that the 64-bit increment of the implementation carried into. It is offered to Odin as its pull request 8329. When the release that the flake pins has it, the adjustments go.

## 5. The primitives, and their tests

37 files are taken, in 20 packages. Each line of the table has a host test with its published vectors (`support/cryptography/vectors`), and the module runs the same vectors on the machine (section 6).

| Primitive | Origin packages | Vectors |
|---|---|---|
| ChaCha20 | `_chacha20`, `_chacha20/ref`, `chacha20`, `_subtle` | RFC 8439 2.3.2, 2.4.2, A.1 |
| Poly1305 | `poly1305`, `_fiat`, `_fiat/field_poly1305` | RFC 8439 2.5.2 |
| ChaCha20-Poly1305 | `chacha20poly1305` | RFC 8439 2.8.2, and a changed byte that `open` refuses |
| SHA-256, SHA-384, SHA-512 | `sha2` (`sha2.odin`, `sha512_impl_hw_gen.odin`) | FIPS 180-4, "abc" |
| HMAC | `hmac` | RFC 4231, test case 2 |
| HKDF | `hkdf` | RFC 5869 A.1 and A.3 |
| X25519 | `x25519`, `_edwards25519`, `_fiat/field_curve25519`, `_fiat/field_scalar25519` | RFC 7748 5.2 and 6.1 |
| Ed25519 | `ed25519` | RFC 8032 7.1, tests 1 and 2, and a changed signature that `verify` refuses |
| AES-128-GCM | `aes` (`aes.odin`, `aes_ecb.odin`, `aes_ctr.odin`, `aes_gcm.odin`, `aes_impl.odin`), `_aes`, `_aes/ct64` | The GCM specification, test case 4, and a changed tag that `open` refuses |

**What the system puts in the place of the hardware code.** The origin chooses a hardware implementation by the processor features, which it reads with `core:sys/info`; a module does not have that package. On another processor the origin itself compiles a generic file. A file of the system takes the place of that dispatch, with the procedures of that generic file, unchanged:
- `sha2/sha256_implementation_portable.odin`;
- `aes/aes_implementation_portable.odin`;
- `_aes/hw/no_hardware.odin` (the package `aes_hw`, which says that no hardware GHASH is used);
- `chacha20/chacha20_implementation_portable.odin`.

So the code that runs is the portable code of the origin: the bitsliced, constant-time AES of `_aes/ct64`, and the portable SHA-2 and ChaCha20.

**`compatibility_hash`** takes the place of `core:crypto/hash` for `hmac` and `hkdf`. The origin package imports each hash of Odin, `core:io` and `core:os`; this one has the SHA-2 algorithms only, with the names of the origin.

**`core:reflect`** stays an import of the compiler collection: `aes_impl.odin` sets the variant of a union with it. It is not cryptography, and its code is in the hash of the module.

**`HAS_RAND_BYTES` is false.** `ed25519.private_key_generate` of the origin draws from the operating system; here a key comes from the generator of the program (`support/random`), through `private_key_set_bytes`.

## 6. The module `cryptography`

`modules/cryptography` is one module of code with exports, a description and a hash. A program imports it through its import slots, as `agenda` imports `calendar`; the console can call it.

| Export | Parameters | Result |
|---|---|---|
| `seal_with_chacha20_poly1305`, `seal_with_aes_128_gcm` | key, nonce (12), additional data, text, result, error | The sealed text and its tag of 16 bytes |
| `open_with_chacha20_poly1305`, `open_with_aes_128_gcm` | key, nonce, additional data, sealed text, result, error | The text, or `Not_Authentic` with no byte |
| `sha256`, `hmac_sha256` | text (and key), result | 32 bytes |
| `hkdf_sha256_extract`, `hkdf_sha256_expand` | salt and input, or key, info and length; result, error | 32 bytes, or `length` bytes (1 to 8160) |
| `x25519` | scalar, point, result, error | 32 bytes; a result of zeros (a point of small order) is `Not_Authentic` |
| `ed25519_public_key`, `ed25519_sign`, `ed25519_verify` | private key or public key, message, signature, error | 32 bytes, 64 bytes, or 0 / `Not_Authentic` |
| `header_protection_mask_with_aes_128`, `header_protection_mask_with_chacha20` | key (16 or 32 bytes), sample (16 bytes), result, error | The 5 bytes of the QUIC header protection mask (RFC 9001, sections 5.4.3 and 5.4.4; `docs/QUIC.md`) |

**The forms of the system.**
- **The caller supplies each byte.** A Text parameter is the bytes of the caller; the result is a buffer of the caller. For a seal, a hash or a key, a buffer that is too small gets no byte, and the count says the size that it needs (the rule of a Text result). For an open, a buffer that is too small is the error `Too_Small` with a negative count: a caller that reads a count of zero or more as a success must not read the old bytes of its buffer as an authentic text.
- **Each byte of the caller is read once.** Another thread of the caller, or another program that can write the memory of an argument, can change it during the call. So the module reads the header of each Text and of the result once, at the entry, and copies each input that the code of the origin reads more than once into its own memory, with a limit:

| Input | Why the origin reads it more than once | Copy, and its limit |
|---|---|---|
| The sealed text of an open | The tag is checked over the text, then the text is decrypted: a change between the two gives a forged text with a positive count | Into the result (each byte read once), then the open in place; the tag into the module |
| The nonce, the additional data | The nonce makes the key of Poly1305 and the stream; the additional data is short | Into the module: 12 bytes; 2048 bytes (the header of a QUIC packet with its token, or a Retry Pseudo-Packet: one datagram) |
| The message of `ed25519_sign` | It is hashed two times, for r and for the digest of R, A and M: two signatures with one r and two messages give the private key | Into the module: 4096 bytes (the content of a TLS 1.3 CertificateVerify has 146) |
| The message and the signature of `ed25519_verify` | Read once by the origin; copied for one rule | Into the module: 4096 and 64 bytes |
| The info of `hkdf_sha256_expand` | Read once for each block of output | Into the module: 1024 bytes (a TLS 1.3 HkdfLabel has 514) |
| The output of HKDF, HMAC, Ed25519 | The origin computes in its output and reads it back (each block of HKDF; R of a signature) | Made in the module, copied to the result at the end |

- **Which arguments must be private memory of the caller**: the result of each export. A seal computes the tag over the bytes that it wrote in the result, and an open decrypts in place in the result after it copied the sealed text there; a result that another party writes during the call gets a tag over its bytes, or a text that was not checked. The text of a seal and the input of a hash are read once and can be in shared memory; the hash is then of the bytes that the call read.
- **A result that overlaps an argument** with an offset is the error `Bad_Value` for argument 5 (the code of the origin would stop the program); a result at the same address as the text (in place) is right.
- **A nonce never comes two times with one key**: that is the duty of the caller. With ChaCha20-Poly1305, a repeated nonce gives the XOR of the two texts and the key of Poly1305; with AES-GCM, it gives the key of GHASH, and with it forgeries.
- **A failure is an error record.** A key or a nonce of another size gives `Too_Small`, `Too_Long` or `Empty`, with the number of the argument and the size that it must have. A tag or a signature that does not verify gives the new kind `Not_Authentic` (`contract/errors`, with its sentence in `support/sentence`). An open leaves no byte of a text that is not authentic in the result: it erases what it wrote. A caller cannot take a failed open for a success, because the count is negative. X25519 gives `Bad_Value` for argument 2 for a point of small order, whose shared secret is 32 zero bytes: it is a point that shares no secret, not a text that is not authentic.
- **Secrets are erased, and so is the stack below each export.** Each export copies a key into its own frame and erases the copy. The frames of the code of the origin under it also hold secrets: the SHA-512 of an Ed25519 private key (its scalar and its nonce prefix), the expanded AES key, the words of the ChaCha20 key, the states of SHA-2 and HMAC. So each export, after its work, calls `erase_stack_below_the_caller` (`runtime/memory.asm`): it writes 0 in the 16 KiB below the stack pointer. The largest frames under an export are its own copies (8160 bytes of HKDF output and 1024 bytes of info, or 4096 bytes of a message, or 2048 bytes of additional data) and the frames of the origin under them (states of some hundred bytes, points of 160 bytes, the bitsliced AES state), together under 12 KiB. This is a reasoned size, not a measure (`llc -stack-size-section` can measure the frames). What stays: the registers after the return, the copies that the caller makes, and the memory of the caller. The cost is 2048 stores of 8 bytes in each call, some hundred nanoseconds; a QUIC packet makes two calls (the AEAD and the header protection mask).
- **The erasure goes from the top down, and a thread needs 24 KiB of stack.** `erase_stack_below_the_caller` writes from just below the stack pointer down to 16 KiB below it, 8 bytes at a time. If the stack of the thread is shorter, the first store past its bottom hits the unmapped page under the stack, and the program stops there: no byte of the mapping under that page (a ring, a region that another program shares) is written. So a thread that calls the module or draws random bytes needs 16 KiB below its frame at the call, and its own frames: 24 KiB in all. The threads of `system.thread_start` have 64 KiB by default (`THREAD_STACK_PAGES`) and the main thread 256 KiB; a thread started with fewer than 6 pages, or one that has used more than 40 KiB of its 64 KiB at the call, stops at its guard page.
- **One call at a time per thread, no hidden state, no allocation.** The code of the origin runs with a zero `context`. `runtime.default_context()` stores the default random generator of the runtime, whose state is thread-local, and a module has no thread-local data (the convert step of the tool refuses it).
- **A key of zeros is valid** for the AEADs and HKDF, as their standards say. X25519 refuses the result of zeros, not the key.

**What the module boundary costs**, measured by `cryptography_vectors` on the machine (the mean of 100 calls, host load about 20):

| Call | Time |
|---|---|
| One call of an export through its import slot | 4 to 12 ns |
| Seal 1200 bytes with ChaCha20-Poly1305 | 2.4 us (about 490 MB/s) |
| Seal 1200 bytes with AES-128-GCM | 11.2 us (about 106 MB/s): the portable bitsliced AES |
| SHA-256 of 1200 bytes | 4.7 us (about 250 MB/s) |
| HKDF expand, 32 bytes | 1.4 us |
| X25519 | 67 us |
| Ed25519 sign, verify | 80 us, 110 to 137 us |

So the module form costs nothing that matters next to the primitives.

**The seam for batches.** The module contract describes a table as a parameter (`docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters"). The module has no batch export yet: seal or open a table of packet records in one call. QUIC calls the exports one packet at a time, through one procedure table of its own (`support/quic`), so that a batch export later changes that one table only.

## 7. What is not done

- **No hardware AES or SHA.** AES-NI and the SHA extensions need the processor features; a device of the system can give them later.
- **The independent review.** The README of the origin says that its packages "have not received independent third party review"; the system adds the RFC vectors and the proof of origin, not a review of the arithmetic.
- **The batch exports** (section 6).
