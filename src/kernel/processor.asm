; The code of the processor that owns the stack or the frame, and so
; cannot be an instruction template of Odin: the entries of the kernel, the
; return to a program, the stubs of the interrupts, the save and the restore
; of the extended state, the load of the segment table (a far return), the
; switch of the stack, the start code of the other processors, and the two
; procedures with hlt, which the compiler takes as an end of the flow. The
; other instructions of the kernel are templates in src/kernel/instructions.odin
; (docs/ARCHITECTURE.md, "The instructions of the kernel"). System V
; convention.
bits 64
default rel

extern kernel_interrupt

KERNEL_ENTER_VECTOR equ 128
STUB_COUNT equ 80

section .text

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

; The frame: 15 registers, the vector, the error code, then what the
; processor pushed. src/kernel/processor.odin has the same layout (Frame).
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
; processor (Processor in src/kernel/processor.odin). In a program, it holds
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
; The gs base at an interrupt, by where it came from (docs/ARCHITECTURE.md,
; "The windows of the entry and of the return"):
; - from a program (cs & 3 != 0): the base of the program; swapgs gives the
;   kernel its own.
; - from the kernel at kernel_enter, before its swapgs: the base of the
;   program. Interrupts are off there (the mask of syscall), so only an
;   exception with a stack of its own arrives there: a debug trap that the
;   processor held over the syscall (mov ss or pop ss before it, or the trap
;   flag on some processors), an NMI or a machine check.
; - from the kernel after that swapgs and before the switch of the stack
;   (label kernel_enter_on_kernel_stack): the base of the kernel, with the
;   stack pointer of the program; the same three can arrive.
; - from the kernel between the swapgs of resume and its iretq (labels
;   resume_with_program_gs to resume_return, both included): the base of
;   the program. Interrupts are off there, so only a fault of the iretq
;   itself (rip resume_return, vector 11, 12 or 13: the processor refused
;   the frame; kernel_interrupt makes it a fault of the thread), an NMI or a
;   machine check arrive there.
; - from the kernel at a stub of an interrupt from a program, before the
;   swapgs of .from_program below: the base of the program. An NMI or a
;   machine check arrives there, and a debug trap that the processor held
;   over the instruction that entered the gate: mov ss or pop ss, then int3,
;   int1 or any instruction that faults, with the trap flag set. The trap
;   then comes at the first instruction of the stub.
; - from the kernel anywhere else: the base of the kernel.
;
; So the stub decides:
; - A debug trap from the kernel is always a trap of a program: one that
;   came late (each gate and the mask of syscall clear the trap flag), or a
;   data breakpoint of the current thread that a copy of the kernel from or
;   to the memory of its program reached (src/kernel/breakpoints.odin; the
;   kernel sets no breakpoint of its own, and a breakpoint is never at an
;   address of the kernel). It runs no compiled code, so it needs no gs:
;   the stub clears DR6 and returns with iretq to the instruction where it
;   came, which goes on with its own stack and gs (the entry of syscall, or
;   a stub, whose frame of the program is intact on the kernel stack). The
;   trap is dropped; the trap flag of the program is in that frame or in
;   r11, so the program gets its next trap after its next instruction.
;   One case differs: a held trap at the first instruction of stub_1, after
;   int1 of a program. The two debug exceptions use one interrupt stack, and
;   the second frame took the place of the first: the instruction address,
;   the stack pointer and the flags of the program are lost; its general
;   registers are not (no instruction ran between). No return is possible,
;   so the program, which asked for it, stops: the stub takes the kernel's
;   gs by the sign rule below, writes a frame of the program with the vector
;   VECTOR_DEBUG_FRAME_LOST and no address, and goes on as from a program.
; - The faults of the iretq of resume, by the saved instruction address
;   compared with the labels of that window: they come only there.
; - An NMI, a machine check and a double fault, which can come at any
;   instruction, by the sign of the base, as Linux does in paranoid_entry:
;   the base of the kernel is an address of the kernel half; the base of a
;   program is its thread record, below the kernel half, or 0 when the
;   program loaded its gs register (each descriptor has the base 0). A
;   program cannot write a base of the kernel half: the instruction
;   wrgsbase is off (CR4.FSGSBASE is clear, an assert of
;   src/kernel/processor.odin) and wrmsr is privileged. A double fault takes
;   that rule before the test of cs: the processor leaves its saved cs and
;   rip undefined.
;
; Each path that takes the swap here never comes back to the iretq of this
; stub: kernel_interrupt stops the machine for an NMI, a machine check and a
; double fault, ends the thread of a refused return, and stops the program
; of a lost debug frame. So no swap back is needed. The base of the kernel
; stays in MSR_KERNEL_GS_BASE through each window, so the swap gives it,
; whatever the program loaded.
;
; An NMI needs no guard against a second NMI on its stack: the processor
; holds the next NMI until the next iretq, and the handler of an NMI never
; runs one. It stops the machine, and a fault inside its report stops the
; machine too. A handler that returned would need that guard.
VECTOR_DEBUG_FRAME_LOST equ 255   ; VECTOR_DEBUG_FRAME_LOST in src/kernel/processor.odin.
interrupt_common:
	PUSH_REGISTERS
	cmp byte [user_access_guard], 0
	je .no_guard
	clac                         ; The interrupted code could be in user_copy, or a program set the flag.
