// kerneltool: all the automation of the project, in one program.
//
//   odin run tools/kerneltool -out:build/kerneltool -- <command>
//
// The project has no scripts. Each build step, each test and each call to a
// third-party program is a command of this tool, so that the way a third-party
// program is run is written in one place.
//
// The development shell of flake.nix supplies what this tool needs:
//   on the path: odin, lld-link, ld.lld, nasm, qemu-system-x86_64, swtpm
//   OVMF_CODE, OVMF_VARS: the UEFI firmware image and its variable store
//   OVMF_TPM_CODE, OVMF_TPM_VARS: the same firmware with a TPM driver and
//     no system management mode, for the machines of the measure
//   OVMF_FULL_CODE, OVMF_FULL_VARS: the firmware with Secure Boot (and system
//     management mode), for the machines of Secure Boot
//   SYSTEM_SIGNING_KEY (not set by the shell): the private key of the
//     principal that signs the system description; with none,
//     the test signing key of resources/keys (system_description.odin)
//   FONT_SOURCE: the BDF file of the font, for the command "font"
//   POINTER_THEME_SOURCE: the folder of the Xcursor theme of the owner (docs/POINTERS.md)
//   VECTOR_FONT_SOURCES: the font files of the vector font candidates, for the command "vector_fonts"
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "contract:remote"
import "support:pci"

EXIT_FAILURE :: 1
EXIT_USAGE :: 2

ROOT_MARK :: "flake.nix"

BUILD_FOLDER :: "build"

// The two source libraries of the project (docs/GLOSSARY.md). An import
// names its library: "contract:ring", "support:system".
//   contract   what two parties agree on: records, numbers, and the code
//              that reads them. It uses no kernel operation. The kernel
//              compiles with this library only.
//   support    what a program compiles in to use the contracts.
// flake.nix gives the same two flags to the compiler when it builds this tool.
CONTRACT_LIBRARY :: "-collection:contract=contract"
SUPPORT_LIBRARY :: "-collection:support=support"
CONTRACT_PACKAGES :: []string{"blake3", "block", "boot_info", "datagram", "date", "errors", "fixed_addresses", "frame", "glyph_cache", "isolated", "module", "operation", "pointer_pictures", "release", "remote", "ring", "settings", "store", "cut_mark", "system_description", "debug_object", "value_kinds", "palette_table", "start_grant"}
BOOT_OBJECT_FOLDER :: BUILD_FOLDER + "/boot"
// The boot program of the main boot volume, and its object: each boot
// volume has its own object folder (boot_volumes.odin).
BOOT_PROGRAM :: BOOT_OBJECT_FOLDER + "/" + MAIN_BOOT_VOLUME_NAME + "/" + BOOT_PROGRAM_FILE_NAME
BOOT_PROGRAM_OBJECT :: BOOT_OBJECT_FOLDER + "/" + MAIN_BOOT_VOLUME_NAME + "/" + BOOT_PROGRAM_OBJECT_FILE_NAME
BOOT_VOLUME :: BUILD_FOLDER + "/boot_volume.img"
BOOT_VOLUME_FAILS :: BUILD_FOLDER + "/boot_volume_fails.img"
BOOT_VOLUME_SHORTAGE :: BUILD_FOLDER + "/boot_volume_shortage.img"
BOOT_VOLUME_MEASURE :: BUILD_FOLDER + "/boot_volume_measure.img" // The boot image of a measure run: `kerneltool measure`.
BOOT_VOLUME_WITHOUT_RETURN_CHECK :: BUILD_FOLDER + "/boot_volume_without_return_check.img" // The kernel kernel_without_return_check: one machine of `test return_fault` only.
TEST_OUTPUT_SHORTAGE :: BUILD_FOLDER + "/test_output_shortage.txt"
BOOT_VOLUME_SELF_TEST :: BUILD_FOLDER + "/boot_volume_self_test_%d.img"
// The volumes of `test trusted_boot` (trusted_boot_scenario.odin): one byte
// of a module changed after the system description was made; one bit of the
// description signature changed; one byte of a module changed before it was
// made (another system, signed, measured).
BOOT_VOLUME_CHANGED_MODULE :: BUILD_FOLDER + "/boot_volume_changed_module.img"
BOOT_VOLUME_WRONG_SIGNATURE :: BUILD_FOLDER + "/boot_volume_wrong_signature.img"
BOOT_VOLUME_OTHER_SYSTEM :: BUILD_FOLDER + "/boot_volume_other_system.img"
// More volumes that the boot program must refuse: one byte of the kernel
// changed; no system description; an entry that states another hash.
BOOT_VOLUME_CHANGED_KERNEL :: BUILD_FOLDER + "/boot_volume_changed_kernel.img"
BOOT_VOLUME_WITHOUT_DESCRIPTION :: BUILD_FOLDER + "/boot_volume_without_description.img"
BOOT_VOLUME_STATED_HASH :: BUILD_FOLDER + "/boot_volume_stated_hash.img"
// The boot program signed for Secure Boot, and the same with one byte
// changed after the signature (secure_boot.odin).
BOOT_VOLUME_SECURE_BOOT :: BUILD_FOLDER + "/boot_volume_secure_boot.img"
BOOT_VOLUME_SECURE_BOOT_CHANGED :: BUILD_FOLDER + "/boot_volume_secure_boot_changed.img"
// The path where the firmware looks for the boot program of a disk.
BOOT_PROGRAM_PATH :: "EFI/BOOT/BOOTX64.EFI"
FIRMWARE_VARIABLES :: BUILD_FOLDER + "/ovmf_vars.fd"
FIRMWARE_FULL_VARIABLES :: BUILD_FOLDER + "/ovmf_full_vars.fd"
FIRMWARE_TPM_VARIABLES :: BUILD_FOLDER + "/ovmf_tpm_vars.fd"
TEST_OUTPUT :: BUILD_FOLDER + "/test_output.txt"
TEST_OUTPUT_FAILS :: BUILD_FOLDER + "/test_output_fails.txt"
TEST_OUTPUT_SELF_TEST :: BUILD_FOLDER + "/test_output_self_test_%d.txt"
// The disks beside the boot volume (support/pci has their places on the
// bus). The data disk keeps the stores of the storage service: `run` uses
// one that stays from run to run, each test makes a new one. The disk of the
// measures holds no data that a program keeps.
DATA_DISK :: BUILD_FOLDER + "/data_disk.img"
TEST_DATA_DISK :: BUILD_FOLDER + "/test_data_disk.img"
SCRATCH_DISK :: BUILD_FOLDER + "/scratch_disk.img"
// The data disk of the three machines of the test of persistence: new
// before the first one, kept for the two others.
TEST_PERSIST_DISK :: BUILD_FOLDER + "/test_persist_disk.img"
TEST_OUTPUT_PERSIST :: BUILD_FOLDER + "/test_output_persist_%d.txt"
DATA_DISK_SIZE :: 64 << 20
SCRATCH_DISK_SIZE :: 32 << 20

DOCUMENT_SCREENSHOT_FOLDER :: "docs/screenshots"
// The pictures and other files of the repository that a build reads.
RESOURCE_FOLDER :: "resources"
// The development log: one folder of pictures per run of `screenshots`. It
// is beside the repository, not in it: no run replaces the pictures of
// another run.
DEVELOPMENT_LOG_FOLDER :: "../kernel-devlog"

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

