; The functions that the compiler calls to copy, move and fill memory:
; memcpy, memmove, memset. Odin gives them only with -no-crt, as loops of
; one byte, and memcpy and memmove with no optimization (optnone). The
; kernel tool builds every module and the kernel without -no-crt and links
; this file in each of them, and in the boot program (docs/FIRST_MILESTONE.md,
; the choices of the fast copy). One source, three forms:
;   (none)   memcpy, memmove, memset with the System V calling convention: the
;            modules and the kernel.
;   WIN64    the same names with the Microsoft x64 calling convention: the boot
;            program (UEFI).
;   HOST     runtime_copy, runtime_move, runtime_fill with the System V
;            convention, for the tests of the kernel tool on the host.
;
; The forms were chosen by measure (the compositor writes the table at its
; start). Under 16 bytes: general registers. 16 to 64 bytes: two or four
; moves of 16 bytes that overlap. Above: rep movsb from COPY_STRING to
; COPY_LARGE, rep stosb from FILL_STRING to FILL_LARGE, else a loop of 64
; bytes in four registers of 16 bytes. Each function reads all its source
; before it writes for 64 bytes or less, so the small forms also move.
;
; The registers: rax, rcx, rdx, rsi, rdi, r8 to r10, xmm0 to xmm4. The
; kernel saves the registers of a program at each entry (fxsave), and runs
; its own code with the interrupts off, so the kernel can use xmm0 to xmm4.
; No AVX: fxsave does not save the upper halves of the ymm registers.
; The direction flag is clear at each call (docs/MODULE_CONTRACT.md, rule
; of the direction flag): rep movsb and rep stosb go up.
bits 64
default rel

; The sizes where the form changes. A measure can give others with -D.
%ifndef COPY_STRING
%define COPY_STRING 2048         ; From this size, rep movsb is faster than the loop...
%endif
%ifndef COPY_LARGE
%define COPY_LARGE 1048576       ; ...up to this size.
%endif
%ifndef FILL_STRING
%define FILL_STRING 4096         ; From this size, rep stosb is faster than the loop...
%endif
%ifndef FILL_LARGE
%define FILL_LARGE 1048576       ; ...up to this size.
%endif

section .text

; copy_core: rdi the destination, rsi the source, rdx the count. Gives rdi
; in rax. The two parts must not overlap, except for 64 bytes or less.
copy_core:
	mov rax, rdi
	cmp rdx, 16
	ja .over16
	cmp edx, 8
	jae .from8
	cmp edx, 4
	jae .from4
	cmp edx, 1
	ja .from2
	jb .done
	movzx ecx, byte [rsi]
	mov [rdi], cl
.done:
	ret
.from2:
	movzx ecx, word [rsi]
	movzx r8d, word [rsi + rdx - 2]
	mov [rdi], cx
	mov [rdi + rdx - 2], r8w
	ret
.from4:
	mov ecx, [rsi]
	mov r8d, [rsi + rdx - 4]
	mov [rdi], ecx
	mov [rdi + rdx - 4], r8d
	ret
.from8:
	mov rcx, [rsi]
	mov r8, [rsi + rdx - 8]
	mov [rdi], rcx
	mov [rdi + rdx - 8], r8
	ret
.over16:
	cmp rdx, 64
	ja .over64
	movdqu xmm0, [rsi]
	movdqu xmm1, [rsi + rdx - 16]
	cmp edx, 32
	jbe .store2
	movdqu xmm2, [rsi + 16]
	movdqu xmm3, [rsi + rdx - 32]
	movdqu [rdi + 16], xmm2
	movdqu [rdi + rdx - 32], xmm3
.store2:
	movdqu [rdi], xmm0
	movdqu [rdi + rdx - 16], xmm1
	ret
.over64:
	cmp rdx, COPY_STRING
	jb .loop_start
	cmp rdx, COPY_LARGE
	jae .loop_start
	mov rcx, rdx
	rep movsb
	ret
.loop_start:
	lea r9, [rsi + rdx - 64]     ; The last 64 bytes, copied after the loop.
	lea r10, [rdi + rdx - 64]