.no_guard:
	mov rax, [rsp + 15 * 8]      ; The vector. rax, rcx and rdx are on the stack: free here.
	cmp rax, 8                   ; A double fault: its saved cs says nothing.
	je .gs_by_its_sign
	test byte [rsp + 18 * 8], 3  ; did the interrupt come from a program?
	jnz .from_program
	; From the kernel.
	cmp rax, 1                   ; A debug trap.
	je .debug_from_the_kernel
	cmp rax, 2                   ; A non-maskable interrupt.
	je .gs_by_its_sign
	cmp rax, 18                  ; A machine check.
	je .gs_by_its_sign
	mov rax, [rsp + 17 * 8]      ; The instruction address.
	lea rcx, [rel kernel_enter]
	cmp rax, rcx
	jb .not_in_entry
	lea rcx, [rel kernel_enter_on_kernel_stack]
	cmp rax, rcx
	jb .gs_by_its_sign           ; Nothing else can come there; at kernel_enter the gs is the program's: the sign rule decides.
.not_in_entry:
	lea rcx, [rel resume_with_program_gs]
	cmp rax, rcx
	jb interrupt_call
	lea rcx, [rel resume_return]
	cmp rax, rcx
	ja interrupt_call
	swapgs                       ; Between the swapgs of resume and its iretq: the kernel's gs back.
	jmp interrupt_call
.debug_from_the_kernel:
	mov eax, 0xFFFF0FF0          ; DR6 with no status (DR6_CLEAR in src/kernel/processor.odin).
	mov dr6, rax
	lea rcx, [rel stub_1]
	cmp [rsp + 17 * 8], rcx
	je .debug_frame_lost
	POP_REGISTERS
	add rsp, 16
	iretq                        ; Back where the trap came, on the stack and the gs that it had.
.debug_frame_lost:
	mov ecx, 0xC0000101          ; MSR_GS_BASE
	rdmsr
	test edx, edx
	js .debug_frame_written
	swapgs
.debug_frame_written:
	; The frame of a program with no instruction address and no stack
	; address: the kernel writes no frame that a return could take.
	mov qword [rsp + 15 * 8], VECTOR_DEBUG_FRAME_LOST
	mov qword [rsp + 16 * 8], 0  ; The error code.
	mov qword [rsp + 17 * 8], 0  ; rip
	mov qword [rsp + 18 * 8], 0x23 ; cs: user code
	mov qword [rsp + 19 * 8], 0x202 ; rflags: interrupts on
	mov qword [rsp + 20 * 8], 0  ; rsp
	mov qword [rsp + 21 * 8], 0x1B ; ss: user data
	jmp .move_to_the_kernel_stack
