#+build !freestanding
package instruction_sets

import "core:testing"

// A processor of these tests has every set that this package knows.
every_set_of_the_processor :: proc(extended_control_register_0: u64, osxsave: bool) -> Processor_Facts {
	return {
		highest_leaf = 0xD,
		leaf_1_ecx = LEAF_1_ECX_SSE3 | LEAF_1_ECX_PCLMULQDQ | LEAF_1_ECX_SSSE3 | LEAF_1_ECX_FMA | LEAF_1_ECX_SSE4_1 | LEAF_1_ECX_SSE4_2 | LEAF_1_ECX_POPCNT | LEAF_1_ECX_AES | (osxsave ? u32(LEAF_1_ECX_OSXSAVE) : 0) | LEAF_1_ECX_AVX | LEAF_1_ECX_F16C,
		leaf_1_edx = LEAF_1_EDX_SSE | LEAF_1_EDX_SSE2,
		leaf_7_ebx = LEAF_7_EBX_BMI1 | LEAF_7_EBX_AVX2 | LEAF_7_EBX_BMI2 | LEAF_7_EBX_AVX512_F | LEAF_7_EBX_AVX512_DQ | LEAF_7_EBX_AVX512_CD | LEAF_7_EBX_AVX512_BW | LEAF_7_EBX_AVX512_VL,
		extended_control_register_0 = extended_control_register_0,
	}
}

SETS_OF_SSE :: Instruction_Sets{.Sse, .Sse2, .Sse3, .Ssse3, .Sse4_1, .Sse4_2, .Popcnt, .Aes, .Pclmulqdq, .Bmi1, .Bmi2}
SETS_OF_AVX :: SETS_OF_SSE + Instruction_Sets{.Avx, .F16c, .Fma, .Avx2}
SETS_OF_AVX_512 :: SETS_OF_AVX + Instruction_Sets{.Avx512_F, .Avx512_Dq, .Avx512_Cd, .Avx512_Bw, .Avx512_Vl}

@(test)
a_kernel_that_saves_with_fxsave_gives_no_avx :: proc(t: ^testing.T) {
	// No OSXSAVE: a value of XCR0 is not read, also if it claims AVX.
	facts := every_set_of_the_processor(0xE7, false)
	testing.expect_value(t, usable_from(facts), SETS_OF_SSE)
	testing.expect_value(t, saved_components(facts), State_Components{.X87, .Sse})
}

@(test)
a_kernel_that_saves_x87_and_sse_with_xsave_gives_no_avx :: proc(t: ^testing.T) {
	testing.expect_value(t, usable_from(every_set_of_the_processor(0x3, true)), SETS_OF_SSE)
}

@(test)
a_kernel_that_saves_avx_gives_avx2_and_not_avx_512 :: proc(t: ^testing.T) {
	testing.expect_value(t, usable_from(every_set_of_the_processor(0x7, true)), SETS_OF_AVX)
}

@(test)
avx_512_needs_its_three_components :: proc(t: ^testing.T) {
	// The opmask alone, or two of the three, is not enough.
	testing.expect_value(t, usable_from(every_set_of_the_processor(0x27, true)), SETS_OF_AVX)
	testing.expect_value(t, usable_from(every_set_of_the_processor(0x67, true)), SETS_OF_AVX)
	testing.expect_value(t, usable_from(every_set_of_the_processor(0xE7, true)), SETS_OF_AVX_512)
}

@(test)
a_processor_without_avx_gives_no_avx_2_and_no_avx_512 :: proc(t: ^testing.T) {
	facts := every_set_of_the_processor(0xE7, true)
	facts.leaf_1_ecx &~= LEAF_1_ECX_AVX
	testing.expect_value(t, usable_from(facts), SETS_OF_SSE)
}

@(test)
components_that_this_package_does_not_know_are_not_given :: proc(t: ^testing.T) {
	// PKRU (bit 9) and the tiles of AMX (bits 17 and 18).
	facts := every_set_of_the_processor(0x7 | 1 << 9 | 1 << 17 | 1 << 18, true)
	testing.expect_value(t, saved_components(facts), State_Components{.X87, .Sse, .Avx})
}
