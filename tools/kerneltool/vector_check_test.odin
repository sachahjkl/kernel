package kerneltool

import "core:fmt"
import "core:strings"
import "core:testing"

// Listings in the form of `llvm-objdump -d --no-show-raw-insn
// --x86-asm-syntax=att`, as the flake's LLVM 18 prints them for the kernel.

// The three allowed procedures, each with its vector instructions and its
// end label, as kernel/processor.asm makes them.
@(private = "file")
ALLOWED_PROCEDURES :: `
0000000000026692 <extended_state_save>:
   26692:      	testb	%sil, %sil
   26695:      	je	0x266a6 <extended_state_save.with_fxsave>
   26697:      	movl	$0xffffffff, %eax       # imm = 0xFFFFFFFF
   266a1:      	xsaveopt64	(%rdi)
   266a5:      	retq

00000000000266a6 <extended_state_save.with_fxsave>:
   266a6:      	fxsave64	(%rdi)
   266aa:      	retq

00000000000266ab <extended_state_save_end>:
   266ab:      	int3

00000000000266ac <extended_state_restore>:
   266ac:      	testb	%sil, %sil
   266b6:      	xrstor64	(%rdi)
   266ba:      	retq

00000000000266bb <extended_state_restore.with_fxrstor>:
   266bb:      	fxrstor64	(%rdi)
   266bf:      	retq

00000000000266c0 <extended_state_restore_end>:
   266c0:      	int3

00000000000266c4 <extended_state_restore_and_read>:
   266c4:      	movq	%rdi, %r8
   266d0:      	xrstor64	(%r8)
   266e0:      	fnstcw	(%r9)
   266e4:      	stmxcsr	0x8(%r9)
   266e9:      	movq	%xmm0, 0x10(%r9)
   266f5:      	vextractf128	$0x1, %ymm0, %xmm1
   26704:      	vzeroupper

0000000000026708 <extended_state_restore_and_read.done>:
   26708:      	retq

0000000000026709 <extended_state_restore_and_read_end>:
   26709:      	int3
`

// listing_of_a_kernel gives a listing with a procedure of `count` ordinary
// instructions, the allowed procedures, and then `after`.
@(private = "file")
listing_of_a_kernel :: proc(count: int, allowed := ALLOWED_PROCEDURES, after := "") -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "\nbuild/modules/kernel/linked.elf:\tfile format elf64-x86-64\n\nDisassembly of section .text:\n\n0000000000001000 <kernel::schedule>:\n")
	for index in 0 ..< count {
		fmt.sbprintf(&builder, "    %x:      \tmovq\t%%rdi, %%rax\n", 0x1000 + index * 3)
	}
	strings.write_string(&builder, allowed)
	strings.write_string(&builder, after)
	return strings.to_string(builder)
}

@(private = "file")
has_problem :: proc(check: Vector_Check, text: string) -> bool {
	for problem in check.problems {
		if strings.contains(problem, text) {
			return true
		}
	}
	return false
}

@(test)
a_kernel_with_vector_code_only_in_the_save_and_the_restore_passes :: proc(t: ^testing.T) {
	check := vector_check_listing(listing_of_a_kernel(VECTOR_CHECK_LEAST_INSTRUCTIONS))
	testing.expect_value(t, len(check.refused), 0)
	testing.expect_value(t, len(check.problems), 0)
	testing.expect_value(t, check.vector_instructions, [KERNEL_VECTOR_PROCEDURE_COUNT]int{2, 2, 6})
}

@(test)
each_kind_of_vector_instruction_outside_the_save_is_refused :: proc(t: ^testing.T) {
	after := `
0000000000026800 <kernel::thread_create>:
   26800:      	movups	%xmm0, (%rax)
   26804:      	vmovdqu	%ymm1, (%rax)
   26808:      	vmovdqu64	%zmm16, (%rax)
   2680e:      	kmovw	%k1, %eax
   26812:      	fldt	(%rax)
   26814:      	fstp	%st(0)
   26816:      	movq	%mm0, %rax
   2681a:      	ldmxcsr	(%rax)
   2681d:      	stmxcsr	(%rax)
   26820:      	vzeroupper
   26823:      	emms
   26825:      	xrstor64	(%rax)
   26829:      	fninit
   2682b:      	wait
   2682c:      	fnstsw	%ax
   2682e:      	fstsw	%ax
   26830:      	fnstcw	(%rax)
   26832:      	fstcw	(%rax)
   26834:      	fnclex
   26836:      	fclex
   26838:      	finit
   2683a:      	fnsave	(%rax)
   2683c:      	fsave	(%rax)
   2683e:      	fnstenv	(%rax)
   26840:      	fstenv	(%rax)
   26842:      	fwait
   26843:      	xsaves64	(%rax)
   26847:      	ldtilecfg	(%rax)
   2684c:      	tileloadd	(%rax,%rbx), %tmm0
   26852:      	movq	%rax, %rbx
`
	check := vector_check_listing(listing_of_a_kernel(VECTOR_CHECK_LEAST_INSTRUCTIONS, after = after))
	testing.expect_value(t, len(check.refused), 29) // All but the last line.
	testing.expect_value(t, len(check.problems), 0)
	if len(check.refused) > 13 {
		testing.expect_value(t, check.refused[0].procedure, "kernel::thread_create")
		testing.expect_value(t, check.refused[0].instruction, "movups	%xmm0, (%rax)")
		testing.expect_value(t, check.refused[13].instruction, "wait")
	}
}