.gs_by_its_sign:
	mov ecx, 0xC0000101          ; MSR_GS_BASE
	rdmsr                        ; edx: bits 32 to 63 of the base.
	test edx, edx
	js interrupt_call            ; Bit 63 set: an address of the kernel half, the kernel's base.
	swapgs
	jmp interrupt_call
.from_program:
	swapgs
	; A debug trap arrives on its own stack also from a program. The kernel
	; can then switch to another thread, wait, and reuse that stack for the
	; next trap: so its frame moves to the top of the kernel stack, where
	; each entry from a program puts it, and the stack is free again. An NMI
	; and a machine check stay on their stacks: they stop the machine.
	cmp qword [rsp + 15 * 8], 1
	jne interrupt_from_program
.move_to_the_kernel_stack:
	mov rax, [gs:abs 0]
	sub rax, 22 * 8
	mov rsi, rsp
	mov rdi, rax
	mov ecx, 22
	cld
	rep movsq
	mov rsp, rax
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
; as an interrupt. interrupt_common knows the three instructions before
; kernel_enter_on_kernel_stack by their addresses: no instruction goes in
; between without a change of its windows.
global kernel_enter
global kernel_enter_on_kernel_stack
kernel_enter:
	swapgs
	mov [gs:abs 8], rsp
	mov rsp, [gs:abs 0]
kernel_enter_on_kernel_stack:
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
; The copy of 176 bytes is 11 pairs of moves of 8 bytes in general
; registers: the kernel has no vector instruction, so no moves of 16 bytes.
; rep movsq was measured slower here: it has a start cost of some tens of
; cycles for a short count (docs/ARCHITECTURE.md, "The return to a
; program", has the numbers).

global resume
resume:                          ; (frame: ^Frame) -> !: run a program
	mov rsi, rdi                 ; the frame of the thread
	mov rsp, [gs:abs 0]          ; the top of the kernel stack (gs: the kernel's)
	sub rsp, 22 * 8
	mov rdi, rsp
%assign pair 0
%rep 11
	mov rax, [rsi + pair * 16]
	mov rdx, [rsi + pair * 16 + 8]
	mov [rdi + pair * 16], rax
	mov [rdi + pair * 16 + 8], rdx
%assign pair pair + 1
%endrep
	swapgs                       ; From here to the iretq, gs is the program's.
global resume_with_program_gs
resume_with_program_gs:
	; The data selectors ds, es, fs and gs are not in the frame of a
	; thread: a value that one program loads would stay for the next
	; program on this processor, a channel of a few bits between them. So
	; each return gives them the null selector, which a program also gets
	; at its start. The load costs a write of the gs base, so it runs only
	; when one of them is not null: at the first return of a processor
	; (its kernel loaded ds and es), and after a program loaded one.
	mov ax, ds
	mov cx, es
	or ax, cx
	mov cx, fs
	or ax, cx
	mov cx, gs
	or ax, cx
	jz .selectors_null
	; The load of gs writes its base (to 0, or not at all on some
	; processors): the base of the program is read first and written back.
	; The fs base is 0 for every thread: the kernel writes no other.
	mov ecx, 0xC0000101          ; MSR_GS_BASE: here, the base of the program.
	rdmsr
	xor esi, esi
	mov ds, si
	mov es, si
	mov fs, si
	mov gs, si
	wrmsr
.selectors_null:
	POP_REGISTERS
	add rsp, 16                  ; The vector and the error code.
global resume_return
resume_return:
	iretq

global stack_switch
stack_switch:                    ; (top: u64, entry: rawptr) -> !: continue on another stack
	mov rsp, rdi
	xor ebp, ebp
	push 0                       ; a null return address: the entry does not return
	jmp rsi

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
; Ap_Parameters in src/kernel/apic.odin.
ap_table:     dd 0
ap_cr0:       dd 0
ap_efer:      dd 0
ap_mxcsr:     dd 0x1F80
ap_stack:     dq 0
ap_parameter: dq 0
ap_entry:     dq 0
global ap_start_end
ap_start_end:
