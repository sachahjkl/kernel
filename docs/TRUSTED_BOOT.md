# Trusted boot

This guide says what verifies what at the start of the machine, with which key, and at which moment. It also says what each part does not protect. The terms are in `docs/GLOSSARY.md`, section "Trusted boot".

The trusted boot has three layers. Each layer works without the next one.

| Layer | What it adds | State |
|---|---|---|
| 1. The signed system description | The boot program verifies a signature and every hash before the kernel starts. The root service checks the boot image again | Built |
| 2. The measure | The firmware extends PCR 11 of the TPM with the hash of the system description, before the kernel starts | Built |
| 3. Secure Boot | The firmware verifies the boot program before it starts it | Designed, not built |

## 1. The claims

Each claim names what verifies, what it verifies, with which key, and when.

1. At each boot, before the kernel starts, the boot program verifies the description signature with the Ed25519 public key that it holds. The signed message is the label `system description signature 1` and the BLAKE3 hash of the system description.
2. After that, and before the kernel starts, the boot program compares the kernel module file and each module and resource of the boot image with the system description: the name, the kind, the size, the BLAKE3 hash of the bytes, and the hash that the boot image states in its entry.
3. The boot program checks the copy of the boot image that the kernel receives, and the kernel module file that it loads.
4. When the firmware has a TPM, and after the checks of claims 1 and 2, the firmware extends PCR 11 with the SHA-256 hash of the system description, at the request of the boot program. The boot program reads PCR 11 back and writes the value in the trust record.
5. Before it starts the first program, the root service takes the system description of the boot image only if its BLAKE3 hash is the hash that the boot program wrote in the trust record. Then it compares each module and resource of the boot image with it, as in claim 2.
6. After claim 5, no program can change a module of the boot image: the kernel gives the pages of the boot image to the root service with the right Read and with no right Write.
7. Nothing verifies the boot program while Secure Boot is off. The trust record and the boot display say "verified by the boot program, which the firmware did not verify".

## 2. What each layer protects, and what it does not

### Layer 1: the signed system description

It protects against:

- a module, a resource or the kernel that a fault of a disk, a copy or a build changed;
- a module of another build put in the boot image;
- a system description that someone changed without the private key of the signing key.

It does not protect against:

- **a replaced boot program.** The firmware does not verify the boot program. A person who can write the boot volume can replace the boot program, its public key and its checks. So the checks find a damaged or swapped file. They do not stop an attacker who can write the boot volume.
- **a system that the test signing key signed.** Its private key is published: anyone can sign a system with it. The boot display shows "the TEST key: its private key is public" in red, and the root service writes a warning on the log.
- **an older system that the same key signed.** The boot program accepts each description that the key signed. No counter refuses an older one.
- **a stolen private key.** A person who has it can sign a system that the boot program accepts.
- **the firmware, and the kernel after the start.** The checks run once, at the start. A fault of the kernel or a device that writes memory directly (DMA) is not in their scope.

### Layer 2: the measure

It adds a record that the TPM keeps until the next reset of the machine. No code that runs after the boot program can set PCR 11 back to an earlier value. A sealed key or a remote party can depend on that value. The system does neither yet.

It does not protect against:

- **a boot program that lies.** A replaced boot program can extend PCR 11 with the hash of a correct description and then start other code. The measure is as honest as the boot program. The firmware of the test machine also measures the boot program itself into PCR 4 (TCG PC Client Platform Firmware Profile), so a party that reads PCR 4 and PCR 11 together can see a replaced boot program. The system does not read PCR 4.
- **a machine with no TPM.** The boot continues. The trust record says `No_Tpm`, and the boot display says "no TPM: the system is not measured".
- **a TPM that is software.** The test machine uses `swtpm` on the host. The host can read and change its state.

### Layer 3: Secure Boot (designed)

It closes the gap of layer 1: the firmware starts only a boot program that the firmware signing key signed. Then the trust record says "verified by the firmware (Secure Boot), then the boot program". Section 7 gives the design.

## 3. The system description

The system description is one file. It is the identity of one version of the whole system (`contract/system_description`).

```
Header, 16 bytes:
  magic        u64   0x5243534544535953 (the bytes "SYSDESCR")
  version      u32   1
  entry_count  u32   1 to 4096
Entry, 80 bytes, entry_count times:
  name         [32]u8   the name; zero bytes after it
  kind         u32      1 kernel, 2 module, 3 resource
  reserved     u32      0
  size         u64      the bytes of the file
  hash         [32]u8   the BLAKE3 hash of the bytes of the file
```

