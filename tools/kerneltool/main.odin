// kerneltool: all the automation of the project, in one program.
//
//   odin run tools/kerneltool -out:build/kerneltool -- <command>
//
// The project has no scripts. Each build step, each test and each call to a
// third-party program is a command of this tool, so that the way a third-party
// program is run is written in one place.
//
// The development shell of flake.nix supplies what this tool needs:
//   on the path: odin, lld-link, qemu-system-x86_64
//   OVMF_CODE, OVMF_VARS: the UEFI firmware image and its variable store
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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

// BOOT_MARK is the text that the boot program prints. Keep equal to boot/main.odin.
BOOT_MARK :: "boot program: ok"
TEST_TIMEOUT :: 60 * time.Second

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS :: [?]Command {
	{name = "build", about = "the boot program, as " + BOOT_PROGRAM, run = run_build},
	{name = "run", about = "build, then start the machine under QEMU with the console on this terminal", run = run_machine},
	{name = "test", about = "build, start the machine under QEMU, and wait for the mark of the boot program", run = run_test},
	{name = "check", about = "odin check -vet of this tool, then test", run = run_check},
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
		fmt.printfln("  %-6s %s", c.name, c.about)
	}
}

// run_build compiles boot/ to COFF objects and links them into a UEFI program.
run_build :: proc(args: []string) -> int {
	if !reset_folder(BOOT_OBJECT_FOLDER) || !make_folder(BOOT_PROGRAM_FOLDER) {
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
			"-vet",
			"-out:" + BOOT_OBJECT_FOLDER + "/boot.obj",
		},
	) {
		return EXIT_FAILURE
	}

	entries, err := os.read_all_directory_by_path(BOOT_OBJECT_FOLDER, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot list %s: %v", BOOT_OBJECT_FOLDER, err)
		return EXIT_FAILURE
	}
	link := make([dynamic]string, context.temp_allocator)
	append(&link, "lld-link", "/subsystem:efi_application", "/entry:efi_main", "/nodefaultlib", "/out:" + BOOT_PROGRAM)
	for entry in entries {
		if strings.has_suffix(entry.name, ".obj") {
			append(&link, strings.concatenate({BOOT_OBJECT_FOLDER, "/", entry.name}, context.temp_allocator))
		}
	}
	if !run(link[:]) {
		return EXIT_FAILURE
	}
	return 0
}

run_machine :: proc(args: []string) -> int {
	if code := run_build(nil); code != 0 {
		return code
	}
	command, ok := machine_command()
	if !ok {
		return EXIT_FAILURE
	}
	if !run(command) {
		return EXIT_FAILURE
	}
	return 0
}

// run_test starts the machine with its console in a file, and passes when the
// file holds BOOT_MARK. The boot program stops the machine, so QEMU exits.
run_test :: proc(args: []string) -> int {
	if code := run_build(nil); code != 0 {
		return code
	}
	command, ok := machine_command()
	if !ok {
		return EXIT_FAILURE
	}
	output, open_err := os.open(TEST_OUTPUT, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", TEST_OUTPUT, open_err)
		return EXIT_FAILURE
	}
	process, start_err := os.process_start({command = command, stdout = output, stderr = output})
	os.close(output)
	if start_err != nil {
		fmt.eprintfln("kerneltool: cannot start %s: %v", command[0], start_err)
		return EXIT_FAILURE
	}
	state, wait_err := os.process_wait(process, TEST_TIMEOUT)
	if wait_err != nil || !state.exited {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		fmt.eprintfln("kerneltool: test failed: the machine did not stop in %v", TEST_TIMEOUT)
		return EXIT_FAILURE
	}

	text, read_err := os.read_entire_file(TEST_OUTPUT, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", TEST_OUTPUT, read_err)
		return EXIT_FAILURE
	}
	if !strings.contains(string(text), BOOT_MARK) {
		fmt.eprintfln("kerneltool: test failed: \"%s\" is not in %s", BOOT_MARK, TEST_OUTPUT)
		return EXIT_FAILURE
	}
	fmt.printfln("kerneltool: test passed: the machine printed \"%s\"", BOOT_MARK)
	return 0
}

run_check :: proc(args: []string) -> int {
	if !run({"odin", "check", "tools/kerneltool", "-vet"}) {
		return EXIT_FAILURE
	}
	return run_test(nil)
}

// machine_command gives the one QEMU command line of the project: the first
// machine of property 7. The boot volume is BOOT_VOLUME, shown as a FAT disk.
machine_command :: proc() -> (command: []string, ok: bool) {
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
		"-m",
		"256",
		"-nographic",
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
