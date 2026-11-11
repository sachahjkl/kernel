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
package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
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
CONTRACT_PACKAGES :: []string{"blake3", "block", "boot_info", "datagram", "errors", "frame", "isolated", "module", "operation", "pointer_pictures", "remote", "ring", "store"}
BOOT_OBJECT_FOLDER :: BUILD_FOLDER + "/boot"
BOOT_PROGRAM :: BOOT_OBJECT_FOLDER + "/BOOTX64.EFI"
BOOT_VOLUME :: BUILD_FOLDER + "/boot_volume.img"
BOOT_VOLUME_FAILS :: BUILD_FOLDER + "/boot_volume_fails.img"
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
	{name = "build", about = "the modules, the boot image and the boot program, as " + BOOT_PROGRAM, run = run_build},
	{name = "test", about = "build, start the machine under QEMU, act as the person, check the log, save pictures of the screen; `test network`, `test main`: one machine only", run = run_test},
	{name = "run", about = "build, then start the machine under QEMU, with the log of the kernel on this terminal; `run without_checks`: the measure build", run = run_machine},
	{name = "screenshots", about = "test, then copy the pictures to " + DOCUMENT_SCREENSHOT_FOLDER + " and to a new folder of " + DEVELOPMENT_LOG_FOLDER, run = run_screenshots},
	{name = "measure", about = "build, start the machine, run the measures of the locks of the kernel with no other program, and stop: the numbers are in " + TEST_OUTPUT_MEASURE + "; `measure scheduler N`: the program scheduler N times; `measure without_checks ...`: the measure build, with no check in the kernel (no lock order check, no check of the frames)", run = run_measure},
	{name = "film", about = "build, start the machine, film the terminal, and write " + FILM_OUTPUT + " and a copy in " + DEVELOPMENT_LOG_FOLDER + " (needs ffmpeg)", run = run_film},
	{name = "font", about = "convert the BDF file of the font to " + FONT_OUTPUT, run = run_font},
	{name = "pointers", about = "convert the pointer manifests of resources/pointers to pointer theme files in " + POINTER_BUILD_FOLDER + ", with the Xcursor folder of " + POINTER_THEME_SOURCE_VARIABLE + " or of the path after the command; print a table of each theme", run = run_pointers},
	{name = "portrait", about = "convert " + PORTRAIT_SOURCE + " to " + PORTRAIT_OUTPUT, run = run_portrait},
	{name = "call", about = "call \"service.export(arguments)\": call an export of a service of the machine that `run` started, through the program remote, and print the typed result", run = run_call},
	{name = "repeat", about = "repeat <module> <count>: build one module again and again, with no machine, and compare each build with the first one", run = run_repeat},
	{name = "check", about = "odin check -vet and odin test of the host code, then test", run = run_check},
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
		fmt.printfln("  %-11s %s", c.name, c.about)
	}
}

