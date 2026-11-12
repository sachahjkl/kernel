package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "contract:system_description"

// The machines of the trusted boot (docs/TRUSTED_BOOT.md), `kerneltool test
// trusted_boot`:
//   1. one byte of the module console changed after the system description
//      was made: the boot program stops, names the module and both hashes,
//      and the kernel never starts;
//   2. one bit of the description signature changed: the boot program stops;
//   3. the system with a software TPM (swtpm) and the firmware with a TPM
//      driver: the boot program measures the description into PCR 11 and
//      reads it back; the tool computes the value from the description and
//      compares;
//   4. another system, one byte of the module lonely changed before the
//      description was made and signed: it boots, and its measure is another
//      value, the one that the tool computes for it.

// The module that the volume of machine 1 changes: the root service starts
// it at each boot: with no check, the machine runs the changed module.
CHANGED_MODULE :: "console"
// The module that the volume of machine 4 changes: no program of that
// machine loads it.
OTHER_SYSTEM_MODULE :: "lonely"

TEST_OUTPUT_CHANGED_MODULE :: BUILD_FOLDER + "/test_output_changed_module.txt"
TEST_OUTPUT_WRONG_SIGNATURE :: BUILD_FOLDER + "/test_output_wrong_signature.txt"
TEST_OUTPUT_MEASURED :: BUILD_FOLDER + "/test_output_measured.txt"
TEST_OUTPUT_OTHER_SYSTEM :: BUILD_FOLDER + "/test_output_other_system.txt"

// The firmware of a test machine.
Machine_Firmware :: enum {
	Usual, // OVMF_CODE and OVMF_VARS: no TPM driver, no Secure Boot.
	With_Tpm, // OVMF_FULL_CODE and OVMF_FULL_VARS, with system management mode, and a software TPM.
}

// The software TPM of one machine: a new state for each machine, so that
// each starts with a TPM with no history.
TPM_FOLDER :: BUILD_FOLDER + "/tpm"
TPM_SOCKET :: TPM_FOLDER + "/swtpm.socket"
TPM_START_TIMEOUT :: 10 * time.Second

Tpm_Process :: struct {
	process: os.Process,
	started: bool,
}

// tpm_start starts swtpm, and waits until its control socket exists.
// --terminate ends it when QEMU closes the socket.
tpm_start :: proc(tpm: ^Tpm_Process) -> bool {
	reset_folder(TPM_FOLDER) or_return
	process, err := os.process_start({command = {"swtpm", "socket", "--tpm2", "--tpmstate", "dir=" + TPM_FOLDER, "--ctrl", "type=unixio,path=" + TPM_SOCKET, "--terminate"}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("kerneltool: cannot start swtpm: %v. Use the development shell: nix develop", err)
		return false
	}
	tpm^ = {process = process, started = true}
	start := time.tick_now()
	for !os.exists(TPM_SOCKET) {
		if time.tick_since(start) > TPM_START_TIMEOUT {
			fmt.eprintfln("kerneltool: swtpm made no socket %s in %v", TPM_SOCKET, TPM_START_TIMEOUT)
			tpm_stop(tpm)
			return false
		}
		time.sleep(10 * time.Millisecond)
	}
	return true
}

tpm_stop :: proc(tpm: ^Tpm_Process) {
	if !tpm.started {
		return
	}
	_ = os.process_kill(tpm.process)
	_, _ = os.process_wait(tpm.process)
	tpm.started = false
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

MEASURE_LINE :: "boot program: PCR 11 = "

scenario_measured := [?]Step {
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
	{kind = .Wait, text = MEASURE_LINE},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: "},
	{kind = .Quit},
}

// trusted_boot_tests_run runs the four machines.
trusted_boot_tests_run :: proc() -> bool {
	refused_machine_run(scenario_changed_module[:], BOOT_VOLUME_CHANGED_MODULE, TEST_OUTPUT_CHANGED_MODULE) or_return
	refused_machine_run(scenario_wrong_signature[:], BOOT_VOLUME_WRONG_SIGNATURE, TEST_OUTPUT_WRONG_SIGNATURE) or_return
	measured := measure_machine_run(scenario_measured[:], BOOT_VOLUME, TEST_OUTPUT_MEASURED) or_return
	other := measure_machine_run(scenario_other_system[:], BOOT_VOLUME_OTHER_SYSTEM, TEST_OUTPUT_OTHER_SYSTEM) or_return
	if measured == other {
		fmt.eprintln("kerneltool: test failed: a system with one byte of one module changed has the same measure")
		return false
	}
	fmt.println("kerneltool: test passed: a system with one byte of the module " + OTHER_SYSTEM_MODULE + " changed has another measure")
	return true
}

// refused_machine_run runs a machine whose boot program must refuse its
// volume, then checks that the kernel wrote nothing: it never started.
refused_machine_run :: proc(steps: []Step, volume, output: string) -> bool {
	// The tool ends QEMU: status 0.
	machine_test(steps, volume, output, 0) or_return
	log_bytes := read_file(output) or_return
	if strings.contains(string(log_bytes), "kernel: ") {
		fmt.eprintfln("kerneltool: test failed: the kernel of %s started after a refused check", volume)
		return false
	}
	fmt.printfln("kerneltool: test passed: the boot program refused %s, and the kernel did not start", volume)
	return true
}

// measure_machine_run runs a machine with the TPM, then compares the value
// of the measure register that the boot program read back with the value
// that the tool computes from the system description of the volume.
measure_machine_run :: proc(steps: []Step, volume, output: string) -> (value: [32]u8, ok: bool) {
	// The tool ends QEMU: status 0.
	machine_test(steps, volume, output, 0, firmware = .With_Tpm) or_return
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
