# Trusted boot

This guide says what verifies what at the start of the machine, with which key, and at which moment. It also says what each part does not protect. The terms are in `docs/GLOSSARY.md`, section "Trusted boot".

The trusted boot has three layers. Each layer works without the next one.

| Layer | What it adds | State |
|---|---|---|
| 1. The signed system description | The boot program verifies a signature and every hash before the kernel starts. The root service checks the boot image again | Built |
| 2. The measure | The firmware extends PCR 11 of the TPM with the hash of the system description, before the kernel starts | Built |
| 3. Secure Boot | The firmware verifies the Authenticode signature of the boot program before it starts it | Built |

## 1. The claims

Each claim names what verifies, what it verifies, with which key, and when.

1. At each boot, before the kernel starts, the boot program verifies the description signature with the Ed25519 public key that it holds. The signed message is the label `system description signature 1` and the BLAKE3 hash of the system description.
2. After that, and before the kernel starts, the boot program compares the kernel module file and each module and resource of the boot image with the system description: the name, the kind, the size, the BLAKE3 hash of the bytes, and the hash that the boot image states in its entry.
3. The boot program checks the copy of the boot image that the kernel receives, and the kernel module file that it loads.
4. When the firmware has a TPM, and after the checks of claims 1 and 2, the firmware extends PCR 11 with the SHA-256 hash of the system description, at the request of the boot program. The boot program reads PCR 11 back and writes the value in the trust record.
5. Before it starts the first program, the root service takes the system description of the boot image only if its BLAKE3 hash is the hash that the boot program wrote in the trust record. Then it compares each module and resource of the boot image with it, as in claim 2.
6. After claim 5, no program can change a module of the boot image: the kernel gives the pages of the boot image to the root service with the right Read and with no right Write.
7. Nothing verifies the boot program while Secure Boot is off. The trust record and the boot display say "verified by the boot program, which the firmware did not verify".
8. With Secure Boot on, before it starts the boot program, the firmware verifies its Authenticode signature with the certificates in its variable `db`. The build signs the boot program with the firmware signing key, and the test machine has the certificate of that key as its only entry of `db`.
9. The boot program reads the variable `SecureBoot` of the firmware. With the value 1, the trust record says `Firmware_And_Boot_Program`, and the boot display says "verified by: the firmware (Secure Boot), then the boot program". The value 1 means that a certificate of `db` verified the boot program: on a machine whose `db` also holds the certificates of a vendor, it can be a certificate of that vendor (section 7).

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
- **a changed debug image.** The debug image (`DEBUG/OBJECTS.IMG`, beside the boot program) is not in the boot image, the system description does not list it, and the boot program reads it with no check. A person who can write the boot volume can make a stop report show false names of procedures and lines. No code comes from it, and each reader checks the form of each debug object before it reads it (`MODULE_CONTRACT.md`, "Debug information").

The second check, by the root service, finds a fault of the path from the boot program to the first program: a fault of the copy of the boot image, or of the kernel. It does not find an attacker: no program can write the pages of the boot image before it. Its time on the test machine: ____ (the line `root: the boot image agrees ...` of the log gives it at each boot).

### Layer 2: the measure

It adds a record that the TPM keeps until the next reset of the machine. No code that runs after the boot program can set PCR 11 back to an earlier value. A sealed key or a remote party can depend on that value. The system does neither yet. The root service puts the value in the record of principal 0, the machine (`PRINCIPALS.md`, section 2).

It does not protect against:

- **a boot program that lies.** A replaced boot program can extend PCR 11 with the hash of a correct description and then start other code. The measure is as honest as the boot program. The firmware of the test machine also measures the boot program itself into PCR 4 (TCG PC Client Platform Firmware Profile), so a party that reads PCR 4 and PCR 11 together can see a replaced boot program. The system does not read PCR 4.
- **a machine with no TPM.** The boot continues. The trust record says `No_Tpm`, and the boot display says "no TPM".
- **a TPM that the firmware stopped using.** The boot continues. The trust record says `Refused`, and the boot display says "TPM refused the measure" in red (section 6).
- **a TPM that is software.** The test machine uses `swtpm` on the host. The host can read and change its state.

### Layer 3: Secure Boot

It closes the gap of layer 1: the firmware starts only a boot program that a certificate of its `db` verifies. A person who can write the boot volume can no longer replace the boot program, its public key or its checks without the private key of the firmware signing key. Then a measure in PCR 11 comes from a boot program that the firmware verified.

