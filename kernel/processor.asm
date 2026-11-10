; Processor instructions that Odin cannot write. System V convention.
bits 64
default rel

extern kernel_interrupt

KERNEL_ENTER_VECTOR equ 128
STUB_COUNT equ 64

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

; In the kernel, the gs register holds the address of the record of the
; processor (Processor in kernel/processor.odin). In a program, it holds
; the address of the thread record. The swapgs instruction exchanges the two.
;   gs:0   the top of the kernel stack of the processor
;   gs:8   the stack of the program, during a kernel entry
;   gs:16  the area where the next entry saves the floating-point state
;   gs:24  the address of the record
interrupt_common:
	PUSH_REGISTERS
	cmp byte [user_access_guard], 0
	je .no_guard
	clac                         ; The interrupted code could be in user_copy, or a program set the flag.
.no_guard:
	test byte [rsp + 15 * 8 + 24], 3 ; did the interrupt come from a program?
	jz interrupt_call
	swapgs
interrupt_from_program:
	mov rax, [gs:abs 16]
	fxsave64 [rax]
interrupt_call:
	mov rdi, rsp
	cld
	call kernel_interrupt
	POP_REGISTERS                ; Only an interrupt of the kernel returns here.
	add rsp, 16
	iretq

; The one kernel entry point of programs: the syscall instruction.
; rcx holds the return address and r11 the flags. It builds the same frame
; as an interrupt.
global kernel_enter
kernel_enter:
	swapgs
	mov [gs:abs 8], rsp
	mov rsp, [gs:abs 0]
	push 0x1B                    ; ss: user data
	push qword [gs:abs 8]
	push r11                     ; flags
	push 0x23                    ; cs: user code
	push rcx                     ; return address
	push 0
	push KERNEL_ENTER_VECTOR
	PUSH_REGISTERS
	jmp interrupt_from_program

global resume
resume:                          ; (frame: ^Frame) -> !: run a program
	mov rsp, rdi
	mov rax, [gs:abs 16]
	fxrstor64 [rax]
	swapgs
	POP_REGISTERS
	add rsp, 16
	iretq

; user_copy(destination, source, count): the one place where the kernel
; uses the memory of a program at the addresses of the program. With the
; guard, the processor refuses such a use everywhere else.
global user_copy
user_copy:
	mov rcx, rdx
	cmp byte [user_access_guard], 0
	je .copy
	stac
	rep movsb
	clac
	ret
.copy:
	rep movsb
	ret

global stack_switch
stack_switch:                    ; (top: u64, entry: rawptr) -> !: continue on another stack
	mov rsp, rdi
	xor ebp, ebp
	push 0                       ; a null return address: the entry does not return
	jmp rsi

global processor_self
processor_self:                  ; () -> ^Processor
	mov rax, [gs:abs 24]
	ret

global cr0_read
cr0_read:
	mov rax, cr0
	ret

global cr4_read
cr4_read:
	mov rax, cr4
	ret

global cr4_write
cr4_write:
	mov cr4, rdi
	ret

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

global user_access_guard
user_access_guard: db 0          ; 1: the processors refuse the memory of programs to the kernel (SMAP)

align 8
global interrupt_stubs
interrupt_stubs:
%assign vector 0
%rep STUB_COUNT
	dq stub_ %+ vector
%assign vector vector + 1
%endrep

; The start code of a processor. The kernel copies it to the page AP_BASE
; of physical memory and fills the parameters at its end. A processor
; starts there in 16-bit mode, and goes to 64-bit mode with the page table
; and the registers of the first processor.
AP_BASE equ 0x8000
%define AP(label) (AP_BASE + label - ap_start_begin)

global ap_start_begin
ap_start_begin:
bits 16
	cli
	cld
	xor ax, ax
	mov ds, ax
	lgdt [AP(ap_descriptor)]
	mov eax, cr0
	or eax, 1
	mov cr0, eax
	jmp dword 0x08:AP(ap_32)
bits 32
ap_32:
	mov ax, 0x10
	mov ds, ax
	mov es, ax
	mov ss, ax
	mov eax, 0x620               ; 36-bit addresses, and the two bits of fxsave
	mov cr4, eax
	mov eax, [AP(ap_table)]
	mov cr3, eax
	mov ecx, 0xC0000080          ; EFER
	mov eax, [AP(ap_efer)]
	xor edx, edx
	wrmsr
	mov eax, [AP(ap_cr0)]
	mov cr0, eax
	jmp 0x18:AP(ap_64)
bits 64
ap_64:
	mov rsp, [abs AP(ap_stack)]
	mov rdi, [abs AP(ap_parameter)]
	mov rax, [abs AP(ap_entry)]
	fninit
	ldmxcsr [abs AP(ap_mxcsr)]
	xor ebp, ebp
	push 0                       ; a null return address: the entry does not return
	jmp rax

align 8
ap_segments:
	dq 0
	dq 0x00CF9A000000FFFF        ; 32-bit code
	dq 0x00CF92000000FFFF        ; data
	dq 0x00AF9A000000FFFF        ; 64-bit code
ap_descriptor:
	dw 4 * 8 - 1
	dd AP(ap_segments)
align 8
; Ap_Parameters in kernel/apic.odin.
ap_table:     dd 0
ap_cr0:       dd 0
ap_efer:      dd 0
ap_mxcsr:     dd 0x1F80
ap_stack:     dq 0
ap_parameter: dq 0
ap_entry:     dq 0
global ap_start_end
ap_start_end:
