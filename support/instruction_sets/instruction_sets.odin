// The usable instruction sets of a program: those that the processor has
// and whose registers the kernel saves (docs/ARCHITECTURE.md, "The extended
// state of the processor", section 6). No kernel operation: CPUID says what
// the processor has and whether the kernel set CR4.OSXSAVE, and XCR0 says
// which state components the kernel saves. An instruction of a set that is
// not usable stops the program with an invalid opcode.
//
// CPUID is slow in a virtual machine (an exit to the host): a program reads
// the facts once, at its start, and keeps the result.
//
// See [usable instruction set](term:usable-instruction-set) and
// (docs/SIMD.md).
package instruction_sets

// One instruction set of the x86-64 processor. A set before Popcnt uses the
// vector registers: it is usable only when the kernel saves them.
Instruction_Set :: enum u8 {
	Sse, // SSE: the xmm registers.
	Sse2, // SSE2: integers in the xmm registers. Every x86-64 processor has it.
	Sse3, // SSE3.
	Ssse3, // SSSE3: the byte shuffle.
	Sse4_1, // SSE4.1.
	Sse4_2, // SSE4.2.
	Aes, // AES-NI: the rounds of AES.
	Pclmulqdq, // The carry-less multiplication.
	Avx, // AVX: the ymm registers.
	F16c, // The conversions of half floats.
	Fma, // The fused multiply-add.
	Avx2, // AVX2: integers in the ymm registers.
	Avx512_F, // AVX-512 Foundation: the zmm and opmask registers.
	Avx512_Dq, // AVX-512 doublewords and quadwords.
	Avx512_Cd, // AVX-512 conflict detection.
	Avx512_Bw, // AVX-512 bytes and words.
	Avx512_Vl, // AVX-512 on the xmm and ymm registers.
	Popcnt, // From here: general registers only.
	Bmi1, // Bit manipulation 1.
	Bmi2, // Bit manipulation 2.
}
// A set of instruction sets: what a program can use.
Instruction_Sets :: bit_set[Instruction_Set; u32]

// The name of each set, as the manuals of the processor write it.
@(rodata)
instruction_set_names := [Instruction_Set]string {
	.Sse       = "SSE",
	.Sse2      = "SSE2",
	.Sse3      = "SSE3",
	.Ssse3     = "SSSE3",
	.Sse4_1    = "SSE4.1",
	.Sse4_2    = "SSE4.2",
	.Popcnt    = "POPCNT",
	.Aes       = "AES",
	.Pclmulqdq = "PCLMULQDQ",
	.Avx       = "AVX",
	.F16c      = "F16C",
	.Fma       = "FMA",
	.Avx2      = "AVX2",
	.Avx512_F  = "AVX-512 F",
	.Avx512_Dq = "AVX-512 DQ",
	.Avx512_Cd = "AVX-512 CD",
	.Avx512_Bw = "AVX-512 BW",
	.Avx512_Vl = "AVX-512 VL",
	.Bmi1      = "BMI1",
	.Bmi2      = "BMI2",
}

// One bit of XCR0 for each state component that the kernel can save.
State_Component :: enum u8 {
	X87                = 0, // The registers of the x87 unit.
	Sse                = 1, // The xmm registers and MXCSR.
	Avx                = 2, // The high halves of ymm0 to ymm15.
	Opmask             = 5, // k0 to k7.
	Zmm_High_Halves    = 6, // The high halves of zmm0 to zmm15.
	Zmm_High_Registers = 7, // zmm16 to zmm31.
}
// A set of state components: the bits of XCR0.
State_Components :: bit_set[State_Component; u64]

AVX_COMPONENTS :: State_Components{.Sse, .Avx} // The components that AVX needs saved.
AVX_512_COMPONENTS :: State_Components{.Sse, .Avx, .Opmask, .Zmm_High_Halves, .Zmm_High_Registers} // The components that AVX-512 needs saved.

// What the processor says, as it said it: the decoding is a pure procedure
// (usable_from), which the host tests.
Processor_Facts :: struct {
	highest_leaf:   u32, // CPUID leaf 0, EAX: the highest leaf.
	leaf_1_ecx:     u32, // CPUID leaf 1, ECX.
	leaf_1_edx:     u32, // CPUID leaf 1, EDX.
	leaf_7_ebx:     u32, // CPUID leaf 7, subleaf 0, EBX. 0 when the highest leaf is below 7.
	leaf_7_ecx:     u32, // CPUID leaf 7, subleaf 0, ECX.
	// XCR0, read only when CPUID says OSXSAVE: without it, xgetbv is an
	// invalid opcode. Zero then.
	extended_control_register_0: u64,
	// CPUID leaf 0xD, EBX: the bytes of the area of the components that
	// XCR0 enables. 512 (the area of fxsave) without OSXSAVE.
	saved_area_size: u32,
}