It does not protect against:

- **an older boot program, or an older system, that the same keys signed.** No counter in the TPM refuses it: not built.
- **the other certificates of `db`.** A machine whose `db` holds the certificates of a vendor starts each boot program that the vendor signed.
- **a change of the variables of the firmware by a person at the machine.** The setup of the firmware can turn Secure Boot off or enrol another certificate. PCR 7, where the firmware measures its Secure Boot state, is read by nothing.
- **PCR 4.** The firmware measures the boot program there. The system does not read it.

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
- The reader refuses two entries with one name: the loader finds a module by its name.
- A boot volume with no system description does not boot: there is no state "not signed".

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
- The boot program turns off the watchdog of the firmware, so the failure stays on the screen until a person stops the machine. It never returns to the firmware: the firmware does not try the next boot option.
- With Secure Boot on, a boot program that the firmware refuses never starts. The boot manager of the firmware writes `BdsDxe: failed to load Boot<number>` on the serial console, and tries its next boot option.

A failed check of the root service stops the start of the programs. The boot display shows "the start failed:" and the file, and the log has the two hashes.

The card of the boot image (`docs/DESIGN.md`, section 12) has one line "check": the count of the verified files, or, after a failure, "failed: " and the whole name of the file, in red. The part and the tile of that file are red too. The line "trust" is the last line of the card, from the trust record, in three parts with a color each. The short words fit the card; the log has the long forms.

| Part | Values |
|---|---|
| The key | "TEST key" (red), or "key" and the first 4 bytes of the public key |
| What verified | "boot program only" (the firmware did not verify the boot program), or "Secure Boot" (claim 9), or "check failed" (red) |
| The measure | "PCR 11" and the first 4 bytes of the value, or "no TPM", or "TPM refused the measure" (red), or "PCR not read" (red) |

After its first draw of the display, the boot program writes its lines on the serial port only, not through the console of the firmware, which also writes on the screen.

## 5. The signing key

The signing key is an Ed25519 key pair of the publisher of the system.

- **Where it lives**: the private key is a file outside the repository. The environment variable `SYSTEM_SIGNING_KEY` names it at build time. The tool refuses a path inside the repository. The boot volume holds the public key and the description signature only.
- **With no variable**: the build signs with the test signing key and the test firmware signing key of `resources/keys`, and the machine says that it is not trusted.
- **The rule of the file**: the tool refuses a private key file that another user owns, or that the group or the others can read, write or run. It finds the repository from the folder of `flake.nix` above the working folder, and compares resolved paths: a symbolic link to the repository is inside it.
- **In memory**: the tool clears the private key after it signed.
- **A volume for a test machine only**: beside each boot volume, the tool writes `<volume>.signed_by`. For a volume that the test keys signed, it says "the TEST signing key, whose private key is published: do not install this volume on a real machine". Do not install such a volume on a real machine: anyone can sign a system that it accepts. The test builds and the pictures of the site use the test keys.

### Creation

1. Run `nix develop -c kerneltool key new <folder>`, with a folder outside the repository.
2. The tool writes `<folder>/signing_key`: the private key, 64 hexadecimal digits, readable by its owner only, in a folder that only its owner can open. It writes `<folder>/signing_key.public`: the public key. It creates each file exclusively: a file or a symbolic link at that path makes it stop.
3. The tool then writes the firmware signing key with `openssl`: `<folder>/firmware_signing_key.pem` (the RSA-2048 private key) and `<folder>/firmware_signing_key.crt` (its certificate).
4. The tool refuses to replace an existing key.
5. To enrol the certificate in the firmware of a real machine, a person present at the machine uses the setup of the firmware: the certificate `firmware_signing_key.crt` as the platform key, the key exchange key and the entry of `db`, then Secure Boot on. The steps depend on the firmware of the machine.

### Use

1. Set `SYSTEM_SIGNING_KEY=<folder>/signing_key` before each build.
2. Run `kerneltool key show` to print the public key that the build uses.
3. The build puts the public key in the boot program and signs the description of each boot volume.

### Backup

