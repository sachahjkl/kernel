package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// The socket of the calls of the tool to its peer (peer_remote.odin): a
// Unix stream socket in a folder that only the user of the tool reaches.
// A call through it acts for the person in the machine, so the socket is
// not a port of the loopback, which every user of the host reaches.
//
// The folder: $XDG_RUNTIME_DIR/kerneltool when the variable is set, else
// /tmp/kerneltool-<user number>. The tool makes it with the mode 0700, and
// takes it only when it is a folder (not a link), of this user, with no
// right for the group and the others: a folder that another user made
// first is refused, and the tool says so. A folder under the repository is
// not used: a repository can be readable by its group.
//
// `kerneltool run` takes the socket "run" in that folder and prints its
// path; `kerneltool call` finds it by the same rule. A machine test takes
// a socket of its own, with the number of the process and of the peer.

CALL_SOCKET_RUN_NAME :: "run"

// The modes that the folder must not have: each right of the group and of
// the others.
@(private = "file")
CALL_FOLDER_OTHER_RIGHTS :: linux.Mode{.IXOTH, .IWOTH, .IROTH, .IXGRP, .IWGRP, .IRGRP}

// call_socket_folder gives the private folder of the sockets of the calls,
// and makes it when it does not exist. problem says why it is refused.
call_socket_folder :: proc() -> (folder: string, problem: string) {
	runtime_folder, has_runtime_folder := os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if has_runtime_folder && runtime_folder != "" {
		folder = fmt.tprintf("%s/kerneltool", runtime_folder)
	} else {
		folder = fmt.tprintf("/tmp/kerneltool-%d", u32(linux.getuid()))
	}
	path := strings.clone_to_cstring(folder, context.temp_allocator)
	made := linux.mkdir(path, linux.Mode{.IRUSR, .IWUSR, .IXUSR})
	if made != .NONE && made != .EEXIST {
		return folder, fmt.tprintf("the folder %s cannot be made: %v", folder, made)
	}
	// lstat: a link to a folder of another user is refused, not followed.
	status: linux.Stat
	if read := linux.lstat(path, &status); read != .NONE {
		return folder, fmt.tprintf("the folder %s cannot be read: %v", folder, read)
	}
	switch {
	case !linux.S_ISDIR(status.mode):
		return folder, fmt.tprintf("%s is not a folder (a link or a file): the tool does not put its socket there", folder)
	case status.uid != linux.getuid():
		return folder, fmt.tprintf("the folder %s belongs to the user %d, not to this user: the tool does not put its socket there", folder, u32(status.uid))
	case status.mode & CALL_FOLDER_OTHER_RIGHTS != {}:
		return folder, fmt.tprintf("the folder %s gives rights to the group or to the others: the tool does not put its socket there (chmod 700 %s)", folder, folder)
	}
	return folder, ""
}

// call_socket_path gives the path of a socket of the calls in the private
// folder.
call_socket_path :: proc(name: string) -> (path: string, problem: string) {
	folder, folder_problem := call_socket_folder()
	if folder_problem != "" {
		return "", folder_problem
	}
	path = fmt.tprintf("%s/calls-%s.socket", folder, name)
	address: linux.Sock_Addr_Un
	if len(path) >= len(address.sun_path) {
		return "", fmt.tprintf("the path %s has %d bytes; a Unix socket takes %d at most", path, len(path), len(address.sun_path) - 1)
	}
	return path, ""
}

@(private = "file")
call_socket_address :: proc(path: string) -> (address: linux.Sock_Addr_Un) {
	address.sun_family = .UNIX
	copy(address.sun_path[:len(address.sun_path) - 1], path)
	return address
}

// call_socket_receive_timeout makes a receive or an accept of a socket end
// after a time: a thread then sees the stop of the peer.
@(private = "file")
call_socket_receive_timeout :: proc(socket: linux.Fd, timeout: time.Duration) {
	value := linux.Time_Val{seconds = int(timeout / time.Second), microseconds = int(timeout % time.Second / time.Microsecond)}
	_ = linux.setsockopt(socket, linux.SOL_SOCKET, linux.Socket_Option.RCVTIMEO, &value)
}

