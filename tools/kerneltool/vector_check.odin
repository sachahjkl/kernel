package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// The proof that the kernel has no x87, MMX, SSE or AVX instruction outside
// the save and the restore of the extended state (docs/ARCHITECTURE.md, "The
// extended state of the processor"). The kernel saves the registers of a
// program only when a processor leaves a thread for another one: during
// each kernel entry and each interrupt, the registers of the program stay
// live, so one instruction of the kernel that changes one of them gives a
// program a wrong value, with no error. The build disassembles the linked
// kernel and refuses it when such an instruction is found.

// The procedures of kernel/processor.asm that save and restore the
// extended state: the only code of the kernel that may name these
// registers. A NASM label inside one of them is "name.label".
@(rodata)
kernel_vector_procedures := [?]string{"extended_state_save", "extended_state_restore", "extended_state_restore_and_read"}

// One instruction that the check refuses.
Vector_Instruction :: struct {
	procedure:   string,
	instruction: string,
}

// Words before the mnemonic in a line of llvm-objdump.
@(rodata)
instruction_prefixes := [?]string{"rep", "repe", "repz", "repne", "repnz", "lock", "notrack", "data16", "addr32", "rex64", "cs", "ds", "ss", "es", "fs", "gs"}

// Mnemonics that use the extended state with no register name in their
// operands.
@(rodata)
vector_mnemonic_starts := [?]string{
	"f", // x87: fld, fstp, fninit, fnstcw, fxsave64, fxrstor64, and the rest.
	"v", // VEX and EVEX: vmovdqu, vzeroupper, vxorps. verr and verw are let through below.
	"k", // The opmask registers of AVX-512: kmovw, kmovq.
	"emms",
	"femms",
	"ldmxcsr",
	"stmxcsr",
	"xsave",
	"xrstor",
}

// Register names in the AT&T syntax of llvm-objdump.
@(rodata)
vector_register_starts := [?]string{"%xmm", "%ymm", "%zmm", "%st", "%mm"}

// procedure_allowed says if a procedure of the listing is one of the save
// and the restore, or a label inside one of them.
procedure_allowed :: proc(procedure: string, allowed: []string) -> bool {
	for name in allowed {
		if procedure == name || (strings.has_prefix(procedure, name) && len(procedure) > len(name) && procedure[len(name)] == '.') {
			return true
		}
	}
	return false
}

// instruction_uses_vector_registers says if one instruction (the text after
// the address, in AT&T syntax) reads or changes an x87, MMX, SSE, AVX or
// opmask register.
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

// vector_instructions_find reads a listing of `llvm-objdump -d
// --no-show-raw-insn` in AT&T syntax and appends each instruction that uses
// an extended state register outside the allowed procedures. An
// instruction before the first procedure name counts as outside.
vector_instructions_find :: proc(listing: string, allowed: []string, found: ^[dynamic]Vector_Instruction) {
	procedure := ""
	text := listing
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		// "0000000000025800 <copy_bytes_without_overlap>:"
		if strings.has_suffix(trimmed, ">:") {
			if open := strings.index(trimmed, " <"); open >= 0 {
				procedure = trimmed[open + 2:len(trimmed) - 2]
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
		if instruction_uses_vector_registers(instruction) && !procedure_allowed(procedure, allowed) {
			append(found, Vector_Instruction{procedure = procedure, instruction = instruction})
		}
	}
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
// says if it holds no instruction that uses an extended state register
// outside the save and the restore. It prints each one that it finds.
kernel_has_no_vector_instruction :: proc(linked: string) -> bool {
	command := [?]string{"llvm-objdump", "-d", "--no-show-raw-insn", "--x86-asm-syntax=att", linked}
	state, standard_output, standard_error, error := os.process_exec({command = command[:]}, context.temp_allocator)
	if error != nil || !state.exited || !state.success {
		fmt.eprintfln("kerneltool: cannot disassemble %s with llvm-objdump: %v %s", linked, error, string(standard_error))
		return false
	}
	found := make([dynamic]Vector_Instruction, context.temp_allocator)
	vector_instructions_find(string(standard_output), kernel_vector_procedures[:], &found)
	if len(found) == 0 {
		return true
	}
	fmt.eprintfln("kerneltool: the kernel has %d instructions that use an x87, MMX, SSE or AVX register outside the save and the restore of the extended state; the registers of a program would change during a kernel entry:", len(found))
	for finding in found[:min(len(found), 40)] {
		fmt.eprintfln("kerneltool:   %s: %s", finding.procedure, finding.instruction)
	}
	return false
}
