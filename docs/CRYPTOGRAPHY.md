# Cryptography

Status: in construction on branch `work/tcp` (2026-11-11), for QUIC and TLS 1.3 (`docs/NETWORK.md`). The owner has not reviewed it.

## 1. The decision of the owner

The owner, 2026-11-11, word for word: "don't write cryptography from nothing, but maybe incorporate existing stuff and adjust it/provide wrappers functions/compat, so that they use OUR kernel primitives (tables, modules, shit like that)".

What it means here:

- **Proven code is the source.** The primitives come from existing code with a permissive license. Their arithmetic and their constant-time code stay as they are.
- **The code is in the repository.** It is not an opaque import of the collection of the compiler.
- **Only the shell changes.** The changes are listed, and a check proves them (section 4).
- **The forms of the system.** The code becomes a module with exports, a description and a hash (properties 10 and 11). The caller supplies the memory (property 14). An error is a value (`errors.Error_Record`). Batches go over tables where that form fits.

## 2. The origin, and its license

- **Origin**: Odin's `core:crypto`, from the compiler that the flake pins: the tag `dev-2026-05` of Odin (nixpkgs takes it from `https://github.com/odin-lang/Odin/archive/refs/tags/dev-2026-05.tar.gz`).
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

The listed changes, all in `tools/kerneltool/cryptography_origin.odin`:
1. The first line: "// Altered source: Odin dev-2026-05, <origin path>; only its imports changed (...)".
2. `"core:crypto"` becomes `crypto "support:cryptography/compatibility_crypto"`.
3. `"core:crypto/` becomes `"support:cryptography/`.
4. `"core:encoding/endian"`, `"core:math/bits"` and `"core:bytes"` become the compatibility packages, with the name of the origin as their alias.

A new file comes with `kerneltool cryptography-take <origin> <file>`, which writes it and prints its line of the manifest.

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

**The forms of the system.**
- **The caller supplies each byte.** A Text parameter is the bytes of the caller; the result is a buffer of the caller. A buffer that is too small gets no byte, and the count says the size that it needs (the rule of a Text result).
- **A failure is an error record.** A key or a nonce of another size gives `Too_Small`, `Too_Long` or `Empty`, with the number of the argument and the size that it must have. A tag or a signature that does not verify gives the new kind `Not_Authentic` (`contract/errors`, with its sentence in `support/sentence`). An open writes no byte of a text that is not authentic: it erases what it wrote. A caller cannot take a failed open for a success, because the count is negative.
- **Secrets are erased.** Each export copies a key into its own frame and erases the copy before it returns. The caller erases its own copies.
- **No hidden state, no allocation.** The code of the origin runs with a zero `context`. `runtime.default_context()` stores the default random generator of the runtime, whose state is thread-local, and a module has no thread-local data (the convert step of the tool refuses it).
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

**The seam for batches.** The module contract cannot describe a table as a parameter in `master` yet. The branch `work/tables` designs it, with `^system.Table_To_Read(Name)`, `Table_To_Change` and `Bytes_To_Read` (`docs/MODULE_CONTRACT.md` on that branch). When it is merged, the module gains the batch exports: seal or open a table of packet records in one call. Until then QUIC calls the exports one packet at a time, through one procedure table of its own (`support/quic`), so that a batch export later changes that one table only.

## 7. What is not done

- **No hardware AES or SHA.** AES-NI and the SHA extensions need the processor features; a device of the system can give them later.
- **The independent review.** The README of the origin says that its packages "have not received independent third party review"; the system adds the RFC vectors and the proof of origin, not a review of the arithmetic.
- **The batch exports** (section 6).
