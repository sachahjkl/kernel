; The functions of the system that copy and fill memory:
;   copy_bytes_without_overlap (destination, source, count)
;   copy_bytes_with_overlap    (destination, source, count)
;   fill_bytes_with_value      (destination, value, count)
;   erase_secret_bytes         (destination, count)
;   erase_stack_below_the_caller ()
; Each gives the destination. The kernel tool links this file in every
; module, in the kernel and in the boot program, and builds them without
; -no-crt: with it, Odin gives its own functions, loops of one byte, two of
; them with no optimization (optnone).
;
; The compiler (LLVM) calls three functions with the names of the C library
; when it copies a record or fills memory: memcpy, memmove, memset. The part
; "Names that the compiler calls" at the end gives these names to the three
; functions above, and nothing else. Code of the system uses the long names.
;
; One source, three forms:
;   (none)   the System V calling convention: the modules and the kernel.
;   WIN64    the Microsoft x64 calling convention: the boot program (UEFI).
;   HOST     the System V convention, the long names only, for the tests of
;            the kernel tool on the host (the host keeps its own memcpy).
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

; copy_bytes_without_overlap: rdi the destination, rsi the source, rdx the count. Gives rdi
; in rax. The two parts must not overlap, except for 64 bytes or less.
copy_bytes_without_overlap:
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

; copy_bytes_with_overlap: as copy_bytes_without_overlap, and the two parts can overlap.
copy_bytes_with_overlap:
	cmp rdx, 64
	jbe copy_bytes_without_overlap                ; Reads all, then writes.
	mov rcx, rdi
	sub rcx, rsi                 ; The destination after the source, in the count: copy down.
	cmp rcx, rdx
	jb .down
	mov rcx, rsi
	sub rcx, rdi                 ; The destination before the source, in the count: rep movsb goes up byte after byte.
	cmp rcx, rdx
	jae copy_bytes_without_overlap
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

; fill_bytes_with_value: rdi the destination, esi the byte, rdx the count. Gives rdi in rax.
fill_bytes_with_value:
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

; erase_secret_bytes: rdi the destination, rsi the count. Writes 0 in each
; byte, and gives rdi in rax. The compiler cannot remove it: the code of a
; module calls it by its symbol, in an object that nasm made, and the
; modules link with no link-time optimization; so LLVM does not see the
; body, and must take the call as a read and a write of the memory that
; the pointer reaches. A store of zeros that the compiler emits itself
; (memset of a variable that is dead after it) can be removed: this one
; cannot. The loop of bytes is enough: a secret has some hundred bytes.
erase_secret_bytes:
	mov rax, rdi
	test rsi, rsi
	jz .done
.loop:
	mov byte [rdi], 0
	inc rdi
	dec rsi
	jnz .loop
.done:
	ret

; erase_stack_below_the_caller: no argument, no result. Writes 0 in the
; STACK_ERASE_SIZE bytes below the stack pointer of its caller: the frames of
; the procedures that the caller called and that returned, which can still
; hold a key, an expanded key or a hash state. A cryptographic export calls
; it after its work, and the random generator after a refill and a reseed.
;
; It writes from the top down, 8 bytes at a time: the first byte past the
; bottom of the stack of the thread is in the unmapped page under the
; stack, so the program stops there, before any byte of the mapping under
; that page (a ring, a region that another program shares) is written. A
; thread that calls the module cryptography or draws random bytes needs
; STACK_ERASE_SIZE of stack below its frame at the call, and its own frames:
; 24 KiB in all is the least (docs/CRYPTOGRAPHY.md, section 6); the threads
; of the system have 64 KiB (system.THREAD_STACK_PAGES) and the main thread
; 256 KiB. With less, the program stops at the guard page: no other memory
; is written.
;
; Why 16 KiB: the largest frames below an export of the module cryptography
; are its own copies (8160 bytes of HKDF output and 1024 bytes of info, or
; 4096 bytes of a message to sign) and the frames of the code of the origin
; under them: SHA-512 and HMAC states of some hundred bytes, the points of
; edwards25519 (160 bytes each, a few at once), the counter blocks of AES
; (ct64, 4 blocks of 16 bytes and the bitsliced state). A measure of the
; deepest frame chooses the size in the end.
;
; Writing below the stack pointer is safe here: the interrupts and the
; kernel entries of a program use the kernel stack, so nothing lives below
; the stack pointer of a program. No string instruction is used, so the
; direction flag is not changed.
%ifndef STACK_ERASE_SIZE
%define STACK_ERASE_SIZE 16384
%endif
erase_stack_below_the_caller:
	; At the entry, rsp points to the return address: each byte below it is
	; free. rdi goes from rsp - 8 down to rsp - STACK_ERASE_SIZE.
	lea rdi, [rsp - 8]
	lea rcx, [rsp - STACK_ERASE_SIZE]
	xor eax, eax
.erase:
	mov [rdi], rax
	sub rdi, 8
	cmp rdi, rcx
	jae .erase
	ret

global copy_bytes_without_overlap
global copy_bytes_with_overlap
global fill_bytes_with_value
global erase_secret_bytes
global erase_stack_below_the_caller

; Names that the compiler calls.
%ifdef HOST

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
	call copy_bytes_without_overlap
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
	call copy_bytes_with_overlap
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
	call fill_bytes_with_value
	pop rsi
	pop rdi
	ret

%else

global memcpy
memcpy equ copy_bytes_without_overlap
global memmove
memmove equ copy_bytes_with_overlap
global memset
memset equ fill_bytes_with_value

%endif
