package kerneltool

import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
test_measure_record :: proc() -> Measure_Record {
	numbers := make([]Measure_Record_Number, 2, context.temp_allocator)
	numbers[0] = {sentence = "Reads of the time", found = true, log = "build/test_output.txt", line_number = 812, matching_lines = 2, machine = "The main machine of `kerneltool test`", line = "[clock] clock: the time page: 1000 reads"}
	numbers[1] = {sentence = "A full frame of the compositor", absent = "build/test_output.txt: no line with \"compositor: a full frame of\""}
	boot_lines := make([]string, 2, context.temp_allocator)
	boot_lines[0] = "kernel: boot: firmware: 1031293 us"
	boot_lines[1] = "kernel: boot: kernel: root service: 2096 us"
	return Measure_Record {
		time = "2026-11-12 02:09 UTC",
		release = "0.91.0",
		commit = "264fa303aaaabbbbccccddddeeeeffff00001111",
		tree = .Changed,
		host = "AMD Ryzen 7 5800X 8-Core Processor, 16 logical processors; QEMU with KVM",
		checks_passed = 1234,
		numbers = numbers,
		boot_lines = boot_lines,
	}
}

// The writer and the reader: the record reads back field by field, and a
// second write gives the same bytes.
@(test)
measure_record_round_trip :: proc(t: ^testing.T) {
	record := test_measure_record()
	text := measure_record_format(record)
	testing.expect(t, strings.has_prefix(text, MEASURE_RECORD_FIRST_LINE + "\ntime 2026-11-12 02:09 UTC\nrelease 0.91.0\n"))
	testing.expect(t, strings.has_suffix(text, "boot kernel: boot: kernel: root service: 2096 us\nend\n"))
	read, problem := measure_record_parse(text)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, read.time, record.time)
	testing.expect_value(t, read.release, record.release)
	testing.expect_value(t, read.commit, record.commit)
	testing.expect_value(t, read.tree, Measure_Tree_State.Changed)
	testing.expect_value(t, read.host, record.host)
	testing.expect_value(t, read.checks_passed, 1234)
	testing.expect_value(t, len(read.numbers), 2)
	testing.expect_value(t, len(read.boot_lines), 2)
	if len(read.numbers) == 2 {
		testing.expect_value(t, read.numbers[0], record.numbers[0])
		testing.expect_value(t, read.numbers[1], record.numbers[1])
	}
	testing.expect_value(t, measure_record_format(read), text)

	// An unknown commit reads back as unknown.
	no_commit := record
	no_commit.commit = ""
	read_no_commit, no_commit_problem := measure_record_parse(measure_record_format(no_commit))
	testing.expect_value(t, no_commit_problem, "")
	testing.expect_value(t, read_no_commit.commit, "")

	// A file that is not whole, of another form, or with a key out of place
	// is refused.
	cut := text[:strings.index(text, "boot ")]
	_, cut_problem := measure_record_parse(cut)
	testing.expect(t, strings.contains(cut_problem, "not whole"))
	_, form_problem := measure_record_parse("measure record 2\ntime x\nrelease y\nend\n")
	testing.expect(t, strings.contains(form_problem, "first line"))
	_, key_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nspeed 3\nend\n")
	testing.expect(t, strings.contains(key_problem, "speed"))
	_, orphan_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nline 3\nend\n")
	testing.expect(t, strings.contains(orphan_problem, "before the first line"))
	_, both_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nnumber n\nlog a\nline 1\nmatching 1\ntext t\nabsent no\nend\n")
	testing.expect(t, strings.contains(both_problem, "not both"))
	_, count_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nnumber n\nlog a\nline zero\nmatching 1\ntext t\nend\n")
	testing.expect(t, strings.contains(count_problem, "count"))
}

