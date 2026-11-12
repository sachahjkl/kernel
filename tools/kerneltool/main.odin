// kerneltool: all the automation of the project, in one program.
//
//   odin run tools/kerneltool -out:build/kerneltool -- <command>
//
// The project has no scripts. Each build step, each test and each call to a
// third-party program is a command of this tool, so that the way a third-party
// program is run is written in one place.
//
// The development shell of flake.nix supplies what this tool needs:
//   on the path: odin, lld-link, ld.lld, nasm, qemu-system-x86_64
//   OVMF_CODE, OVMF_VARS: the UEFI firmware image and its variable store
//   FONT_SOURCE: the BDF file of the font, for the command "font"
//   POINTER_THEME_SOURCE: the folder of the Xcursor theme of the owner (docs/POINTERS.md)
//   VECTOR_FONT_SOURCES: the font files of the vector font candidates, for the command "vector_fonts"
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
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
CONTRACT_PACKAGES :: []string{"blake3", "block", "boot_info", "datagram", "date", "errors", "fixed_addresses", "frame", "glyph_cache", "isolated", "module", "operation", "pointer_pictures", "release", "remote", "ring", "settings", "store"}
BOOT_OBJECT_FOLDER :: BUILD_FOLDER + "/boot"
BOOT_PROGRAM :: BOOT_OBJECT_FOLDER + "/BOOTX64.EFI"
BOOT_VOLUME :: BUILD_FOLDER + "/boot_volume.img"
BOOT_VOLUME_FAILS :: BUILD_FOLDER + "/boot_volume_fails.img"
BOOT_VOLUME_SHORTAGE :: BUILD_FOLDER + "/boot_volume_shortage.img"
BOOT_VOLUME_WITHOUT_RETURN_CHECK :: BUILD_FOLDER + "/boot_volume_without_return_check.img" // The kernel kernel_without_return_check: one machine of `test return_fault` only.
TEST_OUTPUT_SHORTAGE :: BUILD_FOLDER + "/test_output_shortage.txt"
BOOT_VOLUME_SELF_TEST :: BUILD_FOLDER + "/boot_volume_self_test_%d.img"
// The path where the firmware looks for the boot program of a disk.
BOOT_PROGRAM_PATH :: "EFI/BOOT/BOOTX64.EFI"
FIRMWARE_VARIABLES :: BUILD_FOLDER + "/ovmf_vars.fd"
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
// The development log: one folder of pictures per run of `screenshots`. It
// is beside the repository, not in it: no run replaces the pictures of
// another run.
DEVELOPMENT_LOG_FOLDER :: "../kernel-devlog"

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS :: [?]Command {
	{name = "build", about = "the modules, the boot image and the boot program, as " + BOOT_PROGRAM + "; one process for each module, as many at once as the processors, or `build <processes>`", run = run_build},
	{name = "module", about = "module <name> with_checks|without_checks measure_run|usual_run: build one module of the table (the parallel build runs this command)", run = run_module},
	{name = "test", about = "build, start the machine under QEMU, act as the person, check the log, save pictures of the screen; `test network`, `test main`, `test power`, `test tcp`, `test quic`, `test quic-real`, `test random`, `test extended_state`, `test return_fault`: one part only", run = run_test},
	{name = "run", about = "build, then start the machine under QEMU, with the log of the kernel on this terminal; `run without_checks`: the measure build", run = run_machine},
	{name = "screenshots", about = "test, then copy the pictures to " + DOCUMENT_SCREENSHOT_FOLDER + " and to a new folder of " + DEVELOPMENT_LOG_FOLDER, run = run_screenshots},
	{name = "measure", about = "build, start the machine, run the measures of the locks of the kernel with no other program, and stop: the numbers are in " + TEST_OUTPUT_MEASURE + "; `measure scheduler N`: the program scheduler N times; `measure windows`: each window that the interface package draws, alone, and a table of the time of its pictures; `measure without_checks ...`: the measure build, with no check in the kernel (no lock order check, no check of the frames)", run = run_measure},
	{name = "film", about = "build, start the machine, film the terminal, and write " + FILM_OUTPUT + " and a copy in " + DEVELOPMENT_LOG_FOLDER + " (needs ffmpeg)", run = run_film},
	{name = "font", about = "convert the BDF file of the font to " + FONT_OUTPUT, run = run_font},
	{name = "pointers", about = "convert the pointer manifests of resources/pointers to pointer theme files in " + POINTER_BUILD_FOLDER + ", with the Xcursor folder of " + POINTER_THEME_SOURCE_VARIABLE + " or of the path after the command; print a table of each theme", run = run_pointers},
	{name = "vector_fonts", about = "subset the vector font candidates of " + VECTOR_FONT_SOURCES_VARIABLE + " to " + VECTOR_FONT_FOLDER + " and draw " + CANDIDATES_PICTURE, run = run_vector_fonts},
	{name = "logo", about = "draw the files of the mark of the system from support/mark: " + LOGO_FOLDER + " and " + PROJECT_IMAGE + "; `check` verifies them", run = run_logo},
	{name = "portrait", about = "convert " + PORTRAIT_SOURCE + " to " + PORTRAIT_OUTPUT, run = run_portrait},
	{name = "call", about = "call \"service.export(arguments)\": call an export of a service of the machine that `run` started, through the program remote, and print the typed result", run = run_call},
	{name = "repeat", about = "repeat <module> <count>: build one module again and again, with no machine, and count the distinct modules, LLVM IR files and objects; `repeat all <count> [processes]`: every module and the boot program, one row each", run = run_repeat},
	{name = "cryptography-take", about = "cryptography-take <file under the root of Odin> <file of the repository>: copy a file of core:crypto with the listed import changes, and print its line of the manifest", run = run_cryptography_take},
	{name = "cryptography-system-hashes", about = "print the line of " + CRYPTOGRAPHY_SYSTEM_FILES + " for each .odin file of support/cryptography that is not taken from Odin", run = run_cryptography_system_hashes},
	{name = "cryptography-origin", about = "check that each file of " + CRYPTOGRAPHY_MANIFEST + " is its origin in Odin with the listed changes only", run = run_cryptography_origin},
	{name = "changelog", about = "new <type> <subject> \"<text>\" (or - and the text on the standard input) | check | assemble | release <release number> | notes <release number>: the fragments of " + FRAGMENT_FOLDER + " and the releases of " + CHANGELOG_FILE, run = run_changelog},
	{name = "release_number", about = "print the release number of the system: the newest release of " + CHANGELOG_FILE, run = run_release_number},
	{name = "check", about = "odin check -vet and odin test of the host code, changelog check, then test", run = run_check},
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

// run_build builds the modules, the boot images, and then the boot program,
// which contains the kernel module and a boot image. It builds a second
// boot program for the test of a start that fails.
run_build :: proc(args: []string) -> int {
	// `build <processes>`: the count of module processes at once.
	if len(args) > 1 || (len(args) == 1 && !parse_module_build_processes(args[0])) {
		fmt.eprintln("kerneltool: build [processes]")
		return EXIT_USAGE
	}
	if !build_modules() || !build_boot_program("boot_fails.image", BOOT_VOLUME_FAILS, 0) || !build_boot_program("boot_shortage.image", BOOT_VOLUME_SHORTAGE, 0) || !build_boot_program("boot.image", BOOT_VOLUME_WITHOUT_RETURN_CHECK, 0, "kernel_without_return_check") {
		return EXIT_FAILURE
	}
	// One boot program for each test of the kernel on itself.
	for test in self_tests {
		if !build_boot_program("boot.image", self_test_file(BOOT_VOLUME_SELF_TEST, test.number), test.number) {
			return EXIT_FAILURE
		}
	}
	if !build_boot_program("boot.image", BOOT_VOLUME, 0) {
		return EXIT_FAILURE
	}
	return 0
}

// build_boot_program builds the boot program with a boot image and a kernel
// module of the build folder, and writes a boot volume with it. BOOT_PROGRAM
// is the last one.
build_boot_program :: proc(image: string, volume_path: string, self_test: int, kernel := "kernel") -> bool {
	reset_folder(BOOT_OBJECT_FOLDER) or_return
	run(
		{
			"odin",
			"build",
			"boot",
			"-target:freestanding_amd64_win64",
			"-build-mode:obj",
			"-no-entry-point",
			"-default-to-nil-allocator",
			"-disable-red-zone",
			"-o:speed",
			"-vet",
			"-source-code-locations:filename", // No path of the folder of the build in the program.
			CONTRACT_LIBRARY,
			SUPPORT_LIBRARY,
			strings.concatenate({"-define:BOOT_IMAGE=../build/", image}, context.temp_allocator),
			fmt.tprintf("-define:SELF_TEST=%d", self_test),
			fmt.tprintf("-define:KERNEL_MODULE=../build/modules/%s.module", kernel),
			"-out:" + BOOT_OBJECT_FOLDER + "/boot.obj",
		},
	) or_return
	run({"nasm", "-f", "win64", "-o", BOOT_OBJECT_FOLDER + "/jump.obj", "boot/jump.asm"}) or_return
	run({"nasm", "-f", "win64", "-DWIN64", "-o", BOOT_OBJECT_FOLDER + "/memory.obj", RUNTIME_MEMORY}) or_return
	objects := files_with_suffix(BOOT_OBJECT_FOLDER, ".obj") or_return
	link := make([dynamic]string, context.temp_allocator)
	append(&link, "lld-link", "/subsystem:efi_application", "/entry:efi_main", "/nodefaultlib", "/out:" + BOOT_PROGRAM)
	append(&link, ..objects)
	run(link[:]) or_return
	program := read_file(BOOT_PROGRAM) or_return
	volume, fits := volume_encode({{path = BOOT_PROGRAM_PATH, data = program}}, context.temp_allocator)
	if !fits {
		fmt.eprintln("kerneltool: the boot program does not fit in the boot volume")
		return false
	}
	if write_err := os.write_entire_file(volume_path, volume); write_err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", volume_path, write_err)
		return false
	}
	return true
}

