package kerneltool

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

// The socket of the calls is in a folder of this user with no right for
// the group and the others; a folder that gives such a right is refused;
// bytes go both ways, and the end of the sending ends the read of the
// other side.
@(test)
the_socket_of_the_calls_is_private :: proc(t: ^testing.T) {
	base, made := os.make_directory_temp("", "kerneltool-socket-test-*", context.temp_allocator)
	testing.expect(t, made == nil)
	defer os.remove_all(base)
	before, had_before := os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator)
	os.set_env("XDG_RUNTIME_DIR", base)
	defer {
		if had_before {
			os.set_env("XDG_RUNTIME_DIR", before)
		} else {
			os.unset_env("XDG_RUNTIME_DIR")
		}
	}

	folder, problem := call_socket_folder()
	testing.expect_value(t, problem, "")
	status: linux.Stat
	testing.expect(t, linux.lstat(strings.clone_to_cstring(folder, context.temp_allocator), &status) == .NONE)
	testing.expect(t, linux.S_ISDIR(status.mode) && status.uid == linux.getuid())
	testing.expect(t, status.mode & linux.Mode{.IXOTH, .IWOTH, .IROTH, .IXGRP, .IWGRP, .IRGRP} == {}, "no right for the group and the others")

	// The round trip of one call: a header and bytes, the end, an answer.
	path, path_problem := call_socket_path("test-of-the-socket")
	testing.expect_value(t, path_problem, "")
	listener, listening := call_socket_listen(path)
	testing.expect(t, listening)
	client, connected := call_socket_connect(path)
	testing.expect(t, connected)
	served, accepted := call_socket_accept(listener)
	testing.expect(t, accepted)
	message := "a request"
	testing.expect(t, call_socket_send_all(client, transmute([]u8)message))
	call_socket_end_sending(client)
	buffer: [64]u8
	count, ended := call_socket_receive_all(served, buffer[:], 5 * time.Second)
	testing.expect(t, ended && string(buffer[:count]) == message)
	answer := "an answer"
	testing.expect(t, call_socket_send_all(served, transmute([]u8)answer))
	call_socket_close(served)
	count, ended = call_socket_receive_all(client, buffer[:], 5 * time.Second)
	testing.expect(t, ended && string(buffer[:count]) == answer)
	call_socket_close(client)
	call_socket_remove(listener, path)

	// A folder that the group can read is refused.
	_ = linux.chmod(strings.clone_to_cstring(folder, context.temp_allocator), linux.Mode{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP})
	_, refused := call_socket_folder()
	testing.expect(t, refused != "", "a folder with rights of the group is refused")
}
