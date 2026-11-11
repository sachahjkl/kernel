package kerneltool

import "core:testing"

// The text of a call: the service, the export, and the typed arguments.
@(test)
call_parse_reads :: proc(t: ^testing.T) {
	service, export, arguments, problem := call_parse(`  storage.write("a \"note\"\n", -12, 0x10) `)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, service, "storage")
	testing.expect_value(t, export, "write")
	testing.expect_value(t, len(arguments), 3)
	testing.expect(t, arguments[0].is_text && arguments[0].text == "a \"note\"\n")
	testing.expect(t, !arguments[1].is_text && arguments[1].integer == -12)
	testing.expect(t, !arguments[2].is_text && arguments[2].integer == 16)
	service, export, arguments, problem = call_parse("monitor.programs()")
	testing.expect(t, problem == "" && service == "monitor" && export == "programs" && len(arguments) == 0)
}

// Each malformed text gives a sentence, and no call.
@(test)
call_parse_refuses :: proc(t: ^testing.T) {
	for text in ([]string{"programs()", "monitor.programs", ".x()", "monitor.count(\"open", "monitor.count(1 2)", "monitor.count(1,)", "monitor.count(abc)"}) {
		_, _, _, problem := call_parse(text)
		testing.expectf(t, problem != "", "%s is refused", text)
	}
}
