; The instructions that a program needs and that Odin cannot write.
bits 64
default rel
section .text

global system_enter
system_enter:                    ; (wait: u64) -> u64: the one kernel entry point
	syscall
	ret

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