// The commands of the tool. The name is the first argument; the help after
// it is what `kerneltool help` prints, one line for each command. The comment
// above each command is its documentation on the site.
//
// `kerneltool` is the one program of the automation of the project: the
// build, the machine tests, the pictures, the measures, the changelog, the
// news and the site. The project has no script: each step of the work, by
// hand or in a workflow, is a command here, so each call of a third-party
// program (the compiler, the linker, QEMU) is written in one place.
//
// Run a command from the root of the repository, in the development shell
// of the flake, which gives the tool its compilers, QEMU and the firmware:
//
// ```
// nix develop -c kerneltool <command> <arguments>
// ```
//
// The tool writes into `build/`, which is not committed, and into the
// files of the repository that a command names (the pictures, the measure
// record, the changelog). A command ends with the status 0 when it
// succeeds, 1 when a step fails, and 2 when its arguments are wrong.
COMMANDS :: [?]Command {
	// Builds the whole system: each module, the boot image, and the boot
	// program that holds the kernel and the boot image.
	//
	// - `whole` (optional): a whole build: the tool ignores every build
	//   record and builds each module and each boot volume.
	// - `processes` (optional): the count of module builds at once; the count
	//   of the processors when it is absent.
	//
	// The build is incremental: a module whose inputs are the same as at
	// its last build is kept, and so is each boot volume. The command
	// prints the count of the modules and of the boot volumes that it kept,
	// and the measure of its time (docs/TOOLS.md, "The incremental build").
	//
	// Each module is built in its own process (the command `module`). The
	// command then builds the main boot volume, and the volumes that the tests
	// need: a start that must fail, a shortage of frames, the volumes that the
	// trusted boot must refuse (a changed module, a wrong signature, no
	// system description), the volumes of Secure Boot, and one volume for each
	// test of the kernel on itself. The volumes that must be built are built
	// at the same time, each in its own process (the command `volume`).
	// `run`, `test` and `measure` build first, with only the boot volumes
	// that they boot: run `build` alone to check that the whole system
	// compiles.
	//
	// ```
	// nix develop -c kerneltool build 8
	// ```
	{name = "build", about = "the modules, the boot image and the boot program, as " + BOOT_PROGRAM + "; one process for each module, as many at once as the processors, or `build <processes>`; a module or a boot volume whose inputs are the same is kept; `build whole`: ignore the build records and build all", run = run_build},
	// Builds one module of the table of modules in this process, with the
	// options of one build.
	//
	// - `name`: a module of the table (`module_builds`).
	// - `with_checks` or `without_checks`: the checks of the kernel (the order
	//   of the locks, the frames).
	// - `with_debug_information` or `without_debug_information`: the debug
	//   object beside the module.
	// - `compile` or `convert`: one step alone. `compile` writes the linked
	//   file; `convert` writes the module and its debug object from it.
	//
	// The parallel build of `build` runs this command once for each step of a module.
	// Run it by hand to see the errors of one module alone.
	{name = "module", about = "module <name> with_checks|without_checks with_debug_information|without_debug_information [compile|convert]: build one module of the table, and its debug object with the debug information, or run one of its two steps alone (the parallel build runs this command for each step)", run = run_module},
	// Builds one boot volume in this process: its boot image with the system
	// description, its boot program, and the volume file.
	//
	// - `name`: `main`, or the end of the name of the volume file:
	//   `shortage` for `build/boot_volume_shortage.img`.
	//
	// The build runs this command once for each boot volume that it must
	// build, several at once. Run it by hand, after a build, to see the
	// errors of one volume alone.
	{name = "volume", about = "volume <name>: build one boot volume, after a build wrote the modules and the boot images (the build runs this command for each volume that it must build)", run = run_volume},
	// Runs the machine tests: it builds, starts each test machine under QEMU,
	// plays its scenario, and checks its log.
	//
	// A scenario is a list of steps: press keys, move the pointer, wait for a
	// line of the log, save a picture of the screen. A step that waits ends at
	// the hang bound, never at a fixed delay: the test checks an order of
	// events, not a speed. Each machine writes its log in a file
	// `build/test_output*.txt` and its pictures in `build/screenshots`. The
	// whole run starts with a new data disk, then runs every machine in
	// order (a start that fails, the trusted boot, the shortage of frames,
	// the self tests of the kernel, the main machine, the network, TCP, QUIC,
	// the randomness, the extended state, the return to a program, the fault
	// ring, the kernel events, the cryptography, the persistence, the
	// principals, the hierarchy, the ranges, the loss of power), then the
	// tests of the loader on the host. It ends with "kerneltool: all tests
	// passed".
	//
	// The build of the whole run builds every boot volume. The build of one
	// part builds only the boot volumes that the part boots
	// (docs/TOOLS.md, "The incremental build").
	//
	// - `part` (optional): one part only, for the work on it: `main`,
	//   `network`, `power`, `principals`, `tcp`, `quic`, `quic-real`, `random`,
	//   `extended_state`, `return_fault`, `trusted_boot`, also `hierarchy`,
	//   `ranges`, `crypto`, `shortage`, `fault_ring`, `debugger`,
	//   `kernel_events`.
	//   `trusted_boot tpm` adds the two machines with a software TPM.
	//
	// ```
	// nix develop -c kerneltool test network
	// ```
	{name = "test", about = "build, start the machine under QEMU, press its keys and move its pointer, check the log, save pictures of the screen; `test network`, `test main`, `test power`, `test principals`, `test tcp`, `test quic`, `test quic-real`, `test random`, `test extended_state`, `test return_fault`, `test trusted_boot`: one part only; `test trusted_boot tpm`: with the two machines that have a software TPM", run = run_test},
	// Builds, then starts the machine under QEMU in a window, with the log of
	// the kernel on this terminal: the way to use the system by hand.
	//
	// - `without_checks` (optional): the build of the measures, with no check
	//   in the kernel.
	//
	// The data disk `build/data_disk.img` stays from run to run, so the
	// stores of the storage service keep their objects. The command also
	// starts the peer of the host that takes the calls of `kerneltool call`,
	// on a socket that only this user reaches. Close the window, or run
	// `shutdown()` in the console, to end it.
	{name = "run", about = "build, then start the machine under QEMU, with the log of the kernel on this terminal; `run without_checks`: the measure build", run = run_machine},
	// Runs the full machine test and the second build, then publishes their
	// results into the repository.
	//
	// It writes the measure record (`docs/measures/measures.txt`): the numbers
	// of the logs of this run, with the commit, the host and the count of
	// checks. It copies each picture of the test to `docs/screenshots` and to
	// a new dated folder of the development log beside the repository. It is,
	// with `nix flake check`, the full check before a release.
	//
	// - `compress`: no machine; it compresses each PNG file of
	//   `docs/screenshots` and `resources` whose data is stored with no
	//   compression, and prints the bytes before and after.
	{name = "screenshots", about = "test, the second build and the measure runs, then write the measure record " + MEASURE_RECORD_FILE + " and copy the pictures to " + DOCUMENT_SCREENSHOT_FOLDER + " and to a new folder of " + DEVELOPMENT_LOG_FOLDER + "; `screenshots compress`: compress the PNG files of " + DOCUMENT_SCREENSHOT_FOLDER + " and " + RESOURCE_FOLDER + " whose data is stored, with no machine", run = run_screenshots},
	// Runs a machine that measures, with no other load: the numbers that it
	// prints are measures, never conditions of the test.
	//
	// Each machine is a measure run: its boot image holds the resource
	// `measure_run`, and a program then measures its rates over a duration.
	// The modules are those of the test.
	//
	// - no argument: the program `locks` on a machine where only the desktop
	//   runs: the kernel entries in one second with 1, 2 and 4 lockers, in
	//   `build/test_output_measure.txt`.
	// - `scheduler N`: N machines that run the program `scheduler` alone, in
	//   `build/test_output_scheduler_<n>.txt`.
	// - `clock`, `crowd`, `disk`, `flow`, `limits`: the program alone, in
	//   `build/test_output_measure_<program>.txt`; the command prints its
	//   lines.
	// - `windows`: each window of the interface package, alone, and a table of
	//   the time of its pictures.
	// - `address_space`, `shortage`: the machine of one measure.
	// - `without_checks ...`: the same, on the build with no check in the
	//   kernel.
	//
	// The tool checks no speed: a program checks its counts, and the numbers
	// are printed for a reader (docs/TOOLS.md, "The bounds of the tests").
	{name = "measure", about = "build, start the machine, run the measures of the locks of the kernel with no other program, and stop: the numbers are in " + TEST_OUTPUT_MEASURE + "; `measure scheduler N`: the program scheduler N times; `measure clock|crowd|disk|flow|limits`: the program alone, and its lines; `measure windows`: each window that the interface package draws, alone, and a table of the time of its pictures; `measure without_checks ...`: the measure build, with no check in the kernel (no lock order check, no check of the frames)", run = run_measure},
	// Builds, starts a machine that runs the scenario of a film, and films
	// it: the pictures of the screen, taken while the scenario types, become
	// a film with ffmpeg, which must be on the path. The film is for the
	// development log and for a news entry that names it, not a test.
	//
	// - no argument, or `terminal`: the film of the terminal.
	// - `palette`: the film of the palette.
	{name = "film", about = "build, start the machine, film a scenario (" + FILM_NAMES + "; no argument: terminal), and write " + FILM_FOLDER + "/<name>.mp4, " + FILM_FOLDER + "/<name>.webm, a copy of the MP4 file in a new folder of " + DEVELOPMENT_LOG_FOLDER + ", and " + FILM_DOCUMENT_FOLDER + "/<name>.webm when a news entry names the film (needs ffmpeg)", run = run_film},
	// Converts the BDF file of the font of the terminal (Spleen 8x16, from
	// `FONT_SOURCE`) to Odin data in `support/graphics/font.odin`. The result
	// is in the repository, so a build does not need the BDF file: run it only
	// to change the font.
	{name = "font", about = "convert the BDF file of the font to " + FONT_OUTPUT, run = run_font},
	// Converts the pointer manifests of `resources/pointers` to the pointer
	// theme files of the boot image, in `build/pointers`.
	//
	// - `folder` (optional): the Xcursor theme to read; else the folder of
	//   `POINTER_THEME_SOURCE`.
	//
	// It prints a table of each theme: each pointer, its size and its hot
	// spot (docs/POINTERS.md).
	{name = "pointers", about = "convert the pointer manifests of resources/pointers to pointer theme files in " + POINTER_BUILD_FOLDER + ", with the Xcursor folder of " + POINTER_THEME_SOURCE_VARIABLE + " or of the path after the command; print a table of each theme", run = run_pointers},
	// Takes the subset of each vector font candidate of `VECTOR_FONT_SOURCES`
	// that the system draws, writes it to `resources/fonts`, and draws one
	// picture that compares the candidates. Run it to change a font; a build
	// reads the files of the repository (docs/FONTS.md).
	{name = "vector_fonts", about = "subset the vector font candidates of " + VECTOR_FONT_SOURCES_VARIABLE + " to " + VECTOR_FONT_FOLDER + " and draw " + CANDIDATES_PICTURE, run = run_vector_fonts},
	// Draws the files of the mark of the system from its geometry in
	// `support/mark`: the icons in `resources/logo`, the font of the name of
	// the mark, the picture of the project, and one picture of every frame
	// of the animations of the mark.
	//
	// - `check`: draws them again and compares them with the files of the
	//   repository; `kerneltool check` runs it, so a mark that changed in
	//   the code and not in the files fails.
	{name = "logo", about = "draw the files of the mark of the system from support/mark: " + LOGO_FOLDER + " and " + PROJECT_IMAGE + "; `check` verifies them; and " + MARK_ANIMATIONS_PICTURE + ", every frame of the animations of the mark", run = run_logo},
	// Draws one picture of the mark: the one entry to the generator of the
	// pictures of the mark, which `logo` and `site` also ask.
	//
	// - `still`: the still mark, a PNG file.
	// - `frame`: one frame of an animation (`--animation`, `--frame`).
	// - `tile_map`: the tile map of every animation, or of one (`--animation`):
	//   a tile for each distinct frame and, with `--forms yes`, a tile for
	//   each drawn form of the moves.
	// - `table`: the table of that tile map, as JSON: the place and the
	//   size of each tile, the times, the moves in cells.
	// - `uses`: prints the table of the uses: each file of the mark of the
	//   repository and of the site, with its variant.
	// - `developer`: the picture of every frame and form, with its texts.
	//
	// The options say how: `--variant smooth|cells`, `--cell <pixels>`,
	// `--scheme dark|light`, `--background none|scheme`, `--size <pixels>` or
	// `--size <width>x<height>`, `--name-cell <pixels>`, `--gap <pixels>`, `--width <pixels>` (the
	// widest tile map), `--out <file>`. A request with no sense is refused
	// with a sentence: the smooth variant at one pixel for a cell, a part
	// of a pixel, a picture smaller than its drawing (docs/TOOLS.md, "The
	// pictures of the mark").
	{name = "mark", about = "draw one picture of the mark: still | frame | tile_map | table | uses | developer, with --variant smooth|cells, --cell <pixels>, --scheme dark|light, --background none|scheme, --animation <name>, --frame <number>, --forms yes|no, --width <pixels>, --out <file>", run = run_mark},
	// Converts the JPEG portrait of the program `temple` to the pixels that the
	// program holds, `programs/temple/portrait.pixels`. The result is in the
	// repository, so a build decodes no JPEG.
	{name = "portrait", about = "convert " + PORTRAIT_SOURCE + " to " + PORTRAIT_OUTPUT, run = run_portrait},
	// Calls an export of a service of the machine that `kerneltool run`
	// started, from the host, and prints the typed result.
	//
	// - `key`: the public key of the program `remote`, as its window shows it.
	//   The QUIC client of the tool pins it: a machine with another key is
	//   refused.
	// - `call`: one call in the language of the console, in quotes.
	//
	// The call goes to the peer of `run` through a socket that only this user
	// reaches, then over QUIC to `remote`, which calls the service for the
	// principal. A table prints as rows, with its count.
	//
	// ```
	// nix develop -c kerneltool call <key> "monitor.counts_named([(\"programs\"), (\"processors\")])"
	// ```
	{name = "call", about = "call <key> \"service.export(arguments)\": call an export of a service of the machine that `run` started, through the program remote over QUIC (key: the public key of remote, from its window), and print the typed result; the peer of `run` takes the call on a socket that only this user reaches", run = run_call},
	// Builds one module again and again, with no machine, and counts the
	// distinct results: one distinct module, LLVM IR file and object each is a
	// build that gives the same bytes every time.
	//
	// - `module`, `count`: the module and the count of builds.
	// - `all count [processes]`: every module and the boot program, one row
	//   each.
	{name = "repeat", about = "repeat <module> <count>: build one module again and again, with no machine, and count the distinct modules, LLVM IR files and objects; `repeat all <count> [processes]`: every module and the boot program, one row each", run = run_repeat},
	// Copies a file of `core:crypto` of the Odin compiler into the repository
	// with the listed changes of its imports, and prints its line of the
	// manifest of the origin.
	//
	// - `origin`: the file, under the root of Odin.
	// - `file`: its path in the repository.
	{name = "cryptography-take", about = "cryptography-take <file under the root of Odin> <file of the repository>: copy a file of core:crypto with the listed import changes, and print its line of the manifest", run = run_cryptography_take},
	// Prints the line of the list of the system files for each `.odin` file of
	// `support/cryptography` that the manifest of the origin does not name:
	// the files that the project wrote, which a reviewer checks before the
	// lines go into the list.
	{name = "cryptography-system-hashes", about = "print the line of " + CRYPTOGRAPHY_SYSTEM_FILES + " for each .odin file of support/cryptography that is not taken from Odin", run = run_cryptography_system_hashes},
	// Checks that each file that the manifest of the origin names is its file
	// in Odin with the listed changes only. `kerneltool check` runs it.
	{name = "cryptography-origin", about = "check that each file of " + CRYPTOGRAPHY_MANIFEST + " is its origin in Odin with the listed changes only", run = run_cryptography_origin},
	// Works on the changelog: the fragments of `changelog.d/`, and the releases
	// of `CHANGELOG.md`.
	//
	// - `new <type> <subject> "<text>"`: writes one fragment; the type is
	//   Added, Changed, Deprecated, Removed, Fixed or Security. With `-` as the
	//   text, the text comes from the standard input.
	// - `check`: checks the form of each fragment and of the changelog.
	// - `assemble`: prints the next release from the fragments, with no
	//   change.
	// - `release <release number>`: moves the fragments into a new release of
	//   the changelog, with its date, and deletes them.
	// - `notes <release number>`: prints the changes of one release.
	//
	// No one edits `CHANGELOG.md` by hand: this command writes it.
	{name = "changelog", about = "new <type> <subject> \"<text>\" (or - and the text on the standard input) | check | assemble | release <release number> | notes <release number>: the fragments of `" + FRAGMENT_FOLDER + "` and the releases of `" + CHANGELOG_FILE + "`", run = run_changelog},
	// Works on the news entries of `news/`, the dated reports of what a
	// reader can now see or use.
	//
	// - `new <subject>`: writes an entry with the date of today and no title
	//   and no text: the check fails until they are written.
	// - `check`: checks the head, the date, the picture, the release, the
	//   guide and the length of each entry. `kerneltool check` runs it.
	{name = "news", about = "new <subject> | check: the news entries of " + NEWS_FOLDER + ", dated reports in prose of what a reader can now see or use, for the page of the news of the site", run = run_news},
	// Writes the site in `build/site/`: the home, the guides, the reference
	// tables read from the code, the status, the news, the releases, the
	// index of the search and its script.
	//
	// - `--address https://<host>/<path>` (optional): the address of the
	//   published site, for the canonical addresses, the sitemap and the
	//   feeds.
	//
	// Before it writes a page, it checks every page: one title, each link to
	// a page or a file that it writes, each picture with its text. A failure
	// stops the command with the page and the reason, and writes nothing. The
	// design: (docs/SITE.md, "The command").
	{name = "site", about = "write the site of the system in " + SITE_FOLDER + ": the pages from the documents, the code, the news, the pictures and the logs of the last machine tests, an index and one small script for the search, and the feed of the news; no request to another server", run = run_site},
	// Prints the number of the newest release of `CHANGELOG.md`, as `0.91.0`:
	// the number that a workflow gives to a release.
	{name = "release_number", about = "print the release number of the system: the newest release of `" + CHANGELOG_FILE + "`", run = run_release_number},
	// Runs every check of the work tree, and writes no file of the
	// repository. The full check of a batch is `screenshots` with
	// `nix flake check`.
	//
	// In order: `odin check -vet` of the tool, each package of the contract
	// alone, the host tests of each library, the origin of the cryptography,
	// the mark, the pictures of the README, the fixed addresses, the bounds
	// of the tests, the rule on comments, the form of the glossary, the
	// changelog and the news. Then the whole machine test (`test`) and a
	// second build that must give the same bytes.
	{name = "check", about = "odin check -vet and odin test of the host code, the checks of the sources (among them the rule on comments and the form of the glossary), changelog check, news check, then test", run = run_check},
	// Makes or shows the key that signs the system description.
	//
	// - `new <folder>`: writes a new private key, readable by its owner only,
	//   and its public key, in a folder outside the repository, with the
	//   firmware signing key of Secure Boot beside them.
	// - `show`: prints the public key that the build uses: the key of
	//   `SYSTEM_SIGNING_KEY`, or the test signing key of the repository.
	//
	// A system signed with the test key is for a test machine only: its
	// private key is published.
	{name = "key", about = "key new <folder outside the repository>: write a new signing key of the system description (the private key, readable by its owner only, and the public key); `key show`: print the public key that the build uses (" + SIGNING_KEY_VARIABLE + ", or the test signing key)", run = run_key},
}