// call_socket_listen takes the socket of a path: a socket of an earlier run
// at that path is removed first (the folder belongs to this user). Its
// accept ends each 100 ms.
call_socket_listen :: proc(path: string) -> (listener: linux.Fd, ok: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	_ = linux.unlink(name)
	socket, made := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .UNSPECIFIED)
	if made != .NONE {
		fmt.eprintfln("kerneltool: no Unix socket for the calls: %v", made)
		return -1, false
	}
	address := call_socket_address(path)
	if bound := linux.bind(socket, &address); bound != .NONE {
		fmt.eprintfln("kerneltool: the socket of the calls cannot take %s: %v", path, bound)
		_ = linux.close(socket)
		return -1, false
	}
	if listened := linux.listen(socket, 16); listened != .NONE {
		fmt.eprintfln("kerneltool: the socket of the calls at %s does not listen: %v", path, listened)
		_ = linux.close(socket)
		_ = linux.unlink(name)
		return -1, false
	}
	call_socket_receive_timeout(socket, 100 * time.Millisecond)
	return socket, true
}

// call_socket_accept takes one connection of the socket of the calls. false:
// none came in 100 ms.
call_socket_accept :: proc(listener: linux.Fd) -> (connection: linux.Fd, ok: bool) {
	address: linux.Sock_Addr_Un
	accepted, error := linux.accept(listener, &address, {.CLOEXEC})
	if error != .NONE {
		return -1, false
	}
	call_socket_receive_timeout(accepted, 100 * time.Millisecond)
	return accepted, true
}

// call_socket_connect connects to the socket of the calls of a peer.
call_socket_connect :: proc(path: string) -> (connection: linux.Fd, ok: bool) {
	socket, made := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .UNSPECIFIED)
	if made != .NONE {
		return -1, false
	}
	address := call_socket_address(path)
	if connected := linux.connect(socket, &address); connected != .NONE {
		_ = linux.close(socket)
		return -1, false
	}
	call_socket_receive_timeout(socket, 100 * time.Millisecond)
	return socket, true
}

// call_socket_send_all writes each byte. A peer that went away gives false,
// not the signal of a broken pipe.
call_socket_send_all :: proc(connection: linux.Fd, bytes: []u8) -> bool {
	sent := 0
	for sent < len(bytes) {
		count, error := linux.send(connection, bytes[sent:], {.NOSIGNAL})
		if error == .EINTR {
			continue
		}
		if error != .NONE || count <= 0 {
			return false
		}
		sent += count
	}
	return true
}

// call_socket_receive_all reads up to the end of the other side, into
// buffer, within limit on the clock of the host (a bound for a peer that
// hangs). It gives the count of bytes; ended is false when the time or the
// buffer ran out before the end.
call_socket_receive_all :: proc(connection: linux.Fd, buffer: []u8, limit: time.Duration) -> (count: int, ended: bool) {
	start := time.tick_now()
	for time.tick_since(start) < limit {
		if count == len(buffer) {
			return count, false
		}
		read, error := linux.recv(connection, buffer[count:], {})
		switch {
		case error == .EAGAIN || error == .EINTR:
			continue
		case error != .NONE:
			return count, false
		case read == 0:
			return count, true
		}
		count += read
	}
	return count, false
}

call_socket_end_sending :: proc(connection: linux.Fd) {
	_ = linux.shutdown(connection, .WR)
}

call_socket_close :: proc(connection: linux.Fd) {
	_ = linux.close(connection)
}

// call_socket_remove closes the socket of the calls and removes its path.
call_socket_remove :: proc(listener: linux.Fd, path: string) {
	_ = linux.close(listener)
	_ = linux.unlink(strings.clone_to_cstring(path, context.temp_allocator))
}