1. Copy `signing_key` and `firmware_signing_key.pem` to two media that stay offline, in two places. The 64 digits of `signing_key` can also be printed on paper.
2. The public key and the certificate are not secret.

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
- **The tries**: when `HashLogExtendEvent` fails, the boot program tries again, 4 tries in all, 0.5 s apart through `Stall` of the firmware: at most 1.5 s more. A slow interface can finish a later try; the log then says "the measure succeeded at try N", and the trust record keeps the count.
- **The rule when every try fails**: no key is sealed to the measure yet, so a stop protects nothing. The boot continues. The trust record says `Refused` with the status of the firmware; the boot display says "TPM refused the measure" in red; the root service writes a warning with the status and the count of tries. A party that reads PCR 11 sees that it does not hold the measure. When a key is sealed to the measure, that key stays sealed: the person sees why on the display.
- **What the log says of a refusal**: after the last try, the boot program reads PCR 11 through `SubmitCommand` of the same protocol and writes the result. When that read fails too, and no command reaches the TPM, the firmware has stopped using its TPM.

### A measure that does not depend on the event path of the firmware

Designed, not built. When `HashLogExtendEvent` fails, the boot program can send `TPM2_PCR_Extend` itself through `SubmitCommand`, with the SHA-256 hash of the description that it computes with `support/cryptography/sha2` (the boot program links it already for Ed25519). The event log of the firmware then has no entry, and the display must say "measured, with no entry in the event log". It is not built because it does not help in the case that the test machines show: in the firmware of EDK II, as far as its source is known here, `SubmitCommand` checks the same flag "TPM present" as `HashLogExtendEvent`, and fails at once when the firmware cleared it. The one path that does not depend on that flag is a driver of the interface of the TPM in the boot program, and the boot program has no TPM driver: it talks to the TPM through the firmware.

### The machines of the TPM

On the test machines with the firmware with Secure Boot (`OVMFFull`, system management mode) and a software TPM, the firmware sometimes refused the measure: `HashLogExtendEvent` gave `EFI_DEVICE_ERROR` (status `8000000000000007`), and no command for PCR 11 reached the TPM. It happened at a host load of 1.9 as at 12 and at 40, with one processor and with four, with the TIS and the CRB interfaces.

What the swtpm log of such a machine shows:

- **One `Startup`**, and one initialization by QEMU: the firmware did not reset the machine. No `PCR_Allocate`: the firmware accepted the four banks of the TPM (SHA-1, SHA-256, SHA-384, SHA-512).
- **One abandoned command**: swtpm wrote its answer to a `GetCapability` (`TPM_CAP_PCRS`), then QEMU sent the control command "cancel" (`00 00 00 09`). A good machine has none. The firmware did not take the answer, and gave the command up when its interface driver reached its time-out.
- **The time**: a good boot reaches the boot program 2 s after the start of QEMU; a bad one about 130 s after. The interface driver of EDK II waits 90 s at most for an answer, counted in its own delay loop, which runs slower than the clock while it exits to QEMU at each read.
- **Before the boot program**: the command is one of the firmware's own measures, in its DXE phase: after its measures into PCR 0 and PCR 7, before the boot manager. After the time-out, `Tcg2Dxe` marks its TPM as absent, so the call of the boot program fails at once with no command.

The cause held: the answer of one command of the firmware does not reach the firmware, and the firmware then stops using its TPM for the boot. The swtpm log proves the order (answer, then cancel), the count (one) and the absence of a reset; it cannot show where the answer is lost between swtpm, QEMU and the firmware. Not known: the part of QEMU or of the firmware with system management mode that loses it.

What the test machines do:

- **The machines of the measure use a firmware without system management mode**: `pkgs.OVMF.override { tpmSupport = true; }` (`OVMF_TPM_CODE`): the TPM driver, no Secure Boot, so no system management mode, and the CRB interface. Nixpkgs builds no such variant: the flake builds it from the source of EDK II, once.
- **The machines of Secure Boot have no TPM device**: they test what the firmware starts, not the measure.
- **What each machine of the TPM prints**: the count of `Startup` commands, the count of abandoned commands, and the name of the command before the first cancel. QEMU writes a trace of the device with the time of each line (`<machine>_qemu_tpm_trace.log`: each command that the device received, each write of the firmware to the device, a start or a cancel).

What the runs with that firmware showed: 10 runs of 11 passed, each machine of the TPM with "1 Startup, 0 commands abandoned" and its boot program started within seconds. In one run a machine of the firmware without system management mode abandoned two commands and did not reach the boot program in 10 minutes. So system management mode is not the cause. The trace of QEMU of that machine: the firmware starts a command, QEMU gives it to swtpm one millisecond later, swtpm writes its answer, and the firmware cancels 4 minutes 38 seconds later; QEMU does not give the next command to swtpm at all. In another machine that hung, the threads of QEMU were read while it hung: its main thread slept in `poll`, one processor of the machine ran at full time (the firmware in its wait loop), the three others were idle, and swtpm slept in `poll` with its answer written. So the answer is lost inside QEMU, between the thread that reads the answer of swtpm and the device that the firmware reads. Not known: why.

