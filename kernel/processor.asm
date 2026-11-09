; Processor instructions that Odin cannot write. System V convention.
bits 64
default rel

extern kernel_interrupt
extern current_fpu_area
extern kernel_stack_top

KERNEL_ENTER_VECTOR equ 128
STUB_COUNT equ 48

section .text

global port_write_8
port_write_8:                    ; (port: u16, value: u8)
	mov edx, edi
	mov eax, esi
	out dx, al
	ret

global port_read_8
port_read_8:                     ; (port: u16) -> u8
	mov edx, edi
	xor eax, eax
	in al, dx
	ret

global processor_stop
processor_stop:                  ; () -> !
	cli
.again:
	hlt
	jmp .again

global idle_wait
idle_wait:                       ; (): wait for one interrupt
	sti
	hlt
	cli
	ret

global gdt_load
gdt_load:                        ; (descriptor: rawptr): load the table and all segment registers
	lgdt [rdi]
	mov ax, 0x10
	mov ds, ax
	mov es, ax
	mov ss, ax
	xor eax, eax
	mov fs, ax
	mov gs, ax
	pop rax
	push 0x08
	push rax
	retfq

global idt_load
idt_load:                        ; (descriptor: rawptr)
	lidt [rdi]
	ret

global task_load
task_load:                       ; (selector: u16)
	ltr di
	ret

global msr_write
msr_write:                       ; (index: u32, value: u64)
	mov ecx, edi
	mov eax, esi
	mov rdx, rsi
	shr rdx, 32
	wrmsr
	ret

global msr_read
msr_read:                        ; (index: u32) -> u64
	mov ecx, edi
	rdmsr
	shl rdx, 32
	or rax, rdx
	ret

global cr2_read
cr2_read:
	mov rax, cr2
	ret

global cr3_read
cr3_read:
	mov rax, cr3
	ret

global cr3_write
cr3_write:
	mov cr3, rdi
	ret

global page_flush
page_flush:                      ; (address)
	invlpg [rdi]
	ret

; The frame: 15 registers, the vector, the error code, then what the
; processor pushed. kernel/processor.odin has the same layout (Frame).
%macro PUSH_REGISTERS 0
	push rax
	push rcx
	push rdx
	push rbx
	push rbp
	push rsi
	push rdi
	push r8
	push r9
	push r10
	push r11
	push r12
	push r13
	push r14
	push r15
%endmacro

%macro POP_REGISTERS 0
	pop r15
	pop r14
	pop r13
	pop r12
	pop r11
	pop r10
	pop r9
	pop r8
	pop rdi
	pop rsi
	pop rbp
	pop rbx
	pop rdx
	pop rcx
	pop rax
%endmacro

interrupt_common:
	PUSH_REGISTERS
	test byte [rsp + 15 * 8 + 24], 3 ; did the interrupt come from a program?
	jz .call
	mov rax, [current_fpu_area]
	fxsave64 [rax]
.call:
	mov rdi, rsp
	cld
	call kernel_interrupt
	POP_REGISTERS
	add rsp, 16
	iretq

; The one kernel entry point of programs: the syscall instruction.
; rcx holds the return address and r11 the flags. It builds the same frame
; as an interrupt.
global kernel_enter
kernel_enter:
	mov [enter_user_stack], rsp
	mov rsp, [kernel_stack_top]
	push 0x1B                    ; ss: user data
	push qword [enter_user_stack]
	push r11                     ; flags
	push 0x23                    ; cs: user code
	push rcx                     ; return address
	push 0
	push KERNEL_ENTER_VECTOR
	jmp interrupt_common

global resume
resume:                          ; (frame: ^Frame) -> !: run a program
	mov rsp, rdi
	mov rax, [current_fpu_area]
	fxrstor64 [rax]
	POP_REGISTERS
	add rsp, 16
	iretq

%assign vector 0
%rep STUB_COUNT
stub_ %+ vector:
%if !(vector == 8 || (vector >= 10 && vector <= 14) || vector == 17 || vector == 21 || vector == 29 || vector == 30)
	push 0
%endif
	push vector
	jmp interrupt_common
%assign vector vector + 1
%endrep

section .data
enter_user_stack: dq 0

global interrupt_stubs
interrupt_stubs:
%assign vector 0
%rep STUB_COUNT
	dq stub_ %+ vector
%assign vector vector + 1
%endrep