// A path of the host in a log line becomes relative to the repository; the
// home folder, the user name and the host name do not stay in a line.
@(test)
measure_record_cuts_the_private_texts :: proc(t: ^testing.T) {
	names := Measure_Private_Names {
		repository_folder = "/home/someone/Projects/kernel",
		home_folder       = "/home/someone",
		user_name         = "someone",
		host_name         = "workstation",
	}
	line := "[tool] tool: read /home/someone/Projects/kernel/build/test_output.txt, /home/someone/.cache/x and /home/someone/Projects/kernel on workstation for someone"
	testing.expect_value(t, measure_text_without_private(line, names), "[tool] tool: read build/test_output.txt, ~/.cache/x and . on <host> for <user>")
	testing.expect_value(t, measure_text_without_private("net: 64 bytes in 12 us", names), "net: 64 bytes in 12 us")
	// A short name matches parts of words: it is not replaced.
	short := Measure_Private_Names{user_name = "al"}
	testing.expect_value(t, measure_text_without_private("all values", short), "all values")

	// The writer cuts the line that it takes from a log.
	measure := Site_Measure{sentence = "One read", files = {TEST_OUTPUT, ""}, pattern = "disk: read", choice = .First}
	number := Measure_Record_Number{sentence = measure.sentence}
	log := "[a] a: start\n[disk] disk: read /home/someone/Projects/kernel/build/scratch_disk.img: 12 us\n"
	testing.expect(t, measure_record_number_from_log(&number, measure, TEST_OUTPUT, log, names))
	testing.expect_value(t, number.line, "[disk] disk: read build/scratch_disk.img: 12 us")
	testing.expect_value(t, number.line_number, 2)
	testing.expect_value(t, number.matching_lines, 1)
	testing.expect_value(t, number.log, TEST_OUTPUT)
	testing.expect(t, !measure_record_number_from_log(&number, Site_Measure{pattern = "absent"}, TEST_OUTPUT, log, names))
	boot := measure_boot_lines("kernel: boot: firmware: 1 us\n[x] x: y\nkernel: boot: kernel: /home/someone/a: 2 us\n", names)
	testing.expect_value(t, len(boot), 2)
	if len(boot) == 2 {
		testing.expect_value(t, boot[1], "kernel: boot: kernel: ~/a: 2 us")
	}

	// The host line names the processor and the accelerator only.
	information := "processor\t: 0\nmodel name\t: AMD Ryzen 7 5800X 8-Core Processor\nprocessor\t: 1\nmodel name\t: AMD Ryzen 7 5800X 8-Core Processor\n"
	testing.expect_value(t, measure_host_text(information, true), "AMD Ryzen 7 5800X 8-Core Processor, 2 logical processors; QEMU with KVM")
	testing.expect_value(t, measure_host_text("", false), "a processor whose model the tool cannot read, 0 logical processors; QEMU with TCG, with no KVM")
}

// The choice between a log of build/ and the measure record, by their
// times.
@(test)
measure_record_or_build_by_time :: proc(t: ^testing.T) {
	older := time.unix(1_000, 0)
	newer := time.unix(2_000, 0)
	record := Site_Measure_Record{present = true, written = newer}
	testing.expect_value(t, site_measure_source_choose(true, time.unix(3_000, 0), record, true), Site_Measure_Source.Build)
	testing.expect_value(t, site_measure_source_choose(true, older, record, true), Site_Measure_Source.Record)
	testing.expect_value(t, site_measure_source_choose(false, {}, record, true), Site_Measure_Source.Record)
	testing.expect_value(t, site_measure_source_choose(true, older, record, false), Site_Measure_Source.None)
	testing.expect_value(t, site_measure_source_choose(false, {}, record, false), Site_Measure_Source.None)
	no_record := Site_Measure_Record{}
	testing.expect_value(t, site_measure_source_choose(true, older, no_record, false), Site_Measure_Source.Build)
	testing.expect_value(t, site_measure_source_choose(false, {}, no_record, false), Site_Measure_Source.None)

	// A number that build/ does not have and that the record holds: its
	// line, its log and the time of the record, and no "no file".
	present := Site_Measure_Record{present = true, record = test_measure_record(), written = newer}
	from_build := Site_Measured {
		measure = Site_Measure{sentence = "Reads of the time"},
		missing = "build/test_output.txt: no file",
	}
	resolved := site_measure_resolve(from_build, present)
	testing.expect(t, resolved.found)
	testing.expect_value(t, resolved.source, Site_Measure_Source.Record)
	testing.expect_value(t, resolved.text, "clock: the time page: 1000 reads")
	testing.expect_value(t, resolved.path, "build/test_output.txt")
	testing.expect_value(t, resolved.line_number, 812)
	testing.expect_value(t, resolved.written, "2026-11-12 02:09 UTC")
	testing.expect_value(t, resolved.missing, "")
	// A number that the run did not give: absent, with the reason of the run.
	absent := site_measure_resolve(Site_Measured{measure = Site_Measure{sentence = "A full frame of the compositor"}, missing = "build/test_output.txt: no file"}, present)
	testing.expect(t, !absent.found)
	testing.expect(t, strings.contains(absent.missing, "the full check of 2026-11-12 02:09 UTC did not print it"))
	// A log of build/ that is newer wins.
	newest := Site_Measured {
		measure  = Site_Measure{sentence = "Reads of the time"},
		found    = true,
		source   = .Build,
		path     = TEST_OUTPUT,
		text     = "clock: the time page: 2000 reads",
		log_time = time.unix(3_000, 0),
	}
	testing.expect_value(t, site_measure_resolve(newest, present).text, "clock: the time page: 2000 reads")
}