main :: proc() {
	// The development shell of Nix gives the linker a search path with the
	// folder of the build in it (NIX_LDFLAGS). The linker would write it in
	// each module, and the hash of a module would depend on that folder.
	_ = os.unset_env("NIX_LDFLAGS")
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" {
		usage()
		return
	}
	if !os.exists(ROOT_MARK) {
		fmt.eprintln("kerneltool: start it from the root of the repository")
		os.exit(EXIT_USAGE)
	}
	commands := COMMANDS
	for c in commands {
		if c.name == os.args[1] {
			os.exit(c.run(os.args[2:]))
		}
	}
	fmt.eprintfln("kerneltool: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("kerneltool <command>")
	commands := COMMANDS
	for c in commands {
		fmt.printfln("  %-14s %s", c.name, c.about)
	}
}

// run_build is the command `build`: the modules, the boot images, and
// every boot volume. A module whose inputs are the same is kept, and so is
// each boot volume (incremental_build.odin, boot_volumes.odin); `build
// whole` keeps nothing.
run_build :: proc(args: []string) -> int {
	// `build [whole] [processes]`: a whole build, and the count of module
	// processes at once.
	rest := args
	if len(rest) >= 1 && rest[0] == "whole" {
		build_whole = true
		rest = rest[1:]
	}
	if len(rest) > 1 || (len(rest) == 1 && !parse_module_build_processes(rest[0])) {
		fmt.eprintln("kerneltool: build [whole] [processes]")
		return EXIT_USAGE
	}
	return build_system(nil)
}

