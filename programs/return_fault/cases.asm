; The hostile cases of the return to a program (main.odin): each one gives
; the kernel a thread whose return the processor would refuse. Each runs in
; a child program, which the kernel stops or which stops by itself.
bits 64
default rel
section .text

; jump_to_the_last_instruction(address: rawptr, with_avx: bool) -> !
; With with_avx, the high halves of ymm0 to ymm15 get all ones: the thread
; holds AVX values when the kernel stops it. Then it jumps to address, the
; syscall in the last two bytes below the half of a program, with rdi 0 (a
; kernel entry with no wait). The address after that syscall is 2^47: not
; canonical.
global jump_to_the_last_instruction
jump_to_the_last_instruction:
	test sil, sil
	jz .jump
%assign n 0
%rep 16
	vcmpps ymm %+ n, ymm %+ n, ymm %+ n, 0x0F ; The predicate "true": all ones.
%assign n n + 1
%endrep
.jump:
	mov rax, rdi
	xor edi, edi
	jmp rax

; spin_with_a_stack_that_is_not_canonical() -> !
; A program can hold any value in rsp. This one holds an address that is
; not canonical, uses no stack, and waits for the timer: the kernel entry
; of the timer saves that rsp in the frame of the thread.
global spin_with_a_stack_that_is_not_canonical
spin_with_a_stack_that_is_not_canonical:
	mov rax, 0x8000000000000000
	mov rsp, rax
.spin:
	pause
	jmp .spin

; syscall_with_nested_task(before: ^u64) -> u64
; Sets the flag nested task (bit 14) with popfq, writes the flags at before,
; makes one kernel entry with no wait, and gives the flags after it. Then it
; clears the flag again for the compiled code. A kernel that kept the flag
; of the program would fault at its iretq.
global syscall_with_nested_task
syscall_with_nested_task:
	pushfq
	or qword [rsp], 0x4000
	popfq
	pushfq
	pop rax
	mov [rdi], rax
	xor edi, edi
	syscall                      ; rax, rcx and r11 change.
	pushfq
	pop rax
	push rax
	and qword [rsp], ~0x4000
	popfq
	ret
