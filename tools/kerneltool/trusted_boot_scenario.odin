package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "contract:system_description"

// The machines of the trusted boot (docs/TRUSTED_BOOT.md), `kerneltool test
// trusted_boot`. With the usual firmware, the boot program must refuse:
//   1. one byte of the module console changed after the system description
//      was made;
//   2. one bit of the description signature changed;
//   3. one byte of the kernel module changed;
//   4. a boot image with no system description;
//   5. an entry of console that states another hash, with the right bytes.
// Each names the file and stops, and the kernel never starts.
// With the firmware with a TPM driver and a software TPM (swtpm):
//   6. the boot program measures the description into PCR 11 and reads it
//      back; the tool computes the value from the description and compares;
//   7. another system, one byte of the module lonely changed before the
//      description was made and signed: it boots, and its measure is the
//      other value that the tool computes for it.
// With Secure Boot on, and the certificate of the test firmware signing
// key enrolled:
//   8. the signed boot program starts, and says that the firmware verified
//      it;
//   9. the signed boot program with one byte changed does not start;
//  10. the unsigned boot program does not start.

// The module that the volumes of machines 1 and 5 change: the root service
// starts it at each boot: with no check, the machine runs it.
CHANGED_MODULE :: "console"
// The module that the volume of machine 7 changes: no program of that
// machine loads it.
OTHER_SYSTEM_MODULE :: "lonely"

TEST_OUTPUT_CHANGED_MODULE :: BUILD_FOLDER + "/test_output_changed_module.txt"
TEST_OUTPUT_WRONG_SIGNATURE :: BUILD_FOLDER + "/test_output_wrong_signature.txt"
TEST_OUTPUT_CHANGED_KERNEL :: BUILD_FOLDER + "/test_output_changed_kernel.txt"
TEST_OUTPUT_WITHOUT_DESCRIPTION :: BUILD_FOLDER + "/test_output_without_description.txt"
TEST_OUTPUT_STATED_HASH :: BUILD_FOLDER + "/test_output_stated_hash.txt"
TEST_OUTPUT_MEASURED :: BUILD_FOLDER + "/test_output_measured.txt"
TEST_OUTPUT_OTHER_SYSTEM :: BUILD_FOLDER + "/test_output_other_system.txt"
TEST_OUTPUT_SECURE_BOOT :: BUILD_FOLDER + "/test_output_secure_boot.txt"
TEST_OUTPUT_SECURE_BOOT_CHANGED :: BUILD_FOLDER + "/test_output_secure_boot_changed.txt"
TEST_OUTPUT_SECURE_BOOT_UNSIGNED :: BUILD_FOLDER + "/test_output_secure_boot_unsigned.txt"

// The firmware of a test machine.
Machine_Firmware :: enum {
	Usual, // OVMF_CODE and OVMF_VARS: no TPM driver, no Secure Boot.
	With_Tpm, // OVMF_FULL_CODE and OVMF_FULL_VARS (Secure Boot off: no key), with system management mode, and a software TPM.
	With_Tpm_And_Secure_Boot, // The same firmware, with SECURE_BOOT_VARIABLES: the certificate of the firmware signing key enrolled, and Secure Boot on.
}

// The processors of a machine with the firmware with system management
// mode. Each access of the firmware to its variables is a system management
// interrupt that every processor of the machine must enter and leave
// together. The firmware makes many such accesses before it starts the boot
// program, and on a loaded host a processor of the machine can wait for its
// thread on the host at each of them: with 4 processors, the start of the
// boot program came after the bound of the tool, or never, in two runs of
// four. One processor has nothing to wait for. These machines test the
// boot, not the scheduler.
TPM_MACHINE_PROCESSORS :: "1"

// The first wait of a machine with that firmware: for "boot program:
// started", by name, with its own bound. A boot that is slow under the load
// of the host says nothing about the trusted boot; the tool prints the time
// that it took.
TPM_MACHINE_FIRST_WAIT_SECONDS :: 600

// The log that the firmware writes on its debug console port, beside the
// log of the machine. The firmware of Nixpkgs is a release build: it writes
// few lines there.
FIRMWARE_LOG_SUFFIX :: "_firmware.log"
FIRMWARE_LOG_LINES_SHOWN :: 40

// The line of the firmware when it cannot start a boot option, as its boot
// manager writes it on the console (UefiBootManagerLib of EDK II).
FIRMWARE_LOAD_FAILURE_LINE :: "BdsDxe: failed to load Boot"

// machine_file gives a file of one test machine beside its log.
machine_file :: proc(output, suffix: string) -> string {
	return strings.concatenate({strings.trim_suffix(output, ".txt"), suffix}, context.temp_allocator)
}

// The software TPM of one machine: a folder of its own for each machine,
// with a new state, so that each starts with a TPM with no history and no
// file of another machine.
TPM_START_TIMEOUT :: 10 * time.Second

tpm_folder_of :: proc(output: string) -> string {
	return machine_file(output, "_tpm")
}

