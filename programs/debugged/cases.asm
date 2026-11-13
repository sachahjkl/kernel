; The one sequence of the cases of the debugger (main.odin) that needs two
; exact instructions one after the other: the compiler gives no such order.
bits 64
default rel
section .text

; load_stack_selector_then_syscall(selector: ^u64)
; It loads the stack selector from a word of memory, and the next
; instruction is a syscall. The debugger of the program watches that word
; with a data breakpoint: the load is a read of the word, and the processor
; can hold the trap of a load of ss until the instruction after it, the
; syscall, where the trap comes at the first instruction of the kernel
; (docs/ARCHITECTURE.md, "The windows of the entry and of the return"). The
; word holds the stack selector that the thread has already. The syscall
; has rdi 0: a kernel entry with no wait.
global load_stack_selector_then_syscall
load_stack_selector_then_syscall:
	mov rsi, rdi
	xor edi, edi
	mov ss, word [rsi]
	syscall                      ; rax, rcx and r11 change.
	ret
