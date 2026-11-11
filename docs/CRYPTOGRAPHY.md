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

- **Origin**: Odin's `core:crypto`, from the compiler that the flake pins: the release `dev-2026-11a` of Odin, which `flake.nix` fetches by its tag and its hash. The first files were taken from `dev-2026-05`; they were taken again from `dev-2026-11a` when the compiler changed (`kerneltool cryptography-take`), and the origin had corrected its ChaCha20 counter check and rewritten `_subtle` since.
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
1. The first line: "// Altered source: Odin dev-2026-11a, <origin path>; only its imports changed (...)".
2. `"core:crypto"` becomes `crypto "support:cryptography/compatibility_crypto"`.
3. `"core:crypto/` becomes `"support:cryptography/`.
4. `"core:encoding/endian"`, `"core:math/bits"` and `"core:bytes"` become the compatibility packages, with the name of the origin as their alias.

A new file comes with `kerneltool cryptography-take <origin> <file>`, which writes it and prints its line of the manifest.

## 5. The primitives, and their tests

| Primitive | Origin files | Vectors | State |
|---|---|---|---|
| ChaCha20 | `_chacha20/chacha20.odin`, `_chacha20/ref/chacha20_ref.odin`, `chacha20/chacha20.odin`, `_subtle/subtle.odin` | RFC 8439 2.3.2, 2.4.2, A.1 (vectors 1 and 2): host tests | Taken; the random generator of each program uses it (`docs/RANDOMNESS.md`) |

The next primitives, in the order of QUIC: Poly1305 and ChaCha20-Poly1305 (RFC 8439), SHA-256 and SHA-384, HMAC and HKDF (RFC 5869), AES-128-GCM (the Initial packets of QUIC use it), X25519 (RFC 7748), Ed25519 (RFC 8032), then the packet protection of RFC 9001 (its appendix A).
