package kerneltool

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"

// The connection of the tool to the machine protocol of QEMU: a Unix
// stream socket that QEMU listens on, beside the log of the machine. One
// command goes at a time, and the tool waits for its reply (qmp.odin has
// the text of the commands).

// The end of the name of the socket of a machine, after the name of its
// log.
QMP_SOCKET_SUFFIX :: ".qmp"

Qmp :: struct {
	connection: linux.Fd,
	open:       bool,
	ended:      bool, // QEMU closed the connection: the machine ended.
	received:   [dynamic]u8, // The bytes that came after the last whole line.
}

// qmp_socket_of gives the path of the socket of the machine with this log.
qmp_socket_of :: proc(output: string) -> string {
	return machine_file(output, QMP_SOCKET_SUFFIX)
}

// qmp_open connects to the socket of a machine that starts, reads the
// first line of QEMU and opens the commands. QEMU makes the socket when it
// starts: the tool tries until the socket takes the connection.
qmp_open :: proc(qmp: ^Qmp, path: string) -> bool {
	connected := false
	for start := time.tick_now(); !connected && time.tick_since(start) < HANG_BOUND; {
		if qmp.connection, connected = call_socket_connect(path); !connected {
			time.sleep(CONDITION_POLL_PERIOD)
		}
	}
	if !connected {
		fmt.eprintfln("kerneltool: test failed: QEMU did not take a connection at %s within %v", path, HANG_BOUND)
		return false
	}
	qmp.open = true
	for {
		line, read := qmp_line_read(qmp)
		if !read {
			fmt.eprintfln("kerneltool: test failed: QEMU sent no first line at %s", path)
			return false
		}
		if kind, _ := qmp_reply_parse(line); kind == .Greeting {
			break
		}
	}
	_, opened := qmp_command(qmp, "{\"execute\":\"qmp_capabilities\"}")
	return opened
}

qmp_close :: proc(qmp: ^Qmp) {
	if qmp.open {
		call_socket_close(qmp.connection)
		qmp.open = false
	}
	delete(qmp.received)
	qmp.received = nil
}

// qmp_line_read gives the next whole line of QEMU, in the temporary
// allocator. false: QEMU closed the connection (qmp.ended says so), or
// sent no line within the bound of a hang.
qmp_line_read :: proc(qmp: ^Qmp) -> (line: string, ok: bool) {
	start := time.tick_now()
	for {
		for byte, index in qmp.received {
			if byte == '\n' {
				line = strings.clone(string(qmp.received[:index]), context.temp_allocator)
				remove_range(&qmp.received, 0, index + 1)
				return line, true
			}
		}
		if time.tick_since(start) >= HANG_BOUND {
			return "", false
		}
		buffer: [4096]u8
		// The receive of the socket ends after its own time with no byte:
		// this loop then reads the bound again.
		count, error := linux.recv(qmp.connection, buffer[:], {})
		switch {
		case error == .EAGAIN || error == .EINTR:
			continue
		case error != .NONE || count <= 0:
			qmp.ended = true
			return "", false
		}
		append(&qmp.received, ..buffer[:count])
	}
}

// qmp_command sends one command and waits for its reply. value is what the
// command returns, as QEMU wrote it. false: QEMU refused the command or
// gave no reply within the bound of a hang (the tool prints why), or QEMU
// closed the connection, with no message: qmp.ended says so, and the
// caller decides, because a machine that the system stopped is no failure.
qmp_command :: proc(qmp: ^Qmp, command: string) -> (value: string, ok: bool) {
	if qmp.ended {
		return "", false
	}
	if !qmp.open {
		fmt.eprintfln("kerneltool: test failed: no connection to QEMU for the command %s", command)
		return "", false
	}
	line := strings.concatenate({command, "\n"}, context.temp_allocator)
	if !call_socket_send_all(qmp.connection, transmute([]u8)line) {
		qmp.ended = true
		return "", false
	}
	for {
		reply, read := qmp_line_read(qmp)
		if !read {
			if !qmp.ended {
				fmt.eprintfln("kerneltool: test failed: QEMU gave no reply to the command %s within %v", command, HANG_BOUND)
			}
			return "", false
		}
		kind, text := qmp_reply_parse(reply)
		#partial switch kind {
		case .Return:
			return text, true
		case .Error:
			fmt.eprintfln("kerneltool: test failed: QEMU refused the command %s: %s", command, text)
			return "", false
		}
		// An event, or a line that is not of the protocol: not the reply.
	}
}