// run_build builds the modules, the boot images, and then the boot program,
// which contains the kernel module and a boot image. It builds a second
// boot program for the test of a start that fails.
run_build :: proc(args: []string) -> int {
	if !build_modules() || !build_boot_program("boot_fails.image", BOOT_VOLUME_FAILS, 0) {
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

// build_boot_program builds the boot program with a boot image of the build
// folder, and writes a boot volume with it. BOOT_PROGRAM is the last one.
build_boot_program :: proc(image: string, volume_path: string, self_test: int) -> bool {
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
			"-thread-count:1", // The same object at each build: see build_module.
			"-no-threaded-checker",
			"-source-code-locations:filename", // No path of the folder of the build in the program.
			CONTRACT_LIBRARY,
			SUPPORT_LIBRARY,
			strings.concatenate({"-define:BOOT_IMAGE=../build/", image}, context.temp_allocator),
			fmt.tprintf("-define:SELF_TEST=%d", self_test),
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
	// `test network`, `test main`: one machine only, for the work on it.
	if len(args) == 1 && args[0] == "main" {
		return machine_test(scenario[:], BOOT_VOLUME, TEST_OUTPUT, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "network" {
		return machine_test(scenario_network[:], BOOT_VOLUME, TEST_OUTPUT_NETWORK, MACHINE_STOP_OK, TEST_DATA_DISK) ? 0 : EXIT_FAILURE
	}
	// `test tcp`: the two machines of TCP only.
	if len(args) == 1 && args[0] == "tcp" {
		return tcp_tests_run() ? 0 : EXIT_FAILURE
	}
	if !machine_test(scenario_fails[:], BOOT_VOLUME_FAILS, TEST_OUTPUT_FAILS, 0) || !self_tests_run() || !machine_test(scenario[:], BOOT_VOLUME, TEST_OUTPUT, MACHINE_STOP_OK, TEST_DATA_DISK) || !machine_test(scenario_network[:], BOOT_VOLUME, TEST_OUTPUT_NETWORK, MACHINE_STOP_OK, TEST_DATA_DISK) || !tcp_tests_run() || !persistence_run() || !test_modules() || !test_descriptions() {
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
	for folder in ([]string{"runtime", "contract/blake3", "contract/isolated", "contract/pointer_pictures", "contract/remote", "support/bar", "support/graphics", "support/interface", "support/addresses", "support/information", "support/vector_font", "support/network", "support/tcp", "support/web", "tools/kerneltool"}) {
		name, _ := strings.replace_all(folder, "/", "_", context.temp_allocator)
		if !run({"odin", "test", folder, "-vet", CONTRACT_LIBRARY, SUPPORT_LIBRARY, strings.concatenate({"-out:" + BUILD_FOLDER + "/test_", name}, context.temp_allocator)}) {
			return EXIT_FAILURE
		}
	}
	if run_test(nil) != 0 {
		return EXIT_FAILURE
	}
	return modules_same_again() ? 0 : EXIT_FAILURE
}

// modules_same_again builds the modules a second time and compares each
// module file with the file of the first build: the hash of a module is
// the identity of its source, not of one build (property 11).
modules_same_again :: proc() -> bool {
	module_paths := files_with_suffix(MODULE_BUILD_FOLDER, ".module") or_return
	// The pointer theme files are resources of the boot image: the same
	// input gives the same bytes.
	theme_paths := files_with_suffix(POINTER_BUILD_FOLDER, ".pointers") or_return
	paths := slice.concatenate([][]string{module_paths, theme_paths}, context.temp_allocator)
	first := make([][]u8, len(paths), context.temp_allocator)
	for path, index in paths {
		bytes, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("kerneltool: cannot read %s: %v", path, err)
			return false
		}
		first[index] = bytes
	}
	build_modules() or_return
	different := 0
	for path, index in paths {
		bytes, err := os.read_entire_file(path, context.allocator)
		if err != nil || !slice.equal(bytes, first[index]) {
			// The first file stays beside the second one, to compare them.
			kept := strings.concatenate({path, ".first"}, context.temp_allocator)
			_ = os.write_entire_file(kept, first[index])
			fmt.eprintfln("kerneltool: test failed: %s is not the same bytes after a second build (the first build is %s)", path, kept)
			different += 1
		}
	}
	if different != 0 {
		return false
	}
	fmt.printfln("kerneltool: test passed: %d modules and %d pointer theme files are the same bytes after a second build", len(module_paths), len(theme_paths))
	return true
}

// machine_command gives the one QEMU command line of the project: the first
// machine of property 7. The boot volume is a virtio block device. If
// test_output is a path, the machine has no window and writes its log there.
// The network device sends each frame to the peer (peer.odin) on the
// loopback of the host, at peer_port, as one UDP datagram.
// The network device goes to the peer (`-netdev dgram`), or, when forward
// has a port, to QEMU user networking with its TCP (web_host.odin).
machine_command :: proc(volume: string, test_output: string, data_disk: string, peer: ^Peer, forward: Forward = {}) -> (command: []string, ok: bool) {
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
		"max", // Each feature that the host processor, or the emulation, has.
		"-m",
		"512",
		"-smp",
		"4",
		"-device",
		"isa-debug-exit,iobase=0xf4,iosize=0x04",
		"-no-reboot",
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

make_folder :: proc(path: string) -> bool {
	if err := os.make_directory_all(path); err != nil && !os.exists(path) {
		fmt.eprintfln("kerneltool: cannot create %s: %v", path, err)
		return false
	}
	return true
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
