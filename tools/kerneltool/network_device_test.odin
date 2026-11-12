package kerneltool

import "core:strings"
import "core:testing"

// No network device of a machine forwards a UDP port of the host to the
// port of `remote`: each form that the tool builds passes, and a forward to
// that port is refused in each form that QEMU reads.
@(test)
no_machine_forwards_a_port_to_remote :: proc(t: ^testing.T) {
	with_user_network := network_device_of(40001, 40002, 40003, 40004)
	with_peer := network_device_of(0, 0, 40003, 40004)
	testing.expect(t, strings.contains(with_user_network, "hostfwd=tcp:127.0.0.1:40001-10.0.2.15:80"))
	testing.expect(t, strings.has_prefix(with_peer, "dgram,"))
	testing.expect_value(t, network_device_problem(with_user_network), "")
	testing.expect_value(t, network_device_problem(with_peer), "")
	refused := []string {
		"user,id=network,hostfwd=udp:127.0.0.1:9000-10.0.2.15:7100",
		"user,id=network,hostfwd=udp::9000-:7100",
		"user,id=network,hostfwd=tcp:127.0.0.1:8080-10.0.2.15:80,hostfwd=udp:0.0.0.0:7100-10.0.2.15:7100",
	}
	for device in refused {
		testing.expectf(t, network_device_problem(device) != "", "%s is refused", device)
	}
	// A forward of TCP, or of UDP to another port, does not reach remote.
	testing.expect_value(t, network_device_problem("user,id=network,hostfwd=tcp:127.0.0.1:9000-10.0.2.15:7100"), "")
	testing.expect_value(t, network_device_problem("user,id=network,hostfwd=udp:127.0.0.1:9000-10.0.2.15:7101"), "")
}
