; The instructions of the cases of the fault ring and of the control of a
; thread (main.odin) whose exact bytes and addresses a case checks: the
; compiler gives no label inside a procedure, and no form of an
; instruction that the case names.
bits 64
default rel
section .text

; spin_and_publish(cells: ^Spin_Cells) -> !
; The entry of a thread: it loops for ever, and at each turn writes r12 at
; cells.value and adds 1 to cells.count. It makes no kernel entry and uses
; no stack, so a stop finds its instruction address between
; spin_loop_start and spin_loop_end, and a write of r12 shows in
; cells.value.
global spin_and_publish
global spin_loop_start
global spin_loop_end
spin_and_publish:
	xor r12d, r12d
spin_loop_start:
	mov [rdi + 8], r12
	lock inc qword [rdi]
	pause
	jmp spin_loop_start
spin_loop_end:
	int3                         ; Never executed: the end of the loop for the check.

; divide_and_skip() -> u64
; Divides 1000 by 0 with div rcx: a divide error at divide_instruction. A
; handler that adds the length of the div (divide_instruction_end -
; divide_instruction) to the instruction address lets it go on; the result
; is rax, which the handler can write too.
global divide_and_skip
global divide_instruction
global divide_instruction_end
divide_and_skip:
	mov eax, 1000
	xor edx, edx
	xor ecx, ecx
divide_instruction:
	div rcx
divide_instruction_end:
	ret

; two_byte_breakpoint(): int 3 in its form of two bytes (CD 03), not int3
; (CC). A breakpoint whose trap address is two_byte_breakpoint_instruction
; + 2.
global two_byte_breakpoint
global two_byte_breakpoint_instruction
two_byte_breakpoint:
two_byte_breakpoint_instruction:
	db 0xCD, 0x03
	ret

; interrupt_fourteen(): int 14 (CD 0E). The gate of vector 14 has the
; privilege level 0: a protection fault at the instruction, with the error
; code (14 << 3) | 2, and never a page fault. A handler skips its two bytes.
global interrupt_fourteen
global interrupt_fourteen_instruction
interrupt_fourteen:
interrupt_fourteen_instruction:
	db 0xCD, 0x0E
	ret

; icebp(): int1 (the byte F1), a debug trap at icebp_instruction + 1.
global icebp
global icebp_instruction
icebp:
icebp_instruction:
	db 0xF1
	ret

; single_step_six(): sets the trap flag with popfq. The flag acts from the
; instruction after popfq: a debug trap after each of the six instructions
; from single_step_first to the popfq that clears it, the last one at
; single_step_end.
global single_step_six
global single_step_first
global single_step_end
single_step_six:
	pushfq
	or qword [rsp], 0x100
	popfq
single_step_first:
	nop
	nop
	nop
	pushfq
	and qword [rsp], ~0x100
	popfq
single_step_end:
	ret

; mov_ss_then_syscall(): the trap flag set, then mov ss and a syscall as the
; next instruction. mov ss holds the trap of its instruction until the
; instruction after it: the syscall, whose mask clears the flag for the
; kernel. A trap that the processor gave at the first instruction of the
; kernel would stop the machine. Each trap must be a record of this
; program, between mov_ss_then_syscall and mov_ss_then_syscall_end. The
; syscall has rdi 0: a kernel entry with no wait.
global mov_ss_then_syscall
global mov_ss_then_syscall_end
mov_ss_then_syscall:
	push rbx
	mov bx, ss
	xor edi, edi
	pushfq
	or qword [rsp], 0x100
	popfq
	mov ss, bx
	syscall                      ; rax, rcx and r11 change.
	pushfq
	and qword [rsp], ~0x100
	popfq
mov_ss_then_syscall_end:
	pop rbx
	ret