@(test)
an_empty_listing_fails :: proc(t: ^testing.T) {
	check := vector_check_listing("")
	testing.expect(t, has_problem(check, "the listing has 0 instructions"))
	testing.expect(t, has_problem(check, "the allowed procedure extended_state_save is not in the listing"))
	testing.expect(t, has_problem(check, "the allowed procedure extended_state_restore is not in the listing"))
	testing.expect(t, has_problem(check, "the allowed procedure extended_state_restore_and_read is not in the listing"))
}

@(test)
a_listing_of_another_format_fails :: proc(t: ^testing.T) {
	// The Intel syntax with raw bytes and no colon after the address: the
	// parser reads no instruction, and must say so.
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< 2 * VECTOR_CHECK_LEAST_INSTRUCTIONS {
		fmt.sbprintf(&builder, "0x%x  48 89 f8  mov rax, rdi\n", 0x1000 + index * 3)
	}
	strings.write_string(&builder, "0x9000  0f ae 07  fxsave [rdi]\n")
	check := vector_check_listing(strings.to_string(builder))
	testing.expect(t, has_problem(check, "the listing has 0 instructions"))
	testing.expect(t, has_problem(check, "is not in the listing"))
	testing.expect_value(t, len(check.refused), 0)
}

@(test)
a_listing_with_no_allowed_procedure_fails :: proc(t: ^testing.T) {
	check := vector_check_listing(listing_of_a_kernel(VECTOR_CHECK_LEAST_INSTRUCTIONS, allowed = ""))
	testing.expect(t, !has_problem(check, "instructions that the check could read"))
	testing.expect(t, has_problem(check, "the allowed procedure extended_state_save is not in the listing"))
	testing.expect(t, has_problem(check, "the allowed procedure extended_state_restore_and_read is not in the listing"))
}

@(test)
a_short_listing_fails :: proc(t: ^testing.T) {
	// 100 ordinary instructions and the 23 of the allowed procedures.
	check := vector_check_listing(listing_of_a_kernel(100))
	testing.expect(t, has_problem(check, "the listing has 123 instructions"))
}

@(test)
an_allowed_procedure_with_no_vector_instruction_that_the_check_sees_fails :: proc(t: ^testing.T) {
	// The save as a matcher that sees nothing would read it.
	allowed, _ := strings.replace_all(ALLOWED_PROCEDURES, "xsaveopt64", "movq", context.temp_allocator)
	allowed, _ = strings.replace_all(allowed, "fxsave64", "movq", context.temp_allocator)
	check := vector_check_listing(listing_of_a_kernel(VECTOR_CHECK_LEAST_INSTRUCTIONS, allowed = allowed))
	testing.expect(t, has_problem(check, "the allowed procedure extended_state_save has no vector instruction that the check sees"))
	testing.expect(t, !has_problem(check, "the allowed procedure extended_state_restore has no vector instruction"))
}

@(test)
an_allowed_procedure_with_no_end_label_fails :: proc(t: ^testing.T) {
	// The end label of the save is gone: the code after it would be allowed.
	allowed, _ := strings.replace_all(ALLOWED_PROCEDURES, "<extended_state_save_end>", "<stub_0>", context.temp_allocator)
	check := vector_check_listing(listing_of_a_kernel(VECTOR_CHECK_LEAST_INSTRUCTIONS, allowed = allowed))
	testing.expect(t, has_problem(check, "the allowed procedure extended_state_save is followed by stub_0, not by its end label extended_state_save_end"))
}

@(test)
a_listing_that_ends_inside_an_allowed_procedure_fails :: proc(t: ^testing.T) {
	procedures := string(ALLOWED_PROCEDURES)
	index := strings.index(procedures, "0000000000026709 <extended_state_restore_and_read_end>")
	check := vector_check_listing(listing_of_a_kernel(VECTOR_CHECK_LEAST_INSTRUCTIONS, allowed = procedures[:index]))
	testing.expect(t, has_problem(check, "the listing ends inside the allowed procedure extended_state_restore_and_read"))
}

@(test)
a_name_that_only_starts_like_an_allowed_procedure_is_refused :: proc(t: ^testing.T) {
	after := `
0000000000026800 <extended_state_saved_elsewhere>:
   26800:      	movups	%xmm0, (%rax)
`
	check := vector_check_listing(listing_of_a_kernel(VECTOR_CHECK_LEAST_INSTRUCTIONS, after = after))
	testing.expect_value(t, len(check.refused), 1)
}

@(test)
an_instruction_before_any_procedure_name_is_refused :: proc(t: ^testing.T) {
	check := vector_check_listing("   26000:      \tpxor\t%xmm0, %xmm0\n")
	testing.expect_value(t, len(check.refused), 1)
}

@(test)
general_registers_that_look_like_vector_names_pass :: proc(t: ^testing.T) {
	// %rsp, %esi, %spl, a prefix "lock", verw, and a call of a procedure
	// whose name has "wait" in it: no vector register.
	testing.expect(t, !instruction_uses_vector_registers("lock\t\tcmpxchgq\t%rsi, (%rsp)"))
	testing.expect(t, !instruction_uses_vector_registers("movb\t%sil, %spl"))
	testing.expect(t, !instruction_uses_vector_registers("verw\t%ax"))
	testing.expect(t, !instruction_uses_vector_registers("callq\t0xade0 <kernel::pit_wait>"))
	testing.expect(t, !instruction_uses_vector_registers("umwait\t%ecx"))
	testing.expect(t, instruction_uses_vector_registers("kmovq\t%k7, %rax"))
	testing.expect(t, instruction_uses_vector_registers("rep\t\tvmovdqu\t%ymm0, (%rax)"))
}