// build_system builds the modules, the boot images, and then the boot
// volumes that the caller boots: needed_volumes names them by their paths,
// and nil is every volume. A volume that the caller does not name is not
// built and not checked: no machine of this process starts from it
// (machine_command).
build_system :: proc(needed_volumes: []string) -> int {
	build_measure_start()
	if !build_modules() {
		return EXIT_FAILURE
	}
	volumes_started := time.tick_now()
	if !boot_volumes_build(needed_volumes) {
		return EXIT_FAILURE
	}
	build_measure_step("the boot volumes, in all", volumes_started)
	build_measure_print()
	return 0
}

run_machine :: proc(args: []string) -> int {
	if len(args) >= 1 && args[0] == "without_checks" {
		test_build_checks = false
	}
	if code := build_system(boot_volumes_of_command("run")); code != 0 {
		return code
	}
	if !disk_prepare(DATA_DISK, DATA_DISK_SIZE, false) {
		return EXIT_FAILURE
	}
	// The peer receives the calls of `kerneltool call` on a Unix socket of
	// the private folder of the user: `kerneltool call` finds it by its name.
	peer: Peer
	if !peer_start(&peer, CALL_SOCKET_RUN_NAME) {
		return EXIT_FAILURE
	}
	// The developer names the key of each start of remote in `kerneltool
	// call`: this peer takes it.
	peer.remote.keys_from_calls = true
	fmt.printfln("kerneltool: the peer takes the calls of `kerneltool call` at %s (only this user reaches it)", peer.call_socket)
	defer peer_stop(&peer)
	command, ok := machine_command(BOOT_VOLUME, "", DATA_DISK, &peer)
	if !ok {
		return EXIT_FAILURE
	}
	if !run(command) {
		return EXIT_FAILURE
	}
	return 0
}