All numbers are little-endian. The file has no other byte.

The rules that make one system have one description, and one hash:

- Entry 0 is the kernel module. The modules of the boot image come next, in the order of the boot image. The resources come last, in the order of the boot image.
- A name has one byte at least, then zero bytes only. Each reserved field is zero.
- The reader refuses a file of another size, another magic, another version, or another order of kinds.

The boot image holds the system description and its description signature as its two last resources: `system_description` and `system_description_signature`. The description does not list these two resources: a file cannot hold its own hash. The description also does not list the boot program, for the same reason: the boot program holds the boot image. Layer 3 covers the boot program.

The checks fail on the first entry that differs:

| Fault | Meaning |
|---|---|
| `Not_Valid` | The description does not follow the format |
| `Image_Not_Valid` | The tables of the boot image do not fit in it, or its two last resources are not the description and its signature |
| `Count_Differs` | The boot image has more or fewer entries than the description lists |
| `Name_Differs`, `Kind_Differs`, `Size_Differs` | The entry at this place differs |
| `Stated_Hash_Differs` | The boot image states another hash in its entry. The loader gives that hash to the program as its identity |
| `Hash_Differs` | The bytes of the file have another hash |
| `Outside_Image` | The entry points outside the boot image |

## 4. What a failure shows

A failed check of the boot program stops the boot. The kernel does not start.

- The serial log has one line with the file and the two hashes: `boot program: console does not have the hash of the system description: expected <64 digits>, found <64 digits>`. A wrong signature gives `boot program: the signature of the system description is wrong`.
- The boot display shows the same failure in red in its head, with the first 16 digits of each hash. Its step is "the kernel module" for the kernel, else "the boot image".
- The boot program turns off the watchdog of the firmware, so the failure stays on the screen until a person stops the machine.

A failed check of the root service stops the start of the programs. The boot display shows "the start failed:" and the file, and the log has the two hashes.

The boot display has three facts under the tiles of the boot image, from the trust record:

| Fact | Values |
|---|---|
| signed by | "the TEST key: its private key is public" (red), or "the key" and the first 8 bytes of the public key |
| verified by | "the boot program, which the firmware did not verify", or "the firmware (Secure Boot), then the boot program", or "the check failed" |
| measured | "PCR 11 =" and the first 16 bytes of the value, or "no TPM: the system is not measured", or a refusal of the firmware |

## 5. The signing key

The signing key is an Ed25519 key pair of the person who owns the machine.

- **Where it lives**: the private key is a file outside the repository. The environment variable `SYSTEM_SIGNING_KEY` names it at build time. The tool refuses a path inside the repository. The boot volume holds the public key and the description signature only.
- **With no variable**: the build signs with the test signing key of `resources/keys`, and the machine says that it is not trusted.

### Creation

1. Run `nix develop -c kerneltool key new <folder>`, with a folder outside the repository.
2. The tool writes `<folder>/signing_key`: the private key, 64 hexadecimal digits, readable by its owner only, in a folder that only its owner can open. It writes `<folder>/signing_key.public`: the public key.
3. The tool refuses to replace an existing key.

### Use

1. Set `SYSTEM_SIGNING_KEY=<folder>/signing_key` before each build.
2. Run `kerneltool key show` to print the public key that the build uses.
3. The build puts the public key in the boot program and signs the description of each boot volume.

### Backup

1. Copy `signing_key` to two media that stay offline, in two places. The 64 digits can also be printed on paper.
2. The public key is not secret.

### Loss

1. A lost private key cannot sign a new system description. The boot program of the machine still accepts the descriptions that the lost key signed.
2. To recover, make a new key, build a new boot program with the new public key, and install it on the boot volume. With Secure Boot, the firmware signing key must also sign that boot program.
3. If the firmware signing key is lost too, the firmware refuses each new boot program until a person present at the machine enrols a new certificate in the setup of the firmware.

### Theft

A person who has the private key can sign a system that the boot program accepts. Make a new key and a new boot program at once. No list of revoked keys exists.

## 6. The measure

