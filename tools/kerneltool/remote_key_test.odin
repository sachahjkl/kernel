package kerneltool

import "core:testing"

// A step that calls remote needs a step Remote_Key since the last start of
// remote: the first one without it is named, and each scenario of the tool
// passes the check.
@(test)
each_call_of_remote_has_the_key_of_its_start :: proc(t: ^testing.T) {
	right := []Step {
		{kind = .Launch, text = "remote"},
		{kind = .Remote_Key, text = "remote: the public key of this service: "},
		{kind = .Call, text = "monitor.programs()"},
		{kind = .Record, text = "a text"},
	}
	testing.expect_value(t, remote_key_problem(right), "")
	no_key := []Step {
		{kind = .Launch, text = "remote"},
		{kind = .Call, text = "monitor.programs()"},
	}
	testing.expect(t, remote_key_problem(no_key) != "", "a call with no key is refused")
	// A start again makes a new key: the key of the start before does not
	// count.
	started_again := []Step {
		{kind = .Launch, text = "remote"},
		{kind = .Remote_Key, text = "remote: the public key of this service: "},
		{kind = .Call, text = "monitor.programs()"},
		{kind = .Close, text = "remote"},
		{kind = .Type, text = "start(\"remote\")"},
		{kind = .Remote_Case, text = "two at once"},
	}
	testing.expect(t, remote_key_problem(started_again) != "", "a call after a start again with the key of the start before is refused")
	for steps in ([][]Step{scenario[:], scenario_network[:], scenario_measure[:], scenario_shortage[:], scenario_film[:], scenario_palette_film[:], scenario_tcp[:], scenario_tcp_real[:], scenario_quic[:], scenario_quic_real[:]}) {
		testing.expect_value(t, remote_key_problem(steps), "")
	}
}
