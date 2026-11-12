package kerneltool

import "core:testing"

// A listing in the form of `llvm-objdump -d --no-show-raw-insn` in AT&T
// syntax: the save and the restore may name the registers; nothing else.
@(private = "file")
LISTING_OF_A_GOOD_KERNEL :: `
build/modules/kernel/linked.elf:	file format elf64-x86-64

Disassembly of section .text:

0000000000025800 <copy_bytes_without_overlap>:
   25800:      	movq	%rdi, %rax
   25803:      	rep		movsb	(%rsi), %es:(%rdi)
   25805:      	retq

0000000000025c43 <extended_state_save>:
   25c43:      	testb	%sil, %sil
   25c46:      	je	0x25c5d <extended_state_save.with_fxsave>
   25c48:      	xsaveopt64	(%rdi)
   25c5c:      	retq

0000000000025c5d <extended_state_save.with_fxsave>:
   25c5d:      	fxsave64	(%rdi)
   25c61:      	retq

0000000000025c81 <extended_state_restore_and_read>:
   25c81:      	movq	%xmm0, 0x10(%r9)
   25c86:      	vextractf128	$0x1, %ymm0, %xmm1
   25c8c:      	vzeroupper

0000000000026000 <kernel::schedule>:
   26000:      	pushq	%rbp
   26001:      	lock		xaddl	%eax, (%rcx)
   26005:      	xgetbv
   26008:      	verw	%ax
`

@(test)
a_kernel_with_vector_code_only_in_the_save_and_the_restore_passes :: proc(t: ^testing.T) {
	found := make([dynamic]Vector_Instruction, context.temp_allocator)
	vector_instructions_find(LISTING_OF_A_GOOD_KERNEL, kernel_vector_procedures[:], &found)
	testing.expect_value(t, len(found), 0)
}

@(test)
each_kind_of_vector_instruction_outside_the_save_is_refused :: proc(t: ^testing.T) {
	listing := `
0000000000026000 <kernel::thread_create>:
   26000:      	movups	%xmm0, (%rax)
   26004:      	vmovdqu	%ymm1, (%rax)
   26008:      	vmovdqu64	%zmm16, (%rax)
   2600e:      	kmovw	%k1, %eax
   26012:      	fldt	(%rax)
   26014:      	fstp	%st(0)
   26016:      	movq	%mm0, %rax
   2601a:      	ldmxcsr	(%rax)
   2601d:      	stmxcsr	(%rax)
   26020:      	vzeroupper
   26023:      	emms
   26025:      	xrstor64	(%rax)
   26029:      	fninit
   2602b:      	movq	%rax, %rbx
`
	found := make([dynamic]Vector_Instruction, context.temp_allocator)
	vector_instructions_find(listing, kernel_vector_procedures[:], &found)
	testing.expect_value(t, len(found), 13) // All but the last line.
	if len(found) > 0 {
		testing.expect_value(t, found[0].procedure, "kernel::thread_create")
		testing.expect_value(t, found[0].instruction, "movups	%xmm0, (%rax)")
	}
}

@(test)
a_name_that_only_starts_like_an_allowed_procedure_is_refused :: proc(t: ^testing.T) {
	listing := `
0000000000026000 <extended_state_saved_elsewhere>:
   26000:      	movups	%xmm0, (%rax)
`
	found := make([dynamic]Vector_Instruction, context.temp_allocator)
	vector_instructions_find(listing, kernel_vector_procedures[:], &found)
	testing.expect_value(t, len(found), 1)
}

@(test)
an_instruction_before_any_procedure_name_is_refused :: proc(t: ^testing.T) {
	listing := `
   26000:      	pxor	%xmm0, %xmm0
`
	found := make([dynamic]Vector_Instruction, context.temp_allocator)
	vector_instructions_find(listing, kernel_vector_procedures[:], &found)
	testing.expect_value(t, len(found), 1)
}

@(test)
general_registers_that_look_like_vector_names_pass :: proc(t: ^testing.T) {
	// %rsp, %esi, %spl and a prefix "lock": no vector register.
	testing.expect(t, !instruction_uses_vector_registers("lock\t\tcmpxchgq\t%rsi, (%rsp)"))
	testing.expect(t, !instruction_uses_vector_registers("movb\t%sil, %spl"))
	testing.expect(t, !instruction_uses_vector_registers("verw\t%ax"))
	testing.expect(t, instruction_uses_vector_registers("kmovq\t%k7, %rax"))
	testing.expect(t, instruction_uses_vector_registers("rep\t\tvmovdqu\t%ymm0, (%rax)"))
}