- **The register**: PCR 11. The TCG rules for PC firmware leave PCR 8 to 15 to the operating system. The conventions of Linux give PCR 11 to the whole system image that a boot stage measures before the kernel starts, which is what this measure is. The firmware of the test machine does not write PCR 11.
- **The value**: the firmware hashes the system description with SHA-256 and extends PCR 11 with it, in each active bank. In the SHA-256 bank, after a reset, PCR 11 then holds `SHA-256(32 zero bytes || SHA-256(description))`. `kerneltool` computes the same value from the description of the boot volume and compares it with the value that the boot program read back.
- **The event**: type `EV_IPL`, in the event log of the firmware. Its data is the signed message: the label and the BLAKE3 hash. The event log names the system by its identity, BLAKE3; the TPM has no BLAKE3 bank, so the register holds SHA-256.
- **The path**: the boot program calls `HashLogExtendEvent` of `EFI_TCG2_PROTOCOL`, then `TPM2_PCR_Read` through `SubmitCommand`. The firmware talks to the TPM. The boot program has no TPM driver.
- **The order**: the boot program measures after the checks of section 1 and before it leaves the firmware services.

The test machine of the measure uses the firmware with a TPM driver (`OVMF_FULL_CODE`) and a software TPM: `kerneltool` starts `swtpm socket --tpm2` with a new state for each machine, waits for its socket, starts QEMU with `-tpmdev emulator` and `tpm-tis`, and stops `swtpm` after QEMU. That firmware needs the system management mode of QEMU (`-machine q35,smm=on`).

## 7. Secure Boot: the design

Not built. What the layer needs:

1. **A second key.** UEFI Secure Boot verifies Authenticode signatures with RSA keys and X.509 certificates. It cannot verify Ed25519. So the person who owns the machine has a firmware signing key: an RSA-2048 key and a certificate. In the design, `kerneltool key new` also makes it, with `openssl req -x509 -newkey rsa:2048 -nodes -days 36500`, in the same folder.
2. **The signature of the boot program**: `sbsign --key <key> --cert <certificate> --output BOOTX64.EFI <unsigned>`, of the package `sbsigntool` of Nixpkgs. An existing signer of Authenticode is used, not a writer of the tool.
3. **The enrolment in the test machine**: `virt-fw-vars` of the package `python3Packages.virt-firmware` writes a copy of `OVMF_FULL_VARS` with the certificate as PK, KEK and db, and Secure Boot on (`--set-pk`, `--add-kek`, `--add-db`, `--secure-boot`). The flags are from the documentation of virt-firmware and are not tested here. The copy goes to `build/`, one for each machine, as for the other variable stores.
4. **The test**: one machine boots the signed boot program and its trust record says `Firmware_And_Boot_Program`. One machine boots a signed boot program with one byte changed, and the firmware refuses it: the serial log has no line `boot program: started`, and the firmware shows its refusal.
5. **What the boot program reads**: the variable `SecureBoot` of the firmware. The boot program already reads it: with value 1, the trust record says `Firmware_And_Boot_Program`.

What layer 3 does not protect against: the keys in the db of the firmware. If the db also holds the keys of another vendor, each boot program that such a key signed starts. The store of the test machine holds the certificate of the person only.

## 8. The costs

- **Time**: the boot program hashes the kernel and the whole boot image, and the root service hashes the boot image again. The log gives both times: `root: the boot program checked the signature and every hash in <n> us` and `root: the boot image agrees with the system description ...: <n> modules and resources checked in <n> us`.
- **Two hash functions**: BLAKE3 is the identity of each file and of the description. The TPM uses SHA-256 because it has no BLAKE3 bank.
- **Two keys with Secure Boot**: an Ed25519 key for the description and an RSA key for the firmware.
- **The boot volume of each test**: the build signs one boot image for each boot volume, because the kernel of one test volume differs.

## 9. Code

| Part | File |
|---|---|
| The format, its reader and its checks | `contract/system_description/system_description.odin` |
| The trust record | `contract/boot_info/boot_info.odin` (`Boot_Trust`) |
| The checks and the measure of the boot program | `boot/trust.odin` |
| The check of the root service | `programs/root/trust.odin` |
| The facts of the boot display | `support/bootscreen/bootscreen.odin` (`trust_facts`) |
| The signature, the keys, the command `key` | `tools/kerneltool/system_description.odin` |
| The four machines of `test trusted_boot` | `tools/kerneltool/trusted_boot_scenario.odin` |
| The Ed25519 code of the boot program | `support/cryptography/ed25519` (`docs/CRYPTOGRAPHY.md`) |
