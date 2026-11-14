package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// The proof that the kernel has no x87, MMX, SSE, AVX or opmask instruction
// outside the save and the restore of the extended state
// (docs/ARCHITECTURE.md, "The extended state of the processor"). The kernel
// saves the registers of a program only when a processor leaves a thread for
// another one: during each kernel entry and each interrupt, the registers of
// the program stay live, so one instruction of the kernel that changes one
// of them gives a program a wrong value, with no error. The build
// disassembles the linked kernel and refuses it when such an instruction is
// found.
//
// A check that reads nothing proves nothing: a listing in another format,
// an empty listing or a failed disassembly must fail, not pass. So the check
// also refuses a listing with fewer than VECTOR_CHECK_LEAST_INSTRUCTIONS
// instructions, and it must see each allowed procedure, with at least one
// vector instruction in it (where one must be: the matcher proves that it
// sees one), and its end label right after it.
//
// The check reads only the sections that llvm-objdump -d disassembles: the
// executable ones. The start code of the other processors is in the data of
// processor.asm on purpose: its fninit and ldmxcsr run once, at the start of
// a processor, before it runs any thread, and its first thread is restored.

// The procedures of src/kernel/processor.asm that save and restore the
// extended state: the only code of the kernel that may name these
// registers. A NASM label inside one of them is "name.label", and each one
// ends with the label "name_end".
KERNEL_VECTOR_PROCEDURE_COUNT :: 3
@(rodata)
kernel_vector_procedures := [KERNEL_VECTOR_PROCEDURE_COUNT]string{"extended_state_save", "extended_state_restore", "extended_state_restore_and_read"}

// The kernel of 2026-11-12 has 31 145 instructions in its listing. A third
// of that is far below any kernel that this system builds, and far above
// what a listing that the parser misreads in part gives.
VECTOR_CHECK_LEAST_INSTRUCTIONS :: 10_000

// One instruction that the check refuses.
Vector_Instruction :: struct {
	procedure:   string,
	instruction: string,
}

// What the check found in one listing.
Vector_Check :: struct {
	refused:             [dynamic]Vector_Instruction,
	instructions:        int, // The instruction lines that the parser read.
	// For each allowed procedure: seen, and its vector instructions.
	seen:                [KERNEL_VECTOR_PROCEDURE_COUNT]bool,
	vector_instructions: [KERNEL_VECTOR_PROCEDURE_COUNT]int,
	// The sentences of each other failure: a missing procedure, a missing
	// end label, too few instructions.
	problems:            [dynamic]string,
}

// Words before the mnemonic in a line of llvm-objdump.
@(rodata)
instruction_prefixes := [?]string{"rep", "repe", "repz", "repne", "repnz", "lock", "notrack", "data16", "addr32", "rex64", "cs", "ds", "ss", "es", "fs", "gs"}

// Starts of mnemonics that use the extended state with no register name in
// their operands.
@(rodata)
vector_mnemonic_starts := [?]string{
	"f", // x87: fld, fstp, fninit, fnstcw, fnstsw, fnclex, fnsave, fnstenv, frstor, fxsave64, fxrstor64, fwait, and the rest; also fstsw, fstcw, fclex, finit, fsave, fstenv when the disassembler joins the wait.
	"v", // VEX and EVEX: vmovdqu, vzeroupper, vldmxcsr, vxorps. verr and verw are let through below.
	"k", // The opmask registers of AVX-512: kmovw, kmovq.
	"emms",
	"ldmxcsr",
	"stmxcsr",
	"xsave",   // xsave, xsaveopt, xsavec, xsaves, and their 64 forms.
	"xrstor",  // xrstor, xrstors, and their 64 forms.
	"tile",    // AMX: tileloadd, tilestored, tilezero, tilerelease.
	"ldtilecfg",
	"sttilecfg",
	"tdp",     // AMX: tdpbssd and the rest.
}

// Whole mnemonics that use the extended state. "wait" is how llvm-objdump
// prints fwait (0x9B): it raises a pending x87 exception of the program in
// the kernel. No other mnemonic of x86 is "wait" or starts with it (the
// waits of WAITPKG are umwait and tpause).
@(rodata)
vector_mnemonics := [?]string{"wait"}

// Register names in the AT&T syntax of llvm-objdump.
@(rodata)
vector_register_starts := [?]string{"%xmm", "%ymm", "%zmm", "%st", "%mm", "%tmm"}

// allowed_procedure_index gives the index of the allowed procedure that a
// name of the listing belongs to, or -1.
allowed_procedure_index :: proc(name: string) -> int {
	for allowed, index in kernel_vector_procedures {
		if name == allowed || (strings.has_prefix(name, allowed) && len(name) > len(allowed) && name[len(allowed)] == '.') {
			return index
		}
	}
	return -1
}

