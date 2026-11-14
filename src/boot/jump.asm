; boot_jump(page_table, entry, boot_info, stack): leave the boot program.
; Windows x64 convention: rcx, rdx, r8, r9. It does not return.
bits 64
default rel
section .text
global boot_jump
boot_jump:
	cli
	mov r10, rcx
	mov r11, rdx
	mov ecx, 0xC0000080          ; EFER: enable the no-execute bit of page tables
	rdmsr
	or eax, 1 << 11
	wrmsr
	mov rax, cr0
	or rax, 1 << 16              ; the kernel obeys read-only pages
	mov cr0, rax
	mov cr3, r10
	mov rsp, r9
	xor ebp, ebp
	mov rdi, r8                  ; first parameter of the kernel entry (System V)
	push 0                       ; a null return address: the entry does not return
	jmp r11

; A function whose frame is larger than one page calls __chkstk before it
; moves the stack pointer: the convention of the Windows x64 target, which
; is the target of a UEFI program. Its work is to touch each page of the new
; frame, for a stack that grows page by page. The firmware gives the boot
; program a stack that is all present (128 KiB at least, by the UEFI
; specification), so there is nothing to touch. It keeps every register.
global __chkstk
__chkstk:
	ret