.loop:
	movdqu xmm0, [rsi]
	movdqu xmm1, [rsi + 16]
	movdqu xmm2, [rsi + 32]
	movdqu xmm3, [rsi + 48]
	movdqu [rdi], xmm0
	movdqu [rdi + 16], xmm1
	movdqu [rdi + 32], xmm2
	movdqu [rdi + 48], xmm3
	add rsi, 64
	add rdi, 64
	sub rdx, 64
	cmp rdx, 64
	ja .loop
	movdqu xmm0, [r9]
	movdqu xmm1, [r9 + 16]
	movdqu xmm2, [r9 + 32]
	movdqu xmm3, [r9 + 48]
	movdqu [r10], xmm0
	movdqu [r10 + 16], xmm1
	movdqu [r10 + 32], xmm2
	movdqu [r10 + 48], xmm3
	ret

; move_core: as copy_core, and the two parts can overlap.
move_core:
	cmp rdx, 64
	jbe copy_core                ; Reads all, then writes.
	mov rcx, rdi
	sub rcx, rsi                 ; The destination after the source, in the count: copy down.
	cmp rcx, rdx
	jb .down
	mov rcx, rsi
	sub rcx, rdi                 ; The destination before the source, in the count: rep movsb goes up byte after byte.
	cmp rcx, rdx
	jae copy_core
	mov rax, rdi
	mov rcx, rdx
	rep movsb
	ret
.down:
	; Blocks of 16 bytes from the end. A block is read before the write
	; that can reach it. The first 16 bytes are read first and written last.
	mov rax, rdi
	movdqu xmm4, [rsi]
.loop:
	sub rdx, 16
	movdqu xmm0, [rsi + rdx]
	movdqu [rdi + rdx], xmm0
	cmp rdx, 16
	ja .loop
	movdqu [rdi], xmm4
	ret

; fill_core: rdi the destination, esi the byte, rdx the count. Gives rdi in rax.
fill_core:
	mov r9, rdi
	movzx ecx, sil
	mov r8, 0x0101010101010101
	imul rcx, r8                 ; The byte in each byte of rcx.
	cmp rdx, 16
	ja .over16
	cmp edx, 8
	jae .from8
	cmp edx, 4
	jae .from4
	cmp edx, 1
	ja .from2
	jb .done
	mov [rdi], cl
	jmp .done
.from2:
	mov [rdi], cx
	mov [rdi + rdx - 2], cx
	jmp .done
.from4:
	mov [rdi], ecx
	mov [rdi + rdx - 4], ecx
	jmp .done
.from8:
	mov [rdi], rcx
	mov [rdi + rdx - 8], rcx
	jmp .done
.over16:
	movq xmm0, rcx
	punpcklqdq xmm0, xmm0
	cmp rdx, 64
	ja .over64
	movdqu [rdi], xmm0
	movdqu [rdi + rdx - 16], xmm0
	cmp edx, 32
	jbe .done
	movdqu [rdi + 16], xmm0
	movdqu [rdi + rdx - 32], xmm0
	jmp .done
.over64:
	cmp rdx, FILL_STRING
	jb .loop_start
	cmp rdx, FILL_LARGE
	jae .loop_start
	mov eax, ecx
	mov rcx, rdx
	rep stosb
	jmp .done
.loop_start:
	lea r10, [rdi + rdx - 64]
.loop:
	movdqu [rdi], xmm0
	movdqu [rdi + 16], xmm0
	movdqu [rdi + 32], xmm0
	movdqu [rdi + 48], xmm0
	add rdi, 64
	sub rdx, 64
	cmp rdx, 64
	ja .loop
	movdqu [r10], xmm0
	movdqu [r10 + 16], xmm0
	movdqu [r10 + 32], xmm0
	movdqu [r10 + 48], xmm0
.done:
	mov rax, r9
	ret

%ifdef HOST

global runtime_copy
runtime_copy equ copy_core
global runtime_move
runtime_move equ move_core
global runtime_fill
runtime_fill equ fill_core
section .note.GNU-stack noalloc noexec nowrite progbits

%elifdef WIN64

; rcx, rdx, r8 to rdi, rsi, rdx. rdi and rsi belong to the caller.
global memcpy
memcpy:
	push rdi
	push rsi
	mov rdi, rcx
	mov rsi, rdx
	mov rdx, r8
	call copy_core
	pop rsi
	pop rdi
	ret

global memmove
memmove:
	push rdi
	push rsi
	mov rdi, rcx
	mov rsi, rdx
	mov rdx, r8
	call move_core
	pop rsi
	pop rdi
	ret

global memset
memset:
	push rdi
	push rsi
	mov rdi, rcx
	mov esi, edx
	mov rdx, r8
	call fill_core
	pop rsi
	pop rdi
	ret

%else

global memcpy
memcpy equ copy_core
global memmove
memmove equ move_core
global memset
memset equ fill_core

%endif
