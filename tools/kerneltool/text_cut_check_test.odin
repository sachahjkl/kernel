package kerneltool

import "core:testing"

@(test)
text_cut_rule_on_a_good_and_a_bad_source :: proc(t: ^testing.T) {
	good := `writer := system.Writer{buffer = buffer[:]}
for writer.count < 53 {
	system.write_part(&writer, " ")
}
system.writer_reset(&writer) // writer.count = 0 in a comment is no code.
text := system.written(&writer)
if writer.count == 0 {
}`
	testing.expect_value(t, len(text_cut_problems(good)), 0)
	bad := `writer := system.Writer{buffer = buffer[:]}
writer.count = 0
text := string(writer.buffer[:writer.count])
writer.count += 1
writer.count -= 2`
	problems := text_cut_problems(bad)
	testing.expect_value(t, len(problems), 4)
	if len(problems) == 4 {
		testing.expect(t, problems[0] == 2 && problems[1] == 3 && problems[2] == 4 && problems[3] == 5)
	}
}