// Each required number is a line that a scenario of the full check waits
// for, in the log that the table names; the second build is the one other
// required source.
@(test)
measure_record_required_numbers_are_waited_for :: proc(t: ^testing.T) {
	waits :: proc(steps: []Step, pattern: string) -> bool {
		for step in steps {
			if step.kind == .Wait && strings.contains(step.text, pattern) {
				return true
			}
		}
		return false
	}
	for measure in site_measures {
		if !measure.required {
			continue
		}
		waited := false
		for path in measure.files {
			switch path {
			case TEST_OUTPUT:
				waited ||= waits(scenario[:], measure.pattern)
			case TEST_OUTPUT_NETWORK:
				waited ||= waits(scenario_network[:], measure.pattern)
			case TEST_OUTPUT_TCP_REAL:
				waited ||= waits(scenario_tcp_real[:], measure.pattern)
			case TEST_OUTPUT_CRYPTOGRAPHY:
				waited ||= waits(scenario_cryptography[:], measure.pattern)
			case BUILD_FOLDER + "/test_output_persist_1.txt":
				waited ||= waits(scenario_persist_first[:], measure.pattern)
			case REPRODUCIBLE_BUILD_RECORD:
				waited = true
			}
		}
		testing.expectf(t, waited, "the required number %q is not a line that a scenario of the full check waits for", measure.sentence)
	}
}

// The page of the numbers: the run first, then a row from the record, a
// row from build/ and a row that is absent; a record of an older release.
@(test)
measure_record_page_text :: proc(t: ^testing.T) {
	site := test_site()
	site.release = "0.91.0"
	site.measure_record = Site_Measure_Record{present = true, record = test_measure_record(), written = time.unix(2_000, 0)}
	measured := make([]Site_Measured, 3, context.temp_allocator)
	measured[0] = site_measure_resolve(Site_Measured{measure = Site_Measure{sentence = "Reads of the time"}, missing = "build/test_output.txt: no file"}, site.measure_record)
	measured[1] = Site_Measured {
		measure     = Site_Measure{sentence = "Blocks read"},
		found       = true,
		source      = .Build,
		path        = TEST_OUTPUT,
		line_number = 5,
		text        = "disk: read, 1 block",
		written     = "2026-11-13 08:00 UTC",
		log_time    = time.unix(3_000, 0),
	}
	measured[2] = site_measure_resolve(Site_Measured{measure = Site_Measure{sentence = "A full frame of the compositor"}, missing = "build/test_output.txt: no file"}, site.measure_record)
	site.measured = measured
	body := site_numbers_body(&site)
	first_paragraph := body[strings.index(body, "<p>"):]
	first_paragraph = first_paragraph[:strings.index(first_paragraph, "</p>")]
	for part in ([]string{"<time datetime=\"2026-11-12T02:09Z\">2026-11-12 02:09 UTC</time>", "<code>264fa30</code>", "with changes that were not committed", "the release 0.91.0", "AMD Ryzen 7 5800X 8-Core Processor, 16 logical processors; QEMU with KVM", "1234 checks passed"}) {
		testing.expectf(t, strings.contains(first_paragraph, part), "the first paragraph has no %q:\n%s", part, first_paragraph)
	}
	expect := [?]string {
		"<code>clock: the time page: 1000 reads</code>",
		"line 812 (the first of 2 lines with this text)",
		"Measured in the full check of 2026-11-12, on the tree of <code>264fa30</code>, with changes that were not committed.",
		"Measured in this work tree: the log in <code>build/</code> is newer than <code>docs/measures/measures.txt</code>.",
		"1 numbers come from the logs in <code>build/</code>",
		"<td data-label=\"The line of the log\" class=\"column-line missing\">Not measured.</td>",
		"2 of 3 numbers are measured.",
	}
	for part in expect {
		testing.expectf(t, strings.contains(body, part), "the page has no %q:\n%s", part, body)
	}
	testing.expect(t, !strings.contains(body, "the numbers were measured before this release"))
	// The row from the record does not say "no file".
	row_start := strings.index(body, "clock: the time page")
	row := body[row_start:]
	row = row[:strings.index(row, "</tr>")]
	testing.expect(t, !strings.contains(row, "no file"))

	// A record of an older release.
	site.release = "0.92.0"
	older_body := site_numbers_body(&site)
	testing.expect(t, strings.contains(older_body, "The measure record is of the release 0.91.0. This site shows the release 0.92.0: the numbers were measured before this release."))

	// No record.
	site.measure_record = {}
	testing.expect(t, strings.contains(site_numbers_body(&site), "The repository holds no measure record"))
}