So the two machines of the measure are not part of `kerneltool test` and of the full check: `kerneltool test trusted_boot tpm` runs them. A test that fails for a fault of its machine proves nothing about the system. The eight other machines (the five refusals of layer 1 and the three machines of Secure Boot) run in each full check. Before a key is sealed to the measure, the cause must be found or the measure must be tested on a machine with a hardware TPM.

The steps of a machine of the TPM or of Secure Boot after `boot program: started` have a bound of 300 s each, and the wait for `boot program: PCR 11 = ` ends at once with the line of a refusal.

## 7. Secure Boot

1. **A second key.** UEFI Secure Boot verifies Authenticode signatures with RSA keys and X.509 certificates. It cannot verify Ed25519. So the publisher of the system has a firmware signing key: an RSA-2048 key and a self-signed certificate, that `kerneltool key new` makes with `openssl req -new -x509 -newkey rsa:2048 -sha256 -days 36500 -nodes`, in the folder of the signing key. The firmware does not check the dates of a certificate of `db`.
2. **The test pair** is `resources/keys/test_firmware_signing_key.pem` and `.crt`, beside the test signing key, and its private key is published in the same way. `kerneltool key test-firmware-new` writes it once.
3. **The signature of the boot program**: `sbsign --key <key> --cert <certificate> --output <signed> <unsigned>`, of the package `sbsigntool`. The build keeps the unsigned boot program as its output and writes the signed copy beside it.
4. **The variable store of the test machine**: `virt-fw-vars` of the package `python3Packages.virt-firmware` writes a copy of `OVMF_FULL_VARS` with the certificate as PK, KEK and the one entry of `db`, and Secure Boot on (`--set-pk`, `--add-kek`, `--add-db`, `--secure-boot`). No certificate of a vendor is enrolled.
5. **The machines** of `kerneltool test trusted_boot`: the signed boot program starts, and its trust record says `Firmware_And_Boot_Program`; these machines have no TPM device; the signed boot program with one byte changed does not start; the unsigned boot program does not start. For the last two, the tool waits for the line `BdsDxe: failed to load Boot` of the firmware, then checks that the log has no line `boot program: started`.

The machines with this firmware run with four processors, as every other machine, with the system management mode of QEMU (`-machine q35,smm=on`). The first wait of such a machine is the line `boot program: started`, by name, with a bound of 600 seconds: this firmware starts slower than the usual one, and slower still on a loaded host. The tool prints the time of the first wait of each machine.

## 8. The costs

- **Time**: the boot program hashes the kernel and the whole boot image, and the root service hashes the boot image again. The log gives both times: `root: the boot program checked the signature and every hash in <n> us` and `root: the boot image agrees with the system description ...: <n> modules and resources checked in <n> us`.
- **Two hash functions**: BLAKE3 is the identity of each file and of the description. The TPM uses SHA-256 because it has no BLAKE3 bank.
- **Two keys with Secure Boot**: an Ed25519 key for the description and an RSA key for the firmware.
- **The start of the firmware with system management mode**: the tool prints the time from the start of QEMU to `boot program: started` for each machine with that firmware.
- **The boot volume of each test**: the build signs one boot image for each boot volume, because the kernel of one test volume differs.

## 9. Code

| Part | File |
|---|---|
| The format, its reader and its checks | `contract/system_description/system_description.odin` |
| The trust record | `contract/boot_info/boot_info.odin` (`Boot_Trust`) |
| The checks and the measure of the boot program | `boot/trust.odin` |
| The check of the root service | `programs/root/trust.odin` |
| The line of the trust and the line of the check on the boot display | `support/bootscreen/bootscreen.odin` (`trust_line`, `check_line`) |
| The places of the card of the boot image | `support/bootscreen/image_card` |
| The signature, the keys, the command `key` | `tools/kerneltool/system_description.odin` |
| The ten machines of `test trusted_boot` | `tools/kerneltool/trusted_boot_scenario.odin` |
| The firmware signing key, `sbsign`, the variable store with Secure Boot | `tools/kerneltool/secure_boot.odin` |
| The Ed25519 code of the boot program | `support/cryptography/ed25519` (`docs/CRYPTOGRAPHY.md`) |