// instruction_uses_vector_registers says if one instruction (the text after
// the address, in AT&T syntax) reads or changes an x87, MMX, SSE, AVX, AMX or
// opmask register, or the state of the x87 or of SSE.
instruction_uses_vector_registers :: proc(instruction: string) -> bool {
	text := instruction
	mnemonic := ""
	for word in strings.fields_iterator(&text) {
		is_prefix := false
		for prefix in instruction_prefixes {
			if word == prefix {
				is_prefix = true
			}
		}
		if !is_prefix {
			mnemonic = word
			break
		}
	}
	if mnemonic != "" && mnemonic != "verr" && mnemonic != "verw" {
		for start in vector_mnemonic_starts {
			if strings.has_prefix(mnemonic, start) {
				return true
			}
		}
		for whole in vector_mnemonics {
			if mnemonic == whole {
				return true
			}
		}
	}
	for start in vector_register_starts {
		if strings.contains(instruction, start) {
			return true
		}
	}
	// The opmask registers: %k0 to %k7.
	for index := strings.index(instruction, "%k"); index >= 0; {
		after := index + 2
		if after < len(instruction) && instruction[after] >= '0' && instruction[after] <= '7' {
			return true
		}
		next := strings.index(instruction[after:], "%k")
		if next < 0 {
			break
		}
		index = after + next
	}
	return false
}

// vector_check_listing reads a listing of `llvm-objdump -d
// --no-show-raw-insn --x86-asm-syntax=att`. An instruction before the first
// procedure name counts as outside the allowed procedures. The check passes
// when `refused` and `problems` are both empty.
vector_check_listing :: proc(listing: string) -> (check: Vector_Check) {
	check.refused = make([dynamic]Vector_Instruction, context.temp_allocator)
	check.problems = make([dynamic]string, context.temp_allocator)
	procedure := ""
	inside := -1 // The allowed procedure of the current name, or -1.
	text := listing
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		// "0000000000025800 <copy_bytes_without_overlap>:"
		if strings.has_suffix(trimmed, ">:") {
			if open := strings.index(trimmed, " <"); open >= 0 && hexadecimal(trimmed[:open]) {
				name := trimmed[open + 2:len(trimmed) - 2]
				next := allowed_procedure_index(name)
				if inside >= 0 && next != inside {
					// An allowed procedure ends only at its end label.
					end := strings.concatenate({kernel_vector_procedures[inside], "_end"}, context.temp_allocator)
					if name != end {
						append(&check.problems, fmt.tprintf("the allowed procedure %s is followed by %s, not by its end label %s: its end is not known", kernel_vector_procedures[inside], name, end))
					}
				}
				if next >= 0 {
					check.seen[next] = true
				}
				procedure = name
				inside = next
				continue
			}
		}
		// "25800:      	movq	%rdi, %rax"
		colon := strings.index(trimmed, ":")
		if colon <= 0 || !hexadecimal(trimmed[:colon]) {
			continue
		}
		instruction := strings.trim_space(trimmed[colon + 1:])
		if instruction == "" {
			continue
		}
		check.instructions += 1
		if !instruction_uses_vector_registers(instruction) {
			continue
		}
		if inside >= 0 {
			check.vector_instructions[inside] += 1
		} else {
			append(&check.refused, Vector_Instruction{procedure = procedure, instruction = instruction})
		}
	}
	if inside >= 0 {
		append(&check.problems, fmt.tprintf("the listing ends inside the allowed procedure %s, before its end label", kernel_vector_procedures[inside]))
	}
	if check.instructions < VECTOR_CHECK_LEAST_INSTRUCTIONS {
		append(&check.problems, fmt.tprintf("the listing has %d instructions that the check could read, and a kernel has more than %d: the format of llvm-objdump changed, or the listing is empty", check.instructions, VECTOR_CHECK_LEAST_INSTRUCTIONS))
	}
	for name, index in kernel_vector_procedures {
		if !check.seen[index] {
			append(&check.problems, fmt.tprintf("the allowed procedure %s is not in the listing: the check cannot place the save and the restore", name))
		} else if check.vector_instructions[index] == 0 {
			append(&check.problems, fmt.tprintf("the allowed procedure %s has no vector instruction that the check sees, and it has one: the check does not see vector instructions", name))
		}
	}
	return
}

@(private = "file")
hexadecimal :: proc(text: string) -> bool {
	for character in text {
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return false
		}
	}
	return len(text) > 0
}

// kernel_has_no_vector_instruction disassembles the linked kernel and
// says if the check passes. It prints each refused instruction and each
// problem.
kernel_has_no_vector_instruction :: proc(linked: string) -> bool {
	command := [?]string{"llvm-objdump", "-d", "--no-show-raw-insn", "--x86-asm-syntax=att", linked}
	state, standard_output, standard_error, error := os.process_exec({command = command[:]}, context.temp_allocator)
	if error != nil || !state.exited || !state.success {
		fmt.eprintfln("kerneltool: cannot disassemble %s with llvm-objdump: %v %s", linked, error, string(standard_error))
		return false
	}
	check := vector_check_listing(string(standard_output))
	if len(check.refused) == 0 && len(check.problems) == 0 {
		return true
	}
	for problem in check.problems {
		fmt.eprintfln("kerneltool: the check of the vector instructions of the kernel fails: %s", problem)
	}
	if len(check.refused) > 0 {
		fmt.eprintfln("kerneltool: the kernel has %d instructions that use an x87, MMX, SSE or AVX register outside the save and the restore of the extended state; the registers of a program would change during a kernel entry:", len(check.refused))
		for finding in check.refused[:min(len(check.refused), 40)] {
			fmt.eprintfln("kerneltool:   %s: %s", finding.procedure, finding.instruction)
		}
	}
	return false
}