// The parts of the machine test that `test <part>` runs alone.
test_parts := [?]string{"main", "network", "power", "hierarchy", "ranges", "tcp", "quic", "quic-real", "crypto", "random", "shortage", "extended_state", "return_fault", "fault_ring", "debugger", "kernel_events", "principals", "trusted_boot"}

// test_arguments_problem gives the refusal of the arguments of `test`, or
// "" when they name the whole test, one part, or `trusted_boot tpm`. A word
// that is not a part is refused: the whole test in its place takes minutes
// and passes, and the reader believes that the part passed.
test_arguments_problem :: proc(args: []string) -> string {
	if len(args) == 0 {
		return ""
	}
	if len(args) == 2 && args[0] == "trusted_boot" && args[1] == "tpm" {
		return ""
	}
	if len(args) == 1 {
		for part in test_parts {
			if args[0] == part {
				return ""
			}
		}
	}
	given := strings.join(args, " ", context.temp_allocator)
	known := strings.join(test_parts[:], ", ", context.temp_allocator)
	return fmt.tprintf("test does not know the part `%s`; the parts: %s, and `trusted_boot tpm`; with no argument, the whole test", given, known)
}

// The machines of the parts `main`, `network` and `shortage`: one procedure
// for each part, so that the table of the boot volumes of the parts names
// it (boot_volumes.odin).
main_tests_run :: proc() -> bool {
	return machine_test(scenario[:], BOOT_VOLUME, TEST_OUTPUT, MACHINE_STOP_OK, TEST_DATA_DISK)
}

network_tests_run :: proc() -> bool {
	return machine_test(scenario_network[:], BOOT_VOLUME, TEST_OUTPUT_NETWORK, MACHINE_STOP_OK, TEST_DATA_DISK)
}

shortage_tests_run :: proc() -> bool {
	return machine_test(scenario_shortage[:], BOOT_VOLUME_SHORTAGE, TEST_OUTPUT_SHORTAGE, MACHINE_STOP_OK, TEST_DATA_DISK)
}