tpm_socket_of :: proc(output: string) -> string {
	return strings.concatenate({tpm_folder_of(output), "/swtpm.socket"}, context.temp_allocator)
}

Tpm_Process :: struct {
	process: os.Process,
	started: bool,
	folder:  string,
}

// tpm_start starts swtpm for the machine of this output, and waits until
// its control socket exists. --terminate ends it when QEMU closes the
// connection; tpm_stop ends it in each case.
tpm_start :: proc(tpm: ^Tpm_Process, output: string) -> bool {
	folder := tpm_folder_of(output)
	socket := tpm_socket_of(output)
	reset_folder(folder) or_return
	log := strings.concatenate({"file=", folder, "/swtpm.log,level=20"}, context.temp_allocator)
	process, err := os.process_start({command = {"swtpm", "socket", "--tpm2", "--tpmstate", strings.concatenate({"dir=", folder}, context.temp_allocator), "--ctrl", strings.concatenate({"type=unixio,path=", socket}, context.temp_allocator), "--log", log, "--terminate"}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("kerneltool: cannot start swtpm: %v. Use the development shell: nix develop", err)
		return false
	}
	tpm^ = {process = process, started = true, folder = strings.clone(folder)}
	start := time.tick_now()
	for !os.exists(socket) {
		if time.tick_since(start) > TPM_START_TIMEOUT {
			fmt.eprintfln("kerneltool: swtpm made no socket %s in %v", socket, TPM_START_TIMEOUT)
			tpm_stop(tpm)
			return false
		}
		time.sleep(10 * time.Millisecond)
	}
	return true
}

// tpm_stop ends swtpm and waits for its end: the next machine never starts
// while it runs.
tpm_stop :: proc(tpm: ^Tpm_Process) {
	if !tpm.started {
		return
	}
	_ = os.process_kill(tpm.process)
	_, _ = os.process_wait(tpm.process)
	tpm.started = false
	delete(tpm.folder)
	tpm.folder = ""
}

// firmware_failure_report says what a machine with that firmware showed
// when a step failed, while QEMU still runs: a picture of its screen (a
// prompt or a menu of the firmware is there), then the end of the log of
// the firmware and of swtpm.
firmware_failure_report :: proc(machine: ^Machine, output: string) {
	name := machine_file(output, "_firmware_screen")
	name = name[strings.last_index_byte(name, '/') + 1:]
	_ = screen_save(machine, name)
	for path in ([]string{machine_file(output, FIRMWARE_LOG_SUFFIX), strings.concatenate({tpm_folder_of(output), "/swtpm.log"}, context.temp_allocator)}) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("kerneltool: %s: none (%v)", path, err)
			continue
		}
		lines := strings.split_lines(string(data), context.temp_allocator)
		fmt.eprintfln("kerneltool: the end of %s (%d bytes):", path, len(data))
		for line in lines[max(len(lines) - FIRMWARE_LOG_LINES_SHOWN, 0):] {
			fmt.eprintln("   ", line)
		}
	}
}

scenario_changed_module := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: " + CHANGED_MODULE + " does not have the hash of the system description: expected "},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails_changed_module"},
	{kind = .Quit},
}

scenario_wrong_signature := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: the signature of the system description is wrong"},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails_wrong_signature"},
	{kind = .Quit},
}

scenario_changed_kernel := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: " + system_description.KERNEL_ENTRY_NAME + " does not have the hash of the system description: expected "},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails_changed_kernel"},
	{kind = .Quit},
}

scenario_without_description := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: the boot image has no system description and description signature as its two last resources"},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Quit},
}

scenario_stated_hash := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: " + CHANGED_MODULE + " states in the boot image another hash than the system description: expected "},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Quit},
}

MEASURE_LINE :: "boot program: PCR 11 = "

scenario_measured := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = "boot program: verified by the boot program, which the firmware did not verify"},
	{kind = .Wait, text = "boot program: the kernel and each module and resource have the hash of the system description"},
	{kind = .Wait, text = MEASURE_LINE},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: "},
	{kind = .Wait, text = "root: measured: PCR 11 = "},
	{kind = .Wait, text = "compositor: surface console", any_order = true, seconds = 180},
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Shot, text = "boot_measured"},
	{kind = .Quit},
}

scenario_other_system := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = MEASURE_LINE},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: "},
	{kind = .Quit},
}

scenario_secure_boot := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = "boot program: verified by the firmware (Secure Boot), then by the boot program"},
	{kind = .Wait, text = MEASURE_LINE},
	{kind = .Wait, text = "root: verified by the firmware (Secure Boot), then by the boot program"},
	{kind = .Wait, text = "compositor: surface console", any_order = true, seconds = 180},
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Shot, text = "boot_secure_boot"},
	{kind = .Quit},
}

// The firmware refuses the boot program: its boot manager writes that it
// cannot load the boot option of the boot volume. The machine then never
// prints "boot program: started" (refused_machine_run checks the whole log
// after the end of QEMU).
scenario_secure_boot_refused := [?]Step {
	{kind = .Wait, text = FIRMWARE_LOAD_FAILURE_LINE, seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Quit},
}

