; The registers of the extended state, held across kernel entries. Odin
; code between two passes uses the xmm registers itself, so the load, the
; spin, the kernel entries and the store of one pass are one routine that
; calls nothing. Register_Image in main.odin has this layout.
bits 64
default rel

IMAGE_VECTORS     equ 0              ; 32 registers of 64 bytes: register n at n * 64
IMAGE_OPMASKS     equ 2048           ; 8 values of 8 bytes: k0 to k7 (16 bits used)
IMAGE_X87         equ 2112           ; 8 integers of 8 bytes, in the order of the loads
IMAGE_X87_CONTROL equ 2176           ; 2 bytes
IMAGE_MXCSR       equ 2180           ; 4 bytes

LEVEL_SSE         equ 0              ; xmm0 to xmm15
LEVEL_AVX         equ 1              ; ymm0 to ymm15
LEVEL_AVX_512     equ 2              ; zmm0 to zmm31 and k0 to k7

section .text

%macro LOAD_VECTORS 1                ; %1: the base register of the image
	cmp r13, LEVEL_AVX_512
	je %%zmm
	cmp r13, LEVEL_AVX
	je %%ymm
%assign n 0
%rep 16
	movdqu xmm %+ n, [%1 + IMAGE_VECTORS + n * 64]
%assign n n + 1
%endrep
	jmp %%done
%%ymm:
%assign n 0
%rep 16
	vmovdqu ymm %+ n, [%1 + IMAGE_VECTORS + n * 64]
%assign n n + 1
%endrep
	jmp %%done
%%zmm:
%assign n 0
%rep 32
	vmovdqu64 zmm %+ n, [%1 + IMAGE_VECTORS + n * 64]
%assign n n + 1
%endrep
%assign n 0
%rep 8
	kmovw k %+ n, [%1 + IMAGE_OPMASKS + n * 8]
%assign n n + 1
%endrep
%%done:
%endmacro

%macro STORE_VECTORS 1               ; %1: the base register of the image
	cmp r13, LEVEL_AVX_512
	je %%zmm
	cmp r13, LEVEL_AVX
	je %%ymm
%assign n 0
%rep 16
	movdqu [%1 + IMAGE_VECTORS + n * 64], xmm %+ n
%assign n n + 1
%endrep
	jmp %%done
%%ymm:
%assign n 0
%rep 16
	vmovdqu [%1 + IMAGE_VECTORS + n * 64], ymm %+ n
%assign n n + 1
%endrep
	jmp %%done
%%zmm:
%assign n 0
%rep 32
	vmovdqu64 [%1 + IMAGE_VECTORS + n * 64], zmm %+ n
%assign n n + 1
%endrep
%assign n 0
%rep 8
	kmovw [%1 + IMAGE_OPMASKS + n * 8], k %+ n
%assign n n + 1
%endrep
%%done:
%endmacro

; The registers that Odin code expects after a pass: the upper halves
; zero, the x87 stack empty, the default controls.
%macro LEAVE_CLEAN 0
	cmp r13, LEVEL_SSE
	je %%no_upper
	vzeroupper
%%no_upper:
	fninit
	push 0x1F80                  ; MXCSR: every exception masked, round to nearest
	ldmxcsr [rsp]
	add rsp, 8
%endmacro

%macro SAVE_CALLEE_REGISTERS 0
	push rbx
	push rbp
	push r12
	push r13
	push r14
	push r15
%endmacro

%macro RESTORE_CALLEE_REGISTERS 0
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbp
	pop rbx
%endmacro

; registers_hold(expected, seen: ^Register_Image, level, rounds, spins: u64)
; Loads every register of the level, the x87 stack, the x87 control word
; and MXCSR from expected. Then, for each round: a spin of `spins` loops
; (the timer interrupts it), then one kernel entry: on an even round an
; entry that returns at once, on an odd round a wait for a deadline that
; has passed, so the thread leaves its processor until the next tick and
; can come back on another one. Then it stores every register in seen.
global registers_hold
registers_hold:
	SAVE_CALLEE_REGISTERS
	mov rbx, rdi                 ; expected
	mov r12, rsi                 ; seen
	mov r13, rdx                 ; level
	mov r14, rcx                 ; rounds
	mov r15, r8                  ; spins
	fninit
	fldcw [rbx + IMAGE_X87_CONTROL]
%assign n 0
%rep 8
	fild qword [rbx + IMAGE_X87 + n * 8]
%assign n n + 1
%endrep
	ldmxcsr [rbx + IMAGE_MXCSR]
	LOAD_VECTORS rbx
	xor ebp, ebp                 ; the round
.round:
	cmp rbp, r14
	je .end
	mov rcx, r15
.spin:
	dec rcx
	jnz .spin
	mov rdi, rbp
	and edi, 1                   ; 0: no wait; 1: the deadline of the millisecond 1 of the machine, long passed
	syscall                      ; The kernel gives the time in rax; rcx and r11 change. No other register.
	inc rbp
	jmp .round
.end:
	STORE_VECTORS r12
	fnstcw [r12 + IMAGE_X87_CONTROL]
	stmxcsr [r12 + IMAGE_MXCSR]
%assign n 7
%rep 8
	fistp qword [r12 + IMAGE_X87 + n * 8] ; The last load is the top of the stack.
%assign n n - 1
%endrep
	LEAVE_CLEAN
	RESTORE_CALLEE_REGISTERS
	ret

; registers_store(seen: ^Register_Image, level: u64)
; Stores the registers of the level, the x87 control word and MXCSR as they
; are: at the start of a thread, the start state of the kernel. The x87
; stack is not stored: it is empty.
global registers_store
registers_store:
	SAVE_CALLEE_REGISTERS
	mov r12, rdi
	mov r13, rsi
	STORE_VECTORS r12
	fnstcw [r12 + IMAGE_X87_CONTROL]
	stmxcsr [r12 + IMAGE_MXCSR]
	RESTORE_CALLEE_REGISTERS
	ret

; registers_enter_repeatedly(expected: ^Register_Image, level, count: u64)
; Loads the registers of the level, so that they are in use, then makes
; `count` kernel entries that return at once: the measure of the cost of
; an entry with that state.
global registers_enter_repeatedly
registers_enter_repeatedly:
	SAVE_CALLEE_REGISTERS
	mov rbx, rdi
	mov r13, rsi
	mov r14, rdx
	LOAD_VECTORS rbx
.again:
	test r14, r14
	jz .end
	xor edi, edi
	syscall
	dec r14
	jmp .again
.end:
	LEAVE_CLEAN
	RESTORE_CALLEE_REGISTERS
	ret