// run_test runs the machine test (machine.odin), then the host load test.
run_test :: proc(args: []string) -> int {
	if problem := test_arguments_problem(args); problem != "" {
		fmt.eprintfln("kerneltool: %s", problem)
		return EXIT_USAGE
	}
	// The times of the test are measures: the report never changes the result.
	test_started := time.tick_now()
	defer test_times_report(test_started)
	// One part boots only its own boot volumes: the build builds those.
	build_code := build_system(boot_volumes_of_test(args))
	test_times_build_end(test_started)
	if build_code != 0 {
		return build_code
	}
	if !reset_folder(SCREENSHOT_FOLDER) {
		return EXIT_FAILURE
	}
	// A start that fails ends when the tool ends QEMU: status 0.
	if !disk_prepare(TEST_DATA_DISK, DATA_DISK_SIZE, true) {
		return EXIT_FAILURE
	}
	// `test network`, `test main`, `test power`, `test hierarchy`, `test ranges`, `test tcp`, `test random`, `test extended_state`, `test return_fault`, `test fault_ring`, `test kernel_events`, `test trusted_boot`: one part only, for the work on it.
	if len(args) == 1 && args[0] == "trusted_boot" {
		return trusted_boot_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test trusted_boot tpm`: with the two machines of the measure.
	if len(args) == 2 && args[0] == "trusted_boot" && args[1] == "tpm" {
		return trusted_boot_tests_run(with_tpm = true) ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "hierarchy" {
		return hierarchy_tests_run() ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "ranges" {
		return ranges_tests_run() ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "power" {
		return power_loss_run() && power_loss_settings_run() && power_loss_ranges_run() ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "main" {
		return main_tests_run() ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "network" {
		return network_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test crypto`: the machine of the module cryptography only.
	if len(args) == 1 && args[0] == "crypto" {
		return cryptography_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test random`: the three machines of the randomness only.
	if len(args) == 1 && args[0] == "random" {
		return random_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test shortage`: the machine of the shortage of frames only.
	if len(args) == 1 && args[0] == "shortage" {
		return shortage_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test fault_ring`: the machine of the fault ring only.
	if len(args) == 1 && args[0] == "fault_ring" {
		return fault_ring_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test debugger`: the machine of the debugger of a program only.
	if len(args) == 1 && args[0] == "debugger" {
		return debugger_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test principals`: the two machines of the principals only.
	if len(args) == 1 && args[0] == "principals" {
		return principals_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test kernel_events`: the machine of the kernel events only.
	if len(args) == 1 && args[0] == "kernel_events" {
		return kernel_events_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test return_fault`: the machine of the return to a program only.
	if len(args) == 1 && args[0] == "return_fault" {
		return return_fault_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test extended_state`: the three machines of the extended state only.
	if len(args) == 1 && args[0] == "extended_state" {
		return extended_state_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test tcp`: the two machines of TCP only.
	if len(args) == 1 && args[0] == "tcp" {
		return tcp_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test quic`: the machine of QUIC through the network service only.
	if len(args) == 1 && args[0] == "quic" {
		return quic_tests_run() ? 0 : EXIT_FAILURE
	}
	// `test quic-real`: the QUIC client of OpenSSL against quic_echo, through
	// the UDP relay of the peer.
	if len(args) == 1 && args[0] == "quic-real" {
		return quic_real_tests_run() ? 0 : EXIT_FAILURE
	}
	if !machine_test(scenario_fails[:], BOOT_VOLUME_FAILS, TEST_OUTPUT_FAILS, 0) || !trusted_boot_tests_run() || !machine_test(scenario_shortage[:], BOOT_VOLUME_SHORTAGE, TEST_OUTPUT_SHORTAGE, MACHINE_STOP_OK, TEST_DATA_DISK) || !self_tests_run() || !machine_test(scenario[:], BOOT_VOLUME, TEST_OUTPUT, MACHINE_STOP_OK, TEST_DATA_DISK) || !machine_test(scenario_network[:], BOOT_VOLUME, TEST_OUTPUT_NETWORK, MACHINE_STOP_OK, TEST_DATA_DISK) || !tcp_tests_run() || !quic_tests_run() || !quic_real_tests_run() || !random_tests_run() || !extended_state_tests_run() || !return_fault_tests_run() || !fault_ring_tests_run() || !debugger_tests_run() || !kernel_events_tests_run() || !cryptography_tests_run() || !persistence_run() || !principals_tests_run() || !hierarchy_tests_run() || !ranges_tests_run() || !power_loss_run() || !power_loss_settings_run() || !power_loss_ranges_run() || !test_modules() || !test_descriptions() || !test_debug_objects() {
		return EXIT_FAILURE
	}
	fmt.println("kerneltool: all tests passed")
	return 0
}

// The count of the checks that passed in this process: the measure record
// states it. Each check that passes prints its line through
// test_passed_print. A peer thread can print one, so the count is atomic.
test_passed_count: int

test_passed_print :: proc(format: string, args: ..any) {
	sync.atomic_add(&test_passed_count, 1)
	fmt.printfln("kerneltool: test passed: %s", fmt.tprintf(format, ..args))
}

// run_screenshots runs the machine test, copies the pictures of the test
// to the documents and to a new folder of the development log, then runs
// the second build and writes the measure record (measure_record.odin).
// `screenshots compress` runs no machine: it compresses each PNG file of
// the documents and of the resources whose data is stored (picture_files.odin).
run_screenshots :: proc(args: []string) -> int {
	if len(args) == 1 && args[0] == "compress" {
		count, compressed_all := pictures_compress([]string{DOCUMENT_SCREENSHOT_FOLDER, RESOURCE_FOLDER})
		fmt.printfln("kerneltool: %d PNG files, %d compressed: %d bytes before, %d bytes after", count.picture_count, count.compressed_count, count.bytes_before, count.bytes_after)
		return compressed_all ? 0 : EXIT_FAILURE
	}
	if len(args) != 0 {
		fmt.eprintln("kerneltool: screenshots takes no argument, or `compress`")
		return EXIT_USAGE
	}
	// The full check proves the build: it keeps no output of an earlier build.
	build_whole = true
	// The facts of the tree before the pass changes it: the pass writes the
	// pictures and the record into the repository.
	run_facts := measure_run_facts_read()
	if code := run_test(nil); code != 0 {
		return code
	}
	// The pictures are a fact of the machines, which all passed: they go
	// to the documents now. The proofs of the build below say nothing of a
	// picture, and a proof that fails must not leave old pictures in the
	// documents.
	if !screenshots_copy() {
		return EXIT_FAILURE
	}
	// The record states the second build, as `kerneltool check` makes it.
	if !outputs_same_after_second_build() {
		return EXIT_FAILURE
	}
	// The rates of the record come from measure runs: the test measures
	// none (measure_runs.odin).
	if !measure_runs_of_the_record() {
		return EXIT_FAILURE
	}
	if !measure_record_write(run_facts) {
		return EXIT_FAILURE
	}
	return 0
}

// screenshots_copy copies the pictures of the test to the documents and to
// a new folder of the development log.
screenshots_copy :: proc() -> bool {
	pictures, ok := files_with_suffix(SCREENSHOT_FOLDER, ".png")
	// The name of the folder is the time of the run, in UTC.
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	log_folder := fmt.tprintf("%s/%04d-%02d-%02d_%02d%02d%02d", DEVELOPMENT_LOG_FOLDER, year, int(month), day, hour, minute, second)
	if !ok || !make_folder(DOCUMENT_SCREENSHOT_FOLDER) || !make_folder(DEVELOPMENT_LOG_FOLDER) || !make_folder(log_folder) {
		return false
	}
	for picture in pictures {
		for folder in ([]string{DOCUMENT_SCREENSHOT_FOLDER, log_folder}) {
			target := strings.concatenate({folder, picture[strings.last_index(picture, "/"):]}, context.temp_allocator)
			if err := os.copy_file(target, picture); err != nil {
				fmt.eprintfln("kerneltool: cannot write %s: %v", target, err)
				return false
			}
			fmt.printfln("kerneltool: wrote %s", target)
		}
	}
	return true
}

TEST_OUTPUT_MEASURE :: BUILD_FOLDER + "/test_output_measure.txt"

// run_measure runs the measures of the program `locks` on a machine where
// only the desktop runs: the numbers have no load of the other programs of
// the test. The program checks its counts; the tool does not check a speed.
// The machine is a measure run: its boot image holds the resource
// `measure_run`, so each program measures its rates over a duration
// (measure_runs.odin). `measure <program>`: one program of
// `measure_programs`, alone, and its lines.
// `measure scheduler N`: N machines that run only the program scheduler
// with the desktop; the numbers are in build/test_output_scheduler_<n>.txt.
run_measure :: proc(args: []string) -> int {
	args := args
	if len(args) >= 1 && args[0] == "without_checks" {
		test_build_checks = false
		args = args[1:]
	}
	// `measure shortage` boots the volume of the shortage of frames; each
	// other form boots the volume of a measure run.
	shortage := len(args) >= 1 && args[0] == "shortage"
	if code := build_system(boot_volumes_of_command(shortage ? MEASURE_SHORTAGE_COMMAND : MEASURE_COMMAND)); code != 0 {
		return code
	}
	if !make_folder(SCREENSHOT_FOLDER) || !disk_prepare(TEST_DATA_DISK, DATA_DISK_SIZE, true) {
		return EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "windows" {
		return measure_windows() ? 0 : EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "address_space" {
		return machine_test(scenario_measure_address_space[:], BOOT_VOLUME_MEASURE, TEST_OUTPUT_MEASURE, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
	}
	// `measure <program>`: one program that measures itself, alone.
	if len(args) == 1 {
		if program, found := measure_program_find(args[0]); found {
			return measure_program_run(program) ? 0 : EXIT_FAILURE
		}
	}
	if shortage {
		return shortage_tests_run() ? 0 : EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "scheduler" {
		count := 1
		if len(args) == 2 {
			count = 0
			for character in args[1] {
				if character < '0' || character > '9' {
					fmt.eprintln("kerneltool: measure scheduler <count>: the count is a number")
					return EXIT_FAILURE
				}
				count = count * 10 + int(character - '0')
			}
		}
		for run in 1 ..= count {
			// Not in the temporary allocator: the scenario frees it after each step.
			output := fmt.aprintf("%s/test_output_scheduler_%d.txt", BUILD_FOLDER, run)
			defer delete(output)
			if !machine_test(scenario_measure_scheduler[:], BOOT_VOLUME_MEASURE, output, MACHINE_STOP_OK, TEST_DATA_DISK) {
				return EXIT_FAILURE
			}
		}
		return 0
	}
	if len(args) != 0 {
		fmt.eprintln("kerneltool: measure [without_checks] [scheduler <count> | windows | address_space | shortage | clock | crowd | disk | flow | limits]")
		return EXIT_USAGE
	}
	if !machine_test(scenario_measure[:], BOOT_VOLUME_MEASURE, TEST_OUTPUT_MEASURE, MACHINE_STOP_OK, TEST_DATA_DISK) {
		return EXIT_FAILURE
	}
	return 0
}

run_check :: proc(args: []string) -> int {
	// The full check proves the build: it keeps no output of an earlier build.
	build_whole = true
	if !run({"odin", "check", "tools/kerneltool", "-vet", CONTRACT_LIBRARY, SUPPORT_LIBRARY}) {
		return EXIT_FAILURE
	}
	// A package of the contract library compiles with that library only:
	// the compiler refuses an import of "support:".
	for name in CONTRACT_PACKAGES {
		if !run({"odin", "check", strings.concatenate({"contract/", name}, context.temp_allocator), "-no-entry-point", "-vet", CONTRACT_LIBRARY}) {
			return EXIT_FAILURE
		}
		test_passed_print("contract:%s compiles with the contract library only", name)
	}
	// The tests of runtime/memory.asm link the form of the host: the
	// compiler assembles runtime/memory_for_host_tests.asm itself and links
	// its object by its path (a library found through `-L/` is refused by
	// the linker of the Nix sandbox).
	for folder in ([]string{"runtime", "contract/blake3", "contract/isolated", "contract/pointer_pictures", "contract/remote", "support/sentence", "support/cryptography/vectors", "modules/cryptography", "support/quic", "contract/date", "support/storage_mount", "support/storage_object", "support/storage_tree", "support/storage_retention", "support/principals", "support/calendar", "support/line_editor", "support/console_language", "support/debugging", "modules/interface_module", "modules/drawing", "modules/sample", "support/system", "support/bar", "support/palette", "contract/palette_table", "support/bootscreen/image_card", "support/graphics", "support/interface", "support/addresses", "support/information", "support/vector_font", "support/network", "support/tcp", "support/virtio", "support/web", "support/cryptography/chacha20", "support/random", "tools/kerneltool", "contract/fixed_addresses", "contract/settings", "modules/text_shaping", "support/text_shaping", "support/mark", "support/terminal", "contract/cut_mark", "runtime/without_vector_registers", "support/instruction_sets", "contract/system_description", "contract/operation", "contract/debug_object", "contract/value_kinds", "support/source_comment_markdown", "support/console_results", "support/key_path", "support/kind_icons"}) {
		name, _ := strings.replace_all(folder, "/", "_", context.temp_allocator)
		if !run({"odin", "test", folder, "-vet", CONTRACT_LIBRARY, SUPPORT_LIBRARY, strings.concatenate({"-out:" + BUILD_FOLDER + "/test_", name}, context.temp_allocator)}) {
			return EXIT_FAILURE
		}
	}
	if !cryptography_origin_check() {
		return EXIT_FAILURE
	}
	if !logo_check() {
		return EXIT_FAILURE
	}
	if !readme_pictures_check() {
		return EXIT_FAILURE
	}
	if !fixed_addresses_check() {
		return EXIT_FAILURE
	}
	if !test_bound_check() {
		return EXIT_FAILURE
	}
	if !text_cut_check() {
		return EXIT_FAILURE
	}
	if !comment_rule_check() {
		return EXIT_FAILURE
	}
	if !glossary_check() {
		return EXIT_FAILURE
	}
	if !changelog_check() {
		return EXIT_FAILURE
	}
	if !news_check() {
		return EXIT_FAILURE
	}
	if run_test(nil) != 0 {
		return EXIT_FAILURE
	}
	return outputs_same_after_second_build() ? 0 : EXIT_FAILURE
}

// The processor of a test machine, as the -cpu of QEMU.
Processor_Model :: enum {
	Maximum, // Each feature that the host processor, or the emulation, has.
	Without_Random, // No rdrand and no rdseed: the fallback of the seed of the root service (`test random`).
	Without_Avx, // No AVX: the kernel saves x87 and SSE with xsaveopt (`test extended_state`).
	Without_Xsave, // No xsave: the kernel saves with fxsave (`test extended_state`).
}

@(rodata)
processor_models := [Processor_Model]string {
	.Maximum        = "max",
	.Without_Random = "max,-rdrand,-rdseed",
	.Without_Avx    = "max,-avx",
	.Without_Xsave  = "max,-xsave",
}

// machine_command gives the one QEMU command line of the project: the first
// fixed machine that the system targets (QEMU on x86-64 with virtio
// devices, UEFI firmware and a TPM). The boot volume is a virtio block device. If
// test_output is a path, the machine has no window and writes its log there.
// The network device sends each frame to the peer (peer.odin) on the
// loopback of the host, at peer_port, as one UDP datagram.
// The network device goes to the peer (`-netdev dgram`), or, when forward
// has a port, to QEMU user networking with its TCP (web_host.odin).
// processor gives the processor of the machine (Processor_Model).
machine_command :: proc(volume: string, test_output: string, data_disk: string, peer: ^Peer, forward: Forward = {}, processor: Processor_Model = .Maximum, firmware: Machine_Firmware = .Usual) -> (command: []string, ok: bool) {
	// A machine starts only from a boot volume that this process built or
	// kept: a volume that the command did not ask for can be the volume of
	// older sources, and a test on it proves nothing. The variable store of
	// Secure Boot is an output of the build of one volume.
	if !boot_volume_is_ready(volume) || (firmware == .With_Secure_Boot && !boot_volume_is_ready(BOOT_VOLUME_SECURE_BOOT)) {
		fmt.eprintfln("kerneltool: the boot volume %s, or the variable store of Secure Boot, was not built or kept by the build of this command: add it to the volumes of the command (boot_volumes.odin)", volume)
		return nil, false
	}
	if !disk_prepare(SCRATCH_DISK, SCRATCH_DISK_SIZE, false) {
		return nil, false
	}
	code_variable, variables_variable, variables_copy := "OVMF_CODE", "OVMF_VARS", FIRMWARE_VARIABLES
	switch firmware {
	case .Usual:
	case .With_Tpm:
		code_variable, variables_variable, variables_copy = "OVMF_TPM_CODE", "OVMF_TPM_VARS", FIRMWARE_TPM_VARIABLES
	case .With_Secure_Boot:
		code_variable, variables_variable, variables_copy = "OVMF_FULL_CODE", "OVMF_FULL_VARS", FIRMWARE_FULL_VARIABLES
	}
	firmware_code := os.get_env(code_variable, context.temp_allocator)
	firmware_variables := os.get_env(variables_variable, context.temp_allocator)
	// The machine with Secure Boot on starts from the variable store in
	// which the build enrolled the certificate of the firmware signing key
	// (secure_boot.odin), not from the empty store of the firmware.
	if firmware == .With_Secure_Boot {
		firmware_variables = SECURE_BOOT_VARIABLES
	}
	if firmware_code == "" || firmware_variables == "" {
		fmt.eprintfln("kerneltool: %s and %s are not set. Use the development shell: nix develop", code_variable, variables_variable)
		return nil, false
	}
	// The firmware writes its variables, so it gets a private copy.
	if err := os.copy_file(variables_copy, firmware_variables); err != nil {
		fmt.eprintfln("kerneltool: cannot copy %s: %v", firmware_variables, err)
		return nil, false
	}
	if !run({"chmod", "u+w", variables_copy}) {
		return nil, false
	}
	listener_port := forward.listener != nil ? forward.listener.port : 0
	network_device := network_device_of(forward.host_port, listener_port, peer.port, peer.machine.port)
	if problem := network_device_problem(network_device); problem != "" {
		fmt.eprintfln("kerneltool: %s", problem)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	append(
		&list,
		"qemu-system-x86_64",
		"-machine",
		// The firmware with Secure Boot needs the system management mode of
		// the processor: its variables are written only there.
		firmware == .With_Secure_Boot ? "q35,smm=on" : "q35",
		"-accel",
		"kvm",
		"-accel",
		"tcg",
		"-cpu",
		processor_models[processor],
		"-m",
		"512",
		"-smp",
		"4",
		"-device",
		"isa-debug-exit,iobase=0xf4,iosize=0x04",
		"-no-reboot",
		"-rtc", "base=utc", // The real-time clock of the machine is the clock of the host, in UTC: the test of the date compares the two.
		"-net",
		"none", // No other network device than the one below.
		"-netdev",
		network_device,
	)
	if forward.host_port != 0 {
		// Each frame of the device, with its time, for the tool after the run
		// (web_host.odin, frames_of_the_fetch_report).
		append(&list, "-object", "filter-dump,id=frames,netdev=network,file=" + FRAMES_OF_USER_NETWORK)
	}
	append(
		&list,
		"-device",
		fmt.tprintf("virtio-net-pci,netdev=network,disable-legacy=on,mac=%s,addr=0x%x", MACHINE_HARDWARE, pci.NETWORK_DEVICE),
		"-drive",
		strings.concatenate({"if=pflash,format=raw,readonly=on,file=", firmware_code}, context.temp_allocator),
		"-drive",
		strings.concatenate({"if=pflash,format=raw,file=", variables_copy}, context.temp_allocator),
		"-drive",
		strings.concatenate({"if=none,id=boot,format=raw,file=", volume}, context.temp_allocator),
		"-device",
		// The boot volume is the first boot option of the firmware: with no
		// bootindex, the order of its options follows its own enumeration,
		// and a firmware with a network stack can try a network boot first.
		"virtio-blk-pci,drive=boot,bootindex=0",
		"-drive",
		strings.concatenate({"if=none,id=data,format=raw,file=", data_disk}, context.temp_allocator),
		"-device",
		fmt.tprintf("virtio-blk-pci,drive=data,disable-legacy=on,addr=0x%x", pci.DATA_DISK_DEVICE),
		"-drive",
		"if=none,id=scratch,format=raw,file=" + SCRATCH_DISK,
		"-device",
		fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,addr=0x%x", pci.SCRATCH_DISK_DEVICE),
	)
	if firmware != .Usual {
		if test_output == "" {
			fmt.eprintln("kerneltool: a machine with a TPM or with Secure Boot runs only as a test machine, with its own files")
			return nil, false
		}
		// The firmware writes its own log on the debug console port: the
		// tool shows its end when the boot program does not start.
		append(&list, "-debugcon", strings.concatenate({"file:", machine_file(test_output, FIRMWARE_LOG_SUFFIX)}, context.temp_allocator), "-global", "isa-debugcon.iobase=0x402")
	}
	if firmware == .With_Secure_Boot {
		// The flash of the firmware with Secure Boot is writable only in
		// system management mode.
		append(&list, "-global", "driver=cfi.pflash01,property=secure,value=on")
	}
	if firmware == .With_Tpm {
		// The software TPM that machine_test starts (trusted_boot_scenario.odin),
		// through the socket of this machine, on the CRB interface: the
		// command and its answer are in a buffer of memory, not moved byte
		// by byte through one register.
		append(&list, "-chardev", strings.concatenate({"socket,id=tpm_socket,path=", tpm_socket_of(test_output)}, context.temp_allocator))
		append(&list, "-tpmdev", "emulator,id=tpm,chardev=tpm_socket", "-device", "tpm-crb,tpmdev=tpm")
		// The trace of QEMU for the TPM, with the time of each line: when the
		// device received each command of the firmware and when the firmware
		// wrote to the device (a start, a cancel). It shows whether an
		// abandoned command reached QEMU and when the firmware gave it up.
		append(&list, "-msg", "timestamp=on", "-D", machine_file(test_output, QEMU_TRACE_SUFFIX))
		append(&list, "-trace", "enable=tpm_emulator_handle_request", "-trace", "enable=tpm_crb_mmio_write", "-trace", "enable=tpm_emulator_set_locality")
	}
	if test_output != "" {
		// No window. The log of the kernel (the serial port) goes to a file.
		// The monitor of QEMU for a reader is on the standard input: the tool
		// ends QEMU through it. The machine protocol of QEMU is on a socket
		// beside the log: the tool sends the keys and the moves of the
		// pointer through it, and each command has a reply (qmp.odin).
		append(&list, "-display", "none", "-serial", strings.concatenate({"file:", test_output}, context.temp_allocator), "-monitor", "stdio")
		append(&list, "-qmp", strings.concatenate({"unix:", qmp_socket_of(test_output), ",server=on,wait=off"}, context.temp_allocator))
		// A second socket of the same protocol, for the worker of a film:
		// its pictures and the keys of the scenario never share a reply
		// (film.odin). A machine with no film leaves it with no connection.
		append(&list, "-qmp", strings.concatenate({"unix:", film_qmp_socket_of(test_output), ",server=on,wait=off"}, context.temp_allocator))
	} else {
		append(&list, "-serial", "stdio")
	}
	return list[:], true
}

// network_device_of gives the network device of a machine: QEMU user
// networking with its TCP when host_port is not 0 (web_host.odin), else the
// peer (`-netdev dgram`).
network_device_of :: proc(host_port, listener_port, peer_port, machine_port: int) -> string {
	if host_port != 0 {
		return fmt.tprintf("user,id=network,restrict=on,hostfwd=tcp:127.0.0.1:%d-10.0.2.15:80,guestfwd=tcp:%s:80-tcp:127.0.0.1:%d", host_port, GUEST_ADDRESS, listener_port)
	}
	return fmt.tprintf("dgram,id=network,remote.type=inet,remote.host=127.0.0.1,remote.port=%d,local.type=inet,local.host=127.0.0.1,local.port=%d", peer_port, machine_port)
}

// network_device_problem refuses a network device that forwards a UDP port
// of the host to the port of `remote`. QEMU user networking gives each
// forwarded datagram the address 10.0.2.2, the one address that the grant
// of `remote` admits: such a forward opens the calls as the principal to
// whoever reaches the port of the host (docs/QUIC.md, section 7). A
// forward is "hostfwd=[tcp|udp]:[address]:port-[address]:port"; with no
// protocol it is TCP.
network_device_problem :: proc(device: string) -> string {
	for part in strings.split(device, ",", context.temp_allocator) {
		if !strings.has_prefix(part, "hostfwd=") {
			continue
		}
		rule := part[len("hostfwd="):]
		if !strings.has_prefix(rule, "udp:") {
			continue
		}
		dash := strings.last_index_byte(rule, '-')
		colon := strings.last_index_byte(rule, ':')
		if dash < 0 || colon < dash {
			return fmt.tprintf("the network device has a UDP forward that the tool cannot read: %s", part)
		}
		if rule[colon + 1:] == fmt.tprintf("%d", remote.LISTEN_PORT) {
			return fmt.tprintf("the network device forwards a UDP port of the host to the port %d of remote: each sender would call as the principal of the session of remote (%s)", remote.LISTEN_PORT, part)
		}
	}
	return ""
}

// run starts a program with the terminal of this tool and waits for its end.
run :: proc(command: []string) -> bool {
	process, err := os.process_start({command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("kerneltool: cannot start %s: %v", command[0], err)
		return false
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil || !state.success {
		fmt.eprintfln("kerneltool: %s failed (code %d)", command[0], state.exit_code)
		return false
	}
	return true
}

// disk_prepare makes a disk of zero bytes when the file is absent, or always
// with fresh.
disk_prepare :: proc(path: string, size: int, fresh: bool) -> bool {
	if !fresh && os.exists(path) {
		return true
	}
	zero := make([]u8, size)
	defer delete(zero)
	if err := os.write_entire_file(path, zero); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// make_folder makes a folder and each folder above it. Two processes of the
// parallel build can make the same folder above theirs at the same time:
// the one that loses gets "exists" for that folder before its own folder is
// made, so it tries again.
make_folder :: proc(path: string) -> bool {
	err: os.Error
	for _ in 0 ..< 4 {
		err = os.make_directory_all(path)
		if err == nil || os.exists(path) {
			return true
		}
	}
	fmt.eprintfln("kerneltool: cannot create %s: %v", path, err)
	return false
}

reset_folder :: proc(path: string) -> bool {
	if os.exists(path) {
		if err := os.remove_all(path); err != nil {
			fmt.eprintfln("kerneltool: cannot remove %s: %v", path, err)
			return false
		}
	}
	return make_folder(path)
}
