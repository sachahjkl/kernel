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
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

EXIT_FAILURE :: 1
EXIT_USAGE :: 2

ROOT_MARK :: "flake.nix"

BUILD_FOLDER :: "build"
BOOT_OBJECT_FOLDER :: BUILD_FOLDER + "/boot"
BOOT_VOLUME :: BUILD_FOLDER + "/esp"
BOOT_PROGRAM_FOLDER :: BOOT_VOLUME + "/EFI/BOOT"
BOOT_PROGRAM :: BOOT_PROGRAM_FOLDER + "/BOOTX64.EFI"
FIRMWARE_VARIABLES :: BUILD_FOLDER + "/ovmf_vars.fd"
TEST_OUTPUT :: BUILD_FOLDER + "/test_output.txt"

DOCUMENT_SCREENSHOT_FOLDER :: "docs/screenshots"

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS :: [?]Command {
	{name = "build", about = "the modules, the boot image and the boot program, as " + BOOT_PROGRAM, run = run_build},
	{name = "run", about = "build, then start the machine under QEMU, with the log of the kernel on this terminal", run = run_machine},
	{name = "test", about = "build, start the machine under QEMU, act as the person, check the log, save pictures of the screen", run = run_test},
	{name = "screenshots", about = "test, then copy the pictures to " + DOCUMENT_SCREENSHOT_FOLDER, run = run_screenshots},
	{name = "font", about = "convert the BDF file of the font to " + FONT_OUTPUT, run = run_font},
	{name = "check", about = "odin check -vet and odin test of the host code, then test", run = run_check},
}

main :: proc() {
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

// run_build builds the modules, the boot image, and then the boot program,
// which contains the kernel module and the boot image.
run_build :: proc(args: []string) -> int {
	if !build_modules() || !reset_folder(BOOT_OBJECT_FOLDER) || !make_folder(BOOT_PROGRAM_FOLDER) {
		return EXIT_FAILURE
	}
	if !run(
		{
			"odin",
			"build",
			"boot",
			"-target:freestanding_amd64_win64",
			"-build-mode:obj",
			"-no-entry-point",
			"-no-crt",
			"-default-to-nil-allocator",
			"-disable-red-zone",
			"-o:speed",
			"-vet",
			"-out:" + BOOT_OBJECT_FOLDER + "/boot.obj",
		},
	) {
		return EXIT_FAILURE
	}
	if !run({"nasm", "-f", "win64", "-o", BOOT_OBJECT_FOLDER + "/jump.obj", "boot/jump.asm"}) {
		return EXIT_FAILURE
	}
	objects, ok := files_with_suffix(BOOT_OBJECT_FOLDER, ".obj")
	if !ok {
		return EXIT_FAILURE
	}
	link := make([dynamic]string, context.temp_allocator)
	append(&link, "lld-link", "/subsystem:efi_application", "/entry:efi_main", "/nodefaultlib", "/out:" + BOOT_PROGRAM)
	append(&link, ..objects)
	if !run(link[:]) {
		return EXIT_FAILURE
	}
	return 0
}

run_machine :: proc(args: []string) -> int {
	if code := run_build(nil); code != 0 {
		return code
	}
	command, ok := machine_command(false)
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
	if !machine_test() || !test_modules() {
		return EXIT_FAILURE
	}
	fmt.println("kerneltool: all tests passed")
	return 0
}

// run_screenshots runs the machine test and copies its pictures to the documents.
run_screenshots :: proc(args: []string) -> int {
	if code := run_test(nil); code != 0 {
		return code
	}
	pictures, ok := files_with_suffix(SCREENSHOT_FOLDER, ".png")
	if !ok || !make_folder(DOCUMENT_SCREENSHOT_FOLDER) {
		return EXIT_FAILURE
	}
	for picture in pictures {
		target := strings.concatenate({DOCUMENT_SCREENSHOT_FOLDER, picture[strings.last_index(picture, "/"):]}, context.temp_allocator)
		if err := os.copy_file(target, picture); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", target, err)
			return EXIT_FAILURE
		}
		fmt.printfln("kerneltool: wrote %s", target)
	}
	return 0
}

run_check :: proc(args: []string) -> int {
	if !run({"odin", "check", "tools/kerneltool", "-vet"}) {
		return EXIT_FAILURE
	}
	for folder in ([]string{"blake3", "tools/kerneltool"}) {
		name, _ := strings.replace_all(folder, "/", "_", context.temp_allocator)
		if !run({"odin", "test", folder, "-vet", strings.concatenate({"-out:" + BUILD_FOLDER + "/test_", name}, context.temp_allocator)}) {
			return EXIT_FAILURE
		}
	}
	return run_test(nil)
}

// machine_command gives the one QEMU command line of the project: the first
// machine of property 7. The boot volume is BOOT_VOLUME, shown as a FAT disk.
machine_command :: proc(test: bool) -> (command: []string, ok: bool) {
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
		"-m",
		"512",
		"-device",
		"isa-debug-exit,iobase=0xf4,iosize=0x04",
		"-no-reboot",
		"-net",
		"none",
		"-drive",
		strings.concatenate({"if=pflash,format=raw,readonly=on,file=", firmware_code}, context.temp_allocator),
		"-drive",
		"if=pflash,format=raw,file=" + FIRMWARE_VARIABLES,
		"-drive",
		"format=raw,file=fat:rw:" + BOOT_VOLUME,
	)
	if test {
		// No window. The log of the kernel (the serial port) goes to a file.
		// The QEMU monitor is on the standard input: the tool sends keys through it.
		append(&list, "-display", "none", "-serial", "file:" + TEST_OUTPUT, "-monitor", "stdio")
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
