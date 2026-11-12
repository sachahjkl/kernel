; Processor instructions that Odin cannot write. System V convention.
bits 64
default rel

extern kernel_interrupt

KERNEL_ENTER_VECTOR equ 128
STUB_COUNT equ 80

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
;   gs:16  the address of the record
;
; An entry and a resume do not save or restore the x87, SSE and AVX
; registers of the program: the kernel has no instruction that changes
; them, so they stay live through the kernel. The scheduler saves them
; when the processor leaves the thread for another one (docs/ARCHITECTURE.md,
; "The extended state of the processor").
; The frame on the stack, from rsp: the 15 registers, then at 15 * 8 the
; vector, at 16 * 8 the error code, at 17 * 8 rip and at 18 * 8 cs.
;
; The gs base at an interrupt, by where it came from:
; - from a program (cs & 3 != 0): the base of the program; swapgs gives the
;   kernel its own.
; - from the kernel, at any instruction but the iretq of resume: the base of
;   the kernel already.
; - from the kernel between the swapgs of resume and its iretq (the 15
;   pops, the add and the iretq): the base is the one of the program.
;   Interrupts are off there, so only these arrive there:
;   - a fault of the iretq itself (rip resume_return, vector 11, 12 or 13:
;     the processor refused the frame). It gets swapgs here, and
;     kernel_interrupt makes it a fault of the thread
;     (return_refused_by_the_processor).
;   - an NMI or a machine check (vector 2 or 18), at any of these
;     instructions. It gets no swapgs. kernel_interrupt takes the path of a
;     fault of the kernel and stops the machine; that report reads nothing
;     through gs, so it arrives. A program cannot cause either: the kernel
;     sends no NMI, and a machine check is a fault of the hardware.
interrupt_common:
	PUSH_REGISTERS
	cmp byte [user_access_guard], 0
	je .no_guard
	clac                         ; The interrupted code could be in user_copy, or a program set the flag.
.no_guard:
	test byte [rsp + 18 * 8], 3  ; did the interrupt come from a program?
	jnz .from_program
	lea rax, [rel resume_return] ; rax is on the stack: free here.
	cmp [rsp + 17 * 8], rax
	jne interrupt_call
	mov rax, [rsp + 15 * 8]      ; the vector
	cmp rax, 11
	jb interrupt_call
	cmp rax, 13
	ja interrupt_call
	swapgs                       ; A fault of the iretq of resume: the kernel's gs back.
	jmp interrupt_call
.from_program:
	swapgs
interrupt_from_program:
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

; resume returns to a program from a copy of its frame at the top of the
; kernel stack of this processor, not from the frame of the thread in the
; thread table: if the processor refuses the iretq, it pushes the frame of
; its fault below rsp, on the stack where rsp is. From the frame of the
; thread, that push would write over the thread table; from the top of the
; kernel stack, it writes over the part of the copy that the pops already
; read, and below it, where nothing lives: a kernel entry starts at the top
; of the stack and never continues an earlier one. The top 22 * 8 bytes of
; the stack are where each entry from a program put its frame.
;
; Two forms of the copy of 176 bytes, chosen by measure (the kernel entries
; of the program locks in one second): 11 pairs of moves of 8 bytes in
; general registers (RESUME_COPY_WITH_REP_MOVSQ 0), or rep movsq (1). The
; kernel has no vector instruction, so no moves of 16 bytes. rep movsq has a
; start cost of some tens of cycles for a short count; the 44 moves have
; none, and with two loads and two stores in a cycle they take about 22
; cycles. The direction flag is clear in the kernel (syscall clears it
; through MSR_SFMASK, each interrupt runs cld), so rep movsq goes up.
%define RESUME_COPY_WITH_REP_MOVSQ 0

global resume
resume:                          ; (frame: ^Frame) -> !: run a program
	mov rsi, rdi                 ; the frame of the thread
	mov rsp, [gs:abs 0]          ; the top of the kernel stack (gs: the kernel's)
	sub rsp, 22 * 8
	mov rdi, rsp
%if RESUME_COPY_WITH_REP_MOVSQ
	mov ecx, 22
	rep movsq
%else
%assign pair 0
%rep 11
	mov rax, [rsi + pair * 16]
	mov rdx, [rsi + pair * 16 + 8]
	mov [rdi + pair * 16], rax
	mov [rdi + pair * 16 + 8], rdx
%assign pair pair + 1
%endrep
%endif
	swapgs                       ; From here to the iretq, gs is the program's.
	POP_REGISTERS
	add rsp, 16                  ; The vector and the error code.
global resume_return
resume_return:
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
	mov rax, [gs:abs 16]
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

global extended_control_register_write
extended_control_register_write: ; (register: u32, value: u64): xsetbv
	mov ecx, edi
	mov eax, esi
	mov rdx, rsi
	shr rdx, 32
	xsetbv
	ret

; The save and the restore of the extended state of a thread: the
; scheduler calls them when a processor leaves a thread for another one,
; and the first processor proves the start state with them at boot. These
; three procedures are the only code of the kernel that names an x87, SSE
; or AVX register (`kerneltool` refuses any other: vector_check.odin). Each
; one ends with a label "<name>_end": the check allows the instructions of
; a procedure only up to that label, and refuses a kernel where the label
; does not follow the procedure.
; form: Extended_State_Form, 0 for fxsave64 and fxrstor64, 1 for
; xsaveopt64 and xrstor64, with edx:eax all ones: every component of XCR0.
global extended_state_save
extended_state_save:             ; (area: ^Extended_State_Area, form: u8)
	test sil, sil
	jz .with_fxsave
	mov eax, -1
	mov edx, -1
	xsaveopt64 [rdi]
	ret
.with_fxsave:
	fxsave64 [rdi]
	ret
extended_state_save_end:                         ; The end of the procedure for the check of the build: never executed.
	int3

global extended_state_restore
extended_state_restore:          ; (area: ^Extended_State_Area, form: u8)
	test sil, sil
	jz .with_fxrstor
	mov eax, -1
	mov edx, -1
	xrstor64 [rdi]
	ret
.with_fxrstor:
	fxrstor64 [rdi]
	ret
extended_state_restore_end:                         ; The end of the procedure for the check of the build: never executed.
	int3

; The restore, then the registers as the processor took them from the area:
; the x87 control word, MXCSR, the low 8 bytes of xmm0 and, with with_avx,
; bytes 16 to 23 of ymm0. No compiled code runs between the two.
global extended_state_restore_and_read
extended_state_restore_and_read: ; (area: ^Extended_State_Area, read: ^[4]u64, with_avx: bool, form: u8)
	mov r8, rdi
	mov r9, rsi
	movzx r10d, dl
	test cl, cl
	jz .with_fxrstor
	mov eax, -1
	mov edx, -1
	xrstor64 [r8]
	jmp .read
.with_fxrstor:
	fxrstor64 [r8]
.read:
	fnstcw [r9]
	stmxcsr [r9 + 8]
	movq [r9 + 16], xmm0
	test r10d, r10d
	jz .done
	vextractf128 xmm1, ymm0, 1
	movq [r9 + 24], xmm1
	vzeroupper
.done:
	ret
extended_state_restore_and_read_end:                         ; The end of the procedure for the check of the build: never executed.
	int3

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