// trusted_boot_tests_run runs the ten machines.
trusted_boot_tests_run :: proc() -> bool {
	refused_machine_run(scenario_changed_module[:], BOOT_VOLUME_CHANGED_MODULE, TEST_OUTPUT_CHANGED_MODULE) or_return
	refused_machine_run(scenario_wrong_signature[:], BOOT_VOLUME_WRONG_SIGNATURE, TEST_OUTPUT_WRONG_SIGNATURE) or_return
	refused_machine_run(scenario_changed_kernel[:], BOOT_VOLUME_CHANGED_KERNEL, TEST_OUTPUT_CHANGED_KERNEL) or_return
	refused_machine_run(scenario_without_description[:], BOOT_VOLUME_WITHOUT_DESCRIPTION, TEST_OUTPUT_WITHOUT_DESCRIPTION) or_return
	refused_machine_run(scenario_stated_hash[:], BOOT_VOLUME_STATED_HASH, TEST_OUTPUT_STATED_HASH) or_return
	measured := measure_machine_run(scenario_measured[:], BOOT_VOLUME, TEST_OUTPUT_MEASURED, .With_Tpm) or_return
	other := measure_machine_run(scenario_other_system[:], BOOT_VOLUME_OTHER_SYSTEM, TEST_OUTPUT_OTHER_SYSTEM, .With_Tpm) or_return
	if measured == other {
		fmt.eprintln("kerneltool: test failed: a system with one byte of one module changed has the same measure")
		return false
	}
	fmt.println("kerneltool: test passed: a system with one byte of the module " + OTHER_SYSTEM_MODULE + " changed has another measure")
	// With Secure Boot the system description is the same: so is PCR 11.
	secure := measure_machine_run(scenario_secure_boot[:], BOOT_VOLUME_SECURE_BOOT, TEST_OUTPUT_SECURE_BOOT, .With_Tpm_And_Secure_Boot) or_return
	if secure != measured {
		fmt.eprintln("kerneltool: test failed: the signed boot program of one system gives another value of PCR 11 than the unsigned one")
		return false
	}
	refused_machine_run(scenario_secure_boot_refused[:], BOOT_VOLUME_SECURE_BOOT_CHANGED, TEST_OUTPUT_SECURE_BOOT_CHANGED, .With_Tpm_And_Secure_Boot) or_return
	refused_machine_run(scenario_secure_boot_refused[:], BOOT_VOLUME, TEST_OUTPUT_SECURE_BOOT_UNSIGNED, .With_Tpm_And_Secure_Boot) or_return
	return true
}

// refused_machine_run runs a machine whose boot program, or whose firmware,
// must refuse its volume, then checks that the kernel wrote nothing: it
// never started. With Secure Boot the boot program itself must not start.
refused_machine_run :: proc(steps: []Step, volume, output: string, firmware: Machine_Firmware = .Usual) -> bool {
	// The tool ends QEMU: status 0.
	machine_test(steps, volume, output, 0, firmware = firmware) or_return
	log_bytes := read_file(output) or_return
	log := string(log_bytes)
	if strings.contains(log, "kernel: ") {
		fmt.eprintfln("kerneltool: test failed: the kernel of %s started after a refused check", volume)
		return false
	}
	if firmware == .With_Tpm_And_Secure_Boot {
		if strings.contains(log, "boot program: started") {
			fmt.eprintfln("kerneltool: test failed: the firmware with Secure Boot started the boot program of %s", volume)
			return false
		}
		fmt.printfln("kerneltool: test passed: the firmware with Secure Boot refused the boot program of %s, which never started", volume)
		return true
	}
	fmt.printfln("kerneltool: test passed: the boot program refused %s, and the kernel did not start", volume)
	return true
}

// measure_machine_run runs a machine with the TPM, then compares the value
// of the measure register that the boot program read back with the value
// that the tool computes from the system description of the volume.
measure_machine_run :: proc(steps: []Step, volume, output: string, firmware: Machine_Firmware) -> (value: [32]u8, ok: bool) {
	// The tool ends QEMU: status 0.
	machine_test(steps, volume, output, 0, firmware = firmware) or_return
	description := image_description_read(volume) or_return
	expected := system_description.hexadecimal(measure_expected(description))
	log_bytes := read_file(output) or_return
	log := string(log_bytes)
	at := strings.index(log, MEASURE_LINE)
	if at < 0 || len(log) < at + len(MEASURE_LINE) + 64 {
		fmt.eprintfln("kerneltool: test failed: %s has no line \"%s\" with 64 digits", output, MEASURE_LINE)
		return
	}
	found := log[at + len(MEASURE_LINE):][:64]
	if found != string(expected[:]) {
		fmt.eprintfln("kerneltool: test failed: the TPM of %s holds %s in PCR 11; the system description gives %s", volume, found, string(expected[:]))
		return
	}
	fmt.printfln("kerneltool: test passed: PCR 11 of %s is %s, the value that the tool computes from its system description", volume, found)
	return measure_expected(description), true
}