run_machine :: proc(args: []string) -> int {
	if len(args) >= 1 && args[0] == "without_checks" {
		test_build_checks = false
	}
	if code := run_build(nil); code != 0 {
		return code
	}
	if !disk_prepare(DATA_DISK, DATA_DISK_SIZE, false) {
		return EXIT_FAILURE
	}
	// The peer receives the call requests of `kerneltool call` at CALL_PORT.
	peer: Peer
	if !peer_start(&peer, CALL_PORT) {
		return EXIT_FAILURE
	}
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

// run_test runs the machine test (machine.odin), then the host load test.
run_test :: proc(args: []string) -> int {
	if code := run_build(nil); code != 0 {
		return code
	}
	if !reset_folder(SCREENSHOT_FOLDER) {
		return EXIT_FAILURE
	}
	// A start that fails ends when the tool ends QEMU: status 0.
	if !disk_prepare(TEST_DATA_DISK, DATA_DISK_SIZE, true) {
		return EXIT_FAILURE
	}
	// `test network`, `test main`, `test power`, `test tcp`, `test random`, `test extended_state`, `test return_fault`, `test fault_ring`: one part only, for the work on it.
	if len(args) == 1 && args[0] == "tcp" {
		return tcp_tests_run() ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "power" {
		return power_loss_run() && power_loss_settings_run() ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "main" {
		return machine_test(scenario[:], BOOT_VOLUME, TEST_OUTPUT, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "network" {
		return machine_test(scenario_network[:], BOOT_VOLUME, TEST_OUTPUT_NETWORK, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
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
		return machine_test(scenario_shortage[:], BOOT_VOLUME_SHORTAGE, TEST_OUTPUT_SHORTAGE, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
	}
	// `test fault_ring`: the machine of the fault ring only.
	if len(args) == 1 && args[0] == "fault_ring" {
		return fault_ring_tests_run() ? 0 : EXIT_FAILURE
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
	if !machine_test(scenario_fails[:], BOOT_VOLUME_FAILS, TEST_OUTPUT_FAILS, 0) || !machine_test(scenario_shortage[:], BOOT_VOLUME_SHORTAGE, TEST_OUTPUT_SHORTAGE, MACHINE_STOP_OK, TEST_DATA_DISK) || !self_tests_run() || !machine_test(scenario[:], BOOT_VOLUME, TEST_OUTPUT, MACHINE_STOP_OK, TEST_DATA_DISK) || !machine_test(scenario_network[:], BOOT_VOLUME, TEST_OUTPUT_NETWORK, MACHINE_STOP_OK, TEST_DATA_DISK) || !tcp_tests_run() || !quic_tests_run() || !quic_real_tests_run() || !random_tests_run() || !extended_state_tests_run() || !return_fault_tests_run() || !fault_ring_tests_run() || !cryptography_tests_run() || !persistence_run() || !power_loss_run() || !power_loss_settings_run() || !test_modules() || !test_descriptions() {
		return EXIT_FAILURE
	}
	fmt.println("kerneltool: all tests passed")
	return 0
}

// run_screenshots runs the machine test and copies its pictures to the
// documents and to a new folder of the development log.
run_screenshots :: proc(args: []string) -> int {
	if code := run_test(nil); code != 0 {
		return code
	}
	pictures, ok := files_with_suffix(SCREENSHOT_FOLDER, ".png")
	// The name of the folder is the time of the run, in UTC.
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	log_folder := fmt.tprintf("%s/%04d-%02d-%02d_%02d%02d%02d", DEVELOPMENT_LOG_FOLDER, year, int(month), day, hour, minute, second)
	if !ok || !make_folder(DOCUMENT_SCREENSHOT_FOLDER) || !make_folder(DEVELOPMENT_LOG_FOLDER) || !make_folder(log_folder) {
		return EXIT_FAILURE
	}
	for picture in pictures {
		for folder in ([]string{DOCUMENT_SCREENSHOT_FOLDER, log_folder}) {
			target := strings.concatenate({folder, picture[strings.last_index(picture, "/"):]}, context.temp_allocator)
			if err := os.copy_file(target, picture); err != nil {
				fmt.eprintfln("kerneltool: cannot write %s: %v", target, err)
				return EXIT_FAILURE
			}
			fmt.printfln("kerneltool: wrote %s", target)
		}
	}
	return 0
}

TEST_OUTPUT_MEASURE :: BUILD_FOLDER + "/test_output_measure.txt"

// run_measure runs the measures of the program `locks` on a machine where
// only the desktop runs: the numbers have no load of the other programs of
// the test. The program checks its counts; the tool does not check a speed.
// `measure scheduler N`: N machines that run only the program scheduler
// with the desktop; the numbers are in build/test_output_scheduler_<n>.txt.
run_measure :: proc(args: []string) -> int {
	args := args
	if len(args) == 1 && args[0] == "windows" {
		measure_run = true
	}
	if len(args) >= 1 && args[0] == "without_checks" {
		test_build_checks = false
		args = args[1:]
	}
	if code := run_build(nil); code != 0 {
		return code
	}
	if !make_folder(SCREENSHOT_FOLDER) || !disk_prepare(TEST_DATA_DISK, DATA_DISK_SIZE, true) {
		return EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "windows" {
		return measure_windows() ? 0 : EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "address_space" {
		return machine_test(scenario_measure_address_space[:], BOOT_VOLUME, TEST_OUTPUT_MEASURE, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "shortage" {
		return machine_test(scenario_shortage[:], BOOT_VOLUME_SHORTAGE, TEST_OUTPUT_SHORTAGE, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
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
			if !machine_test(scenario_measure_scheduler[:], BOOT_VOLUME, output, MACHINE_STOP_OK, TEST_DATA_DISK) {
				return EXIT_FAILURE
			}
		}
		return 0
	}
	if !machine_test(scenario_measure[:], BOOT_VOLUME, TEST_OUTPUT_MEASURE, MACHINE_STOP_OK, TEST_DATA_DISK) {
		return EXIT_FAILURE
	}
	return 0
}

FILM_OUTPUT :: FILM_FOLDER + "/terminal.mp4"
TEST_OUTPUT_FILM :: BUILD_FOLDER + "/test_output_film.txt"

// run_film films the terminal. The film is for the development log: it is
// not a test.
run_film :: proc(args: []string) -> int {
	if code := run_build(nil); code != 0 {
		return code
	}
	if !reset_folder(FILM_FOLDER) || !make_folder(SCREENSHOT_FOLDER) {
		return EXIT_FAILURE
	}
	// The tool ends QEMU: status 0.
	if !disk_prepare(TEST_DATA_DISK, DATA_DISK_SIZE, true) || !machine_test(scenario_film[:], BOOT_VOLUME, TEST_OUTPUT_FILM, 0, TEST_DATA_DISK) {
		return EXIT_FAILURE
	}
	if !run({"ffmpeg", "-loglevel", "error", "-y", "-framerate", fmt.tprint(FILM_RATE), "-i", FILM_FRAME, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", FILM_OUTPUT}) {
		return EXIT_FAILURE
	}
	frames, _ := files_with_suffix(FILM_FOLDER, ".ppm")
	for frame in frames {
		_ = os.remove(frame)
	}
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	target := fmt.tprintf("%s/%04d-%02d-%02d_%02d%02d%02d_terminal.mp4", DEVELOPMENT_LOG_FOLDER, year, int(month), day, hour, minute, second)
	if !make_folder(DEVELOPMENT_LOG_FOLDER) {
		return EXIT_FAILURE
	}
	if err := os.copy_file(target, FILM_OUTPUT); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", target, err)
		return EXIT_FAILURE
	}
	fmt.printfln("kerneltool: wrote %s (%d pictures) and %s", FILM_OUTPUT, len(frames), target)
	return 0
}

run_check :: proc(args: []string) -> int {
	if !run({"odin", "check", "tools/kerneltool", "-vet", CONTRACT_LIBRARY, SUPPORT_LIBRARY}) {
		return EXIT_FAILURE
	}
	// A package of the contract library compiles with that library only:
	// the compiler refuses an import of "support:".
	for name in CONTRACT_PACKAGES {
		if !run({"odin", "check", strings.concatenate({"contract/", name}, context.temp_allocator), "-no-entry-point", "-vet", CONTRACT_LIBRARY}) {
			return EXIT_FAILURE
		}
		fmt.printfln("kerneltool: test passed: contract:%s compiles with the contract library only", name)
	}
	// The tests of runtime/memory.asm link the form of the host: the
	// compiler assembles runtime/memory_for_host_tests.asm itself and links
	// its object by its path (a library found through `-L/` is refused by
	// the linker of the Nix sandbox).
	for folder in ([]string{"runtime", "contract/blake3", "contract/isolated", "contract/pointer_pictures", "contract/remote", "support/sentence", "support/cryptography/vectors", "modules/cryptography", "support/quic", "contract/date", "support/storage_mount", "support/storage_retention", "support/calendar", "support/line_editor", "modules/interface_module", "modules/sample", "support/system", "support/bar", "support/graphics", "support/interface", "support/addresses", "support/information", "support/vector_font", "support/network", "support/tcp", "support/web", "support/cryptography/chacha20", "support/random", "tools/kerneltool", "contract/fixed_addresses", "contract/settings", "modules/text_shaping", "support/text_shaping", "support/mark", "support/terminal", "runtime/without_vector_registers", "support/instruction_sets"}) {
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
	if !fixed_addresses_check() {
		return EXIT_FAILURE
	}
	if !changelog_check() {
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
// machine of property 7. The boot volume is a virtio block device. If
// test_output is a path, the machine has no window and writes its log there.
// The network device sends each frame to the peer (peer.odin) on the
// loopback of the host, at peer_port, as one UDP datagram.
// The network device goes to the peer (`-netdev dgram`), or, when forward
// has a port, to QEMU user networking with its TCP (web_host.odin).
// processor gives the processor of the machine (Processor_Model).
machine_command :: proc(volume: string, test_output: string, data_disk: string, peer: ^Peer, forward: Forward = {}, processor: Processor_Model = .Maximum) -> (command: []string, ok: bool) {
	if !disk_prepare(SCRATCH_DISK, SCRATCH_DISK_SIZE, false) {
		return nil, false
	}
	firmware_code := os.get_env("OVMF_CODE", context.temp_allocator)
	firmware_variables := os.get_env("OVMF_VARS", context.temp_allocator)
	if firmware_code == "" || firmware_variables == "" {
		fmt.eprintln("kerneltool: OVMF_CODE and OVMF_VARS are not set. Use the development shell: nix develop")
		return nil, false
	}
	// The firmware writes its variables, so it gets a private copy.
	if err := os.copy_file(FIRMWARE_VARIABLES, firmware_variables); err != nil {
		fmt.eprintfln("kerneltool: cannot copy %s: %v", firmware_variables, err)
		return nil, false
	}
	if !run({"chmod", "u+w", FIRMWARE_VARIABLES}) {
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	append(
		&list,
		"qemu-system-x86_64",
		"-machine",
		"q35",
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
		forward.host_port != 0 ? fmt.tprintf("user,id=network,restrict=on,hostfwd=tcp:127.0.0.1:%d-10.0.2.15:80,guestfwd=tcp:%s:80-tcp:127.0.0.1:%d", forward.host_port, GUEST_ADDRESS, forward.listener.port) : fmt.tprintf("dgram,id=network,remote.type=inet,remote.host=127.0.0.1,remote.port=%d,local.type=inet,local.host=127.0.0.1,local.port=%d", peer.port, peer.machine.port),
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
		"if=pflash,format=raw,file=" + FIRMWARE_VARIABLES,
		"-drive",
		strings.concatenate({"if=none,id=boot,format=raw,file=", volume}, context.temp_allocator),
		"-device",
		"virtio-blk-pci,drive=boot",
		"-drive",
		strings.concatenate({"if=none,id=data,format=raw,file=", data_disk}, context.temp_allocator),
		"-device",
		fmt.tprintf("virtio-blk-pci,drive=data,disable-legacy=on,addr=0x%x", pci.DATA_DISK_DEVICE),
		"-drive",
		"if=none,id=scratch,format=raw,file=" + SCRATCH_DISK,
		"-device",
		fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,addr=0x%x", pci.SCRATCH_DISK_DEVICE),
	)
	if test_output != "" {
		// No window. The log of the kernel (the serial port) goes to a file.
		// The QEMU monitor is on the standard input: the tool sends keys through it.
		append(&list, "-display", "none", "-serial", strings.concatenate({"file:", test_output}, context.temp_allocator), "-monitor", "stdio")
	} else {
		append(&list, "-serial", "stdio")
	}
	return list[:], true
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
