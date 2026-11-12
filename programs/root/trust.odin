package root

import "contract:blake3"
import op "contract:operation"
import "contract:system_description"
import "support:system"

// The check of the root service (docs/TRUSTED_BOOT.md, "The root service").
//
// The boot program verified the description signature and every hash
// before the kernel started, and wrote what it verified in the trust
// record. This service reads the record in the boot record of the kernel,
// takes the system description of the boot image only when its hash is the
// one that the boot program verified, and checks every module and resource
// of the boot image against it once, before it starts the first program.
//
// Once is enough: the kernel gives this service the pages of the boot image
// with the right Read and no Write, so no program can change a module
// between this check and its start. The kernel itself is not in the boot
// image: only the boot program checks it. The kernel does not read the
// description.

// The boot record, read once: about 2.5 KiB, kept out of the stack.
trust_boot_report: op.Boot_Report

trust_check :: proc "contextless" () {
	report := &trust_boot_report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Boot), 0, u64(uintptr(report)), size_of(op.Boot_Report))
	trust := &report.trust
	if trust.verifier == .None {
		fail("the boot program did not verify the system description", .Bad_State)
	}
	description, _, found := system_description.trust_resources(image)
	if !found {
		fail("the boot image has no system description", .Bad_State)
	}
	if blake3.hash(description) != trust.description_hash {
		fail("the system description is not the one that the boot program verified", .Bad_State)
	}
	start := system.nanoseconds()
	result := system_description.image_check(description, image)
	spent := system.nanoseconds() - start
	if result.fault != .None {
		expected := system_description.hexadecimal(result.expected_hash)
		found_digits := system_description.hexadecimal(result.found_hash)
		buffer: [256]u8
		text := system.format(buffer[:], system_description.name_of(&result.name), ": ", system_description.fault_sentences[result.fault])
		system.log_in("programs", .Error, "root: ", text, ": expected ", string(expected[:]), ", found ", string(found_digits[:]))
		fail(text, .Bad_State)
	}
	system.log("root: the boot image agrees with the system description that the boot program verified: ", trust.entry_count - 1, " modules and resources checked in ", spent / 1000, " us; the kernel was checked by the boot program only")
	if report.cycle_frequency != 0 {
		system.log("root: the boot program checked the signature and every hash in ", trust.check_cycles * 1_000_000 / report.cycle_frequency, " us")
	}
	if trust.key_kind == .Test {
		system.log_in("programs", .Warning, "root: the system description is signed by the test signing key, whose private key is published: this system is not trusted")
	}
	if trust.verifier == .Boot_Program {
		system.log("root: verified by the boot program, which the firmware did not verify")
	} else {
		system.log("root: verified by the firmware (Secure Boot), then by the boot program")
	}
	switch trust.measure {
	case .Measured:
		digits := system_description.hexadecimal(trust.measure_value)
		system.log("root: measured: PCR ", trust.measure_register, " = ", string(digits[:]), ", at try ", trust.measure_tries)
	case .No_Tpm:
		system.log("root: the system description is not measured into the TPM: the firmware has no TPM")
	case .Refused:
		system.log_in("programs", .Warning, "root: the TPM refused the measure of the system description: status ", system.Hex(trust.measure_status), ", after ", trust.measure_tries, " tries: PCR ", trust.measure_register, " does not hold it")
	case .Not_Read:
		system.log_in("programs", .Warning, "root: the system description is measured, but the read of PCR ", trust.measure_register, " failed: status ", system.Hex(trust.measure_status))
	case .None:
		system.log_in("programs", .Warning, "root: the boot program did not try the measure")
	}
}