// The bits of CPUID that this package reads (Intel SDM, volume 2A, CPUID).
LEAF_1_EDX_SSE :: 1 << 25
LEAF_1_EDX_SSE2 :: 1 << 26
LEAF_1_ECX_SSE3 :: 1 << 0
LEAF_1_ECX_PCLMULQDQ :: 1 << 1
LEAF_1_ECX_SSSE3 :: 1 << 9
LEAF_1_ECX_FMA :: 1 << 12
LEAF_1_ECX_SSE4_1 :: 1 << 19
LEAF_1_ECX_SSE4_2 :: 1 << 20
LEAF_1_ECX_POPCNT :: 1 << 23
LEAF_1_ECX_AES :: 1 << 25
LEAF_1_ECX_OSXSAVE :: 1 << 27
LEAF_1_ECX_AVX :: 1 << 28
LEAF_1_ECX_F16C :: 1 << 29
LEAF_7_EBX_BMI1 :: 1 << 3
LEAF_7_EBX_AVX2 :: 1 << 5
LEAF_7_EBX_BMI2 :: 1 << 8
LEAF_7_EBX_AVX512_F :: 1 << 16
LEAF_7_EBX_AVX512_DQ :: 1 << 17
LEAF_7_EBX_AVX512_CD :: 1 << 28
LEAF_7_EBX_AVX512_BW :: 1 << 30
LEAF_7_EBX_AVX512_VL :: 1 << 31

// processor_identification_read is the instruction CPUID of a leaf and a
// subleaf.
processor_identification_read :: asm(leaf: u32, subleaf: u32) -> (a, b, c, d: u32) [
	leaf -> a    = %eax,
	b            = %ebx,
	subleaf -> c = %ecx,
	d            = %edx,
	#volatile,
] {
	cpuid
}

// extended_control_register_read is the instruction XGETBV: the extended
// control register `number`. It is an invalid opcode without OSXSAVE.
extended_control_register_read :: asm(number: u32) -> (low, high: u32) [
	number = %ecx,
	low    = %eax,
	high   = %edx,
	#volatile,
] {
	xgetbv
}

// processor_facts_read asks the processor that runs it.
processor_facts_read :: proc "contextless" () -> (facts: Processor_Facts) {
	facts.highest_leaf, _, _, _ = processor_identification_read(0, 0)
	_, _, facts.leaf_1_ecx, facts.leaf_1_edx = processor_identification_read(1, 0)
	if facts.highest_leaf >= 7 {
		_, facts.leaf_7_ebx, facts.leaf_7_ecx, _ = processor_identification_read(7, 0)
	}
	facts.saved_area_size = 512
	if facts.leaf_1_ecx & LEAF_1_ECX_OSXSAVE != 0 {
		low, high := extended_control_register_read(0)
		facts.extended_control_register_0 = u64(low) | u64(high) << 32
		if facts.highest_leaf >= 0xD {
			_, facts.saved_area_size, _, _ = processor_identification_read(0xD, 0)
		}
	}
	return
}

// saved_components gives the state components that the kernel saves.
saved_components :: proc "contextless" (facts: Processor_Facts) -> State_Components {
	if facts.leaf_1_ecx & LEAF_1_ECX_OSXSAVE == 0 {
		return {.X87, .Sse} // fxsave: the kernel set CR4.OSFXSR.
	}
	known := State_Components{.X87, .Sse, .Avx, .Opmask, .Zmm_High_Halves, .Zmm_High_Registers}
	return transmute(State_Components)facts.extended_control_register_0 & known
}

// usable_from gives the usable instruction sets from the facts.
usable_from :: proc "contextless" (facts: Processor_Facts) -> (usable: Instruction_Sets) {
	has :: proc "contextless" (usable: ^Instruction_Sets, word: u32, bit: u32, set: Instruction_Set) {
		if word & bit != 0 {
			usable^ += {set}
		}
	}
	// The SSE registers: the kernel saves them on every processor.
	has(&usable, facts.leaf_1_edx, LEAF_1_EDX_SSE, .Sse)
	has(&usable, facts.leaf_1_edx, LEAF_1_EDX_SSE2, .Sse2)
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_SSE3, .Sse3)
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_SSSE3, .Ssse3)
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_SSE4_1, .Sse4_1)
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_SSE4_2, .Sse4_2)
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_AES, .Aes)
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_PCLMULQDQ, .Pclmulqdq)
	// General registers only.
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_POPCNT, .Popcnt)
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_BMI1, .Bmi1)
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_BMI2, .Bmi2)
	saved := saved_components(facts)
	if !(AVX_COMPONENTS <= saved) {
		return
	}
	// The ymm registers: the kernel saves their high halves.
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_AVX, .Avx)
	if .Avx not_in usable {
		return
	}
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_F16C, .F16c)
	has(&usable, facts.leaf_1_ecx, LEAF_1_ECX_FMA, .Fma)
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_AVX2, .Avx2)
	if !(AVX_512_COMPONENTS <= saved) {
		return
	}
	// The zmm and opmask registers: the kernel saves them too.
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_AVX512_F, .Avx512_F)
	if .Avx512_F not_in usable {
		return
	}
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_AVX512_DQ, .Avx512_Dq)
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_AVX512_CD, .Avx512_Cd)
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_AVX512_BW, .Avx512_Bw)
	has(&usable, facts.leaf_7_ebx, LEAF_7_EBX_AVX512_VL, .Avx512_Vl)
	return
}

// usable_instruction_sets reads the facts of the processor that runs it and
// gives the usable instruction sets.
usable_instruction_sets :: proc "contextless" () -> Instruction_Sets {
	return usable_from(processor_facts_read())
}
