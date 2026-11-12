// The measure record: the file of the repository that holds the measured
// numbers of the last full check, and the facts of its run. A build of the
// site on a clean checkout runs no machine, so it reads the numbers here
// (docs/SITE.md, "The measure record"). `kerneltool screenshots` writes
// the file; `kerneltool site` reads it.
package kerneltool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

MEASURE_RECORD_FOLDER :: "docs/measures"
MEASURE_RECORD_FILE :: MEASURE_RECORD_FOLDER + "/measures.txt"
// The first line names the form: a reader refuses another form.
MEASURE_RECORD_FIRST_LINE :: "measure record 1"
// The last line: a file with no such line was not written whole.
MEASURE_RECORD_LAST_LINE :: "end"
// The count of the first digits of a commit that a page shows.
MEASURE_COMMIT_SHORT_LENGTH :: 7
// A user name or a host name that is shorter is not replaced in a text: it
// matches parts of common words.
MEASURE_PRIVATE_NAME_LEAST_LENGTH :: 3

// Whether the work tree had changes that were not committed when the run
// started.
Measure_Tree_State :: enum {
	Unknown,
	Clean,
	Changed,
}

@(rodata)
measure_tree_state_names := [Measure_Tree_State]string {
	.Unknown = "unknown",
	.Clean   = "clean",
	.Changed = "changed",
}

// What the pass reads before it changes the tree.
Measure_Run_Facts :: struct {
	started: time.Time,
	commit:  string, // 40 hexadecimal digits, or "" when the tool cannot read it.
	tree:    Measure_Tree_State,
}

// One number of `site_measures` in the record: the whole line of the log
// that holds it, or why the run did not give it.
Measure_Record_Number :: struct {
	sentence:       string, // The sentence of the table: the key of the number.
	found:          bool,
	log:            string, // The path of the log, relative to the repository.
	line_number:    int,
	matching_lines: int,
	machine:        string, // The machine that wrote the log.
	line:           string, // The whole line, with its label "[program] ".
	absent:         string, // Why the run did not give the number.
}

Measure_Record :: struct {
	time:          string, // When the record was written, "2026-11-12 02:09 UTC".
	release:       string, // The newest release of the changelog in the tree of the run.
	commit:        string, // The commit of the tree of the run, or "".
	tree:          Measure_Tree_State,
	host:          string, // The processor of the host and the accelerator of QEMU.
	checks_passed: int,
	numbers:       []Measure_Record_Number,
	boot_lines:    []string, // The lines "kernel: boot: ..." of the main machine.
}

// The texts of the host that no line of the record may hold.
Measure_Private_Names :: struct {
	repository_folder: string, // The absolute path of the repository.
	home_folder:       string,
	user_name:         string,
	host_name:         string,
}

// measure_time_text gives a time as the pages show it.
measure_time_text :: proc(moment: time.Time) -> string {
	year, month, day := time.date(moment)
	hour, minute, _ := time.clock(moment)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", year, int(month), day, hour, minute)
}

// measure_run_facts_read reads the commit and the state of the tree. The
// pass calls it first: it writes pictures and the record into the tree.
measure_run_facts_read :: proc() -> Measure_Run_Facts {
	facts := Measure_Run_Facts{started = time.now(), commit = site_git_commit()}
	command := [?]string{"git", "status", "--porcelain"}
	state, standard_output, _, error := os.process_exec({command = command[:]}, context.temp_allocator)
	if error == nil && state.exited && state.success {
		if len(strings.trim_space(string(standard_output))) == 0 {
			facts.tree = .Clean
		} else {
			facts.tree = .Changed
		}
	}
	return facts
}

// measure_private_names_read reads the texts of the host that the record
// must not hold.
measure_private_names_read :: proc() -> Measure_Private_Names {
	names: Measure_Private_Names
	names.repository_folder, _ = os.get_working_directory(context.temp_allocator)
	names.home_folder = os.get_env("HOME", context.temp_allocator)
	names.user_name = os.get_env("USER", context.temp_allocator)
	if data, error := os.read_entire_file("/proc/sys/kernel/hostname", context.temp_allocator); error == nil {
		names.host_name = strings.trim_space(string(data))
	}
	return names
}

// measure_text_without_private cuts the texts of the host out of a text:
// a path in the repository becomes relative to it, the home folder becomes
// "~", the user name "<user>" and the host name "<host>". The repository
// is in the home folder, so it goes first.
measure_text_without_private :: proc(text: string, names: Measure_Private_Names) -> string {
	result := text
	if len(names.repository_folder) > 1 {
		result, _ = strings.replace_all(result, strings.concatenate({names.repository_folder, "/"}, context.temp_allocator), "", context.temp_allocator)
		result, _ = strings.replace_all(result, names.repository_folder, ".", context.temp_allocator)
	}
	if len(names.home_folder) > 1 {
		result, _ = strings.replace_all(result, names.home_folder, "~", context.temp_allocator)
	}
	if len(names.user_name) >= MEASURE_PRIVATE_NAME_LEAST_LENGTH {
		result, _ = strings.replace_all(result, names.user_name, "<user>", context.temp_allocator)
	}
	if len(names.host_name) >= MEASURE_PRIVATE_NAME_LEAST_LENGTH {
		result, _ = strings.replace_all(result, names.host_name, "<host>", context.temp_allocator)
	}
	return result
}

// measure_host_text gives the host as the record states it: the model of
// the processor, the count of logical processors, and how QEMU runs the
// machine. It names no host, no user and no folder.
measure_host_text :: proc(processor_information: string, has_kvm: bool) -> string {
	model := "a processor whose model the tool cannot read"
	count := 0
	for line in site_lines(processor_information) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		key := strings.trim_space(line[:colon])
		if key == "processor" {
			count += 1
		}
		if key == "model name" && count <= 1 {
			model = strings.trim_space(line[colon + 1:])
		}
	}
	accelerator: string = has_kvm ? "QEMU with KVM" : "QEMU with TCG, with no KVM"
	return fmt.tprintf("%s, %d logical processors; %s", model, count, accelerator)
}

// measure_record_number_from_log takes the line of a number from the
// content of one log. It gives false when the log has no such line.
measure_record_number_from_log :: proc(number: ^Measure_Record_Number, measure: Site_Measure, path, content: string, names: Measure_Private_Names) -> bool {
	line, line_number, matching_lines := log_line_choose(content, measure.pattern, measure.choice)
	if matching_lines == 0 {
		return false
	}
	number.found = true
	number.log = measure_text_without_private(path, names)
	number.line_number = line_number
	number.matching_lines = matching_lines
	number.machine = site_output_conditions(path)
	number.line = measure_text_without_private(line, names)
	number.absent = ""
	return true
}

// measure_record_number_read reads one number from the logs of the run. A
// log that is older than the start of the run is of another run: it is not
// read.
measure_record_number_read :: proc(measure: Site_Measure, started: time.Time, names: Measure_Private_Names) -> Measure_Record_Number {
	number := Measure_Record_Number{sentence = measure.sentence}
	reasons := make([dynamic]string, context.temp_allocator)
	for path in measure.files {
		if path == "" {
			continue
		}
		file_information, stat_error := os.stat(path, context.temp_allocator)
		if stat_error != nil {
			append(&reasons, fmt.tprintf("%s: no file", path))
			continue
		}
		if time.diff(started, file_information.modification_time) < 0 {
			append(&reasons, fmt.tprintf("%s: written before the start of the run", path))
			continue
		}
		data, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			append(&reasons, fmt.tprintf("%s: cannot read: %v", path, read_error))
			continue
		}
		if measure_record_number_from_log(&number, measure, path, string(data), names) {
			return number
		}
		append(&reasons, fmt.tprintf("%s: no line with \"%s\"", path, measure.pattern))
	}
	number.absent = measure_text_without_private(strings.join(reasons[:], "; ", context.temp_allocator), names)
	return number
}

// measure_boot_lines gives the lines of the stages of the start of a log of
// the main machine, with the texts of the host cut out.
measure_boot_lines :: proc(content: string, names: Measure_Private_Names) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	for line in site_lines(content) {
		if strings.has_prefix(line, SITE_BOOT_STAGE_PREFIX) {
			append(&lines, measure_text_without_private(line, names))
		}
	}
	return lines[:]
}

// measure_value gives a text that fits on one line of the record.
measure_value :: proc(text: string) -> string {
	one_line, _ := strings.replace_all(text, "\n", " ", context.temp_allocator)
	one_line, _ = strings.replace_all(one_line, "\r", " ", context.temp_allocator)
	return one_line
}

// measure_record_format writes the record in its form: the first line,
// the facts of the run, one block for each number in the order of the
// table, the lines of the start in the order of the log, and the last
// line. Each line is a key, one space and a value.
measure_record_format :: proc(record: Measure_Record) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n", MEASURE_RECORD_FIRST_LINE)
	fmt.sbprintf(&b, "time %s\n", measure_value(record.time))
	fmt.sbprintf(&b, "release %s\n", measure_value(record.release))
	commit: string = record.commit != "" ? record.commit : "unknown"
	fmt.sbprintf(&b, "commit %s\n", measure_value(commit))
	fmt.sbprintf(&b, "tree %s\n", measure_tree_state_names[record.tree])
	fmt.sbprintf(&b, "host %s\n", measure_value(record.host))
	fmt.sbprintf(&b, "checks %d\n", record.checks_passed)
	for number in record.numbers {
		fmt.sbprintf(&b, "number %s\n", measure_value(number.sentence))
		if number.found {
			fmt.sbprintf(&b, "log %s\n", measure_value(number.log))
			fmt.sbprintf(&b, "line %d\n", number.line_number)
			fmt.sbprintf(&b, "matching %d\n", number.matching_lines)
			fmt.sbprintf(&b, "machine %s\n", measure_value(number.machine))
			fmt.sbprintf(&b, "text %s\n", measure_value(number.line))
		} else {
			fmt.sbprintf(&b, "absent %s\n", measure_value(number.absent))
		}
	}
	for line in record.boot_lines {
		fmt.sbprintf(&b, "boot %s\n", measure_value(line))
	}
	fmt.sbprintf(&b, "%s\n", MEASURE_RECORD_LAST_LINE)
	return strings.to_string(b)
}

// measure_record_parse reads a record in its form. The file is a file of
// the repository that a person can change: each line is checked.
measure_record_parse :: proc(text: string) -> (record: Measure_Record, problem: string) {
	lines := site_lines(text)
	for len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	if len(lines) == 0 || lines[0] != MEASURE_RECORD_FIRST_LINE {
		return {}, fmt.tprintf("the first line is not \"%s\"", MEASURE_RECORD_FIRST_LINE)
	}
	if len(lines) < 2 || lines[len(lines) - 1] != MEASURE_RECORD_LAST_LINE {
		return {}, fmt.tprintf("the last line is not \"%s\": the file is not whole", MEASURE_RECORD_LAST_LINE)
	}
	numbers := make([dynamic]Measure_Record_Number, context.temp_allocator)
	boot_lines := make([dynamic]string, context.temp_allocator)
	for line, index in lines[1:len(lines) - 1] {
		line_number := index + 2
		key, value := line, ""
		if space := strings.index_byte(line, ' '); space >= 0 {
			key = line[:space]
			value = line[space + 1:]
		}
		current: ^Measure_Record_Number
		if len(numbers) > 0 {
			current = &numbers[len(numbers) - 1]
		}
		switch key {
		case "time":
			record.time = value
		case "release":
			record.release = value
		case "commit":
			record.commit = value == "unknown" ? "" : value
		case "tree":
			known := false
			for name, state in measure_tree_state_names {
				if name == value {
					record.tree = state
					known = true
				}
			}
			if !known {
				return {}, fmt.tprintf("line %d: the tree \"%s\" is not clean, changed or unknown", line_number, value)
			}
		case "host":
			record.host = value
		case "checks":
			checks, checks_ok := strconv.parse_int(value, 10)
			if !checks_ok || checks < 0 {
				return {}, fmt.tprintf("line %d: the count of checks \"%s\" is not a count", line_number, value)
			}
			record.checks_passed = checks
		case "number":
			append(&numbers, Measure_Record_Number{sentence = value})
		case "boot":
			append(&boot_lines, value)
		case "log", "line", "matching", "machine", "text", "absent":
			if current == nil {
				return {}, fmt.tprintf("line %d: \"%s\" before the first line \"number\"", line_number, key)
			}
			switch key {
			case "log":
				current.log = value
				current.found = true
			case "line", "matching":
				count, count_ok := strconv.parse_int(value, 10)
				if !count_ok || count < 1 {
					return {}, fmt.tprintf("line %d: \"%s\" is not a count of at least 1", line_number, value)
				}
				if key == "line" {
					current.line_number = count
				} else {
					current.matching_lines = count
				}
			case "machine":
				current.machine = value
			case "text":
				current.line = value
			case "absent":
				current.absent = value
			}
		case:
			return {}, fmt.tprintf("line %d: the key \"%s\" is not a key of the form", line_number, key)
		}
	}
	if record.time == "" || record.release == "" {
		return {}, "the line \"time\" or the line \"release\" is absent"
	}
	for number in numbers {
		if number.found == (number.absent != "") {
			return {}, fmt.tprintf("the number \"%s\" needs a line \"log\" or a line \"absent\", not both", number.sentence)
		}
		if number.found && (number.line_number == 0 || number.matching_lines == 0 || number.line == "") {
			return {}, fmt.tprintf("the number \"%s\" has a log but no line, count or text", number.sentence)
		}
	}
	record.numbers = numbers[:]
	record.boot_lines = boot_lines[:]
	return record, ""
}

// measure_record_write writes the record of the run that just passed: each
// number of `site_measures`, the lines of the start, and the facts of the
// run. A number that the table marks as required and that the logs of the
// run do not hold is a fault of the run: the record is not written.
measure_record_write :: proc(facts: Measure_Run_Facts) -> bool {
	names := measure_private_names_read()
	record := Measure_Record {
		time          = measure_time_text(time.now()),
		commit        = facts.commit,
		tree          = facts.tree,
		checks_passed = sync.atomic_load(&test_passed_count),
	}
	processor_information, _ := site_read_quiet("/proc/cpuinfo")
	record.host = measure_text_without_private(measure_host_text(processor_information, os.exists("/dev/kvm")), names)
	changelog_problems := make([dynamic]string, context.temp_allocator)
	changelog, changelog_ok := changelog_read(&changelog_problems)
	if !changelog_ok || len(changelog_problems) > 0 || len(changelog.releases) == 0 {
		problems_print(changelog_problems[:])
		fmt.eprintfln("kerneltool: %s is not written: the release of %s cannot be read", MEASURE_RECORD_FILE, CHANGELOG_FILE)
		return false
	}
	record.release = release_number_text(changelog.releases[0].number)

	numbers := make([dynamic]Measure_Record_Number, context.temp_allocator)
	holes := make([dynamic]string, context.temp_allocator)
	for measure in site_measures {
		number := measure_record_number_read(measure, facts.started, names)
		if !number.found {
			fmt.printfln("kerneltool: the run did not give the number \"%s\": %s", measure.sentence, number.absent)
			if measure.required {
				append(&holes, measure.sentence)
			}
		}
		append(&numbers, number)
	}
	if len(holes) > 0 {
		for hole in holes {
			fmt.eprintfln("kerneltool: test failed: the required number \"%s\" is not in the logs of the run", hole)
		}
		fmt.eprintfln("kerneltool: %s is not written: %d required numbers are absent", MEASURE_RECORD_FILE, len(holes))
		return false
	}
	record.numbers = numbers[:]

	// The lines of the start, from the log of the main machine of this run.
	main_log_information, main_log_error := os.stat(TEST_OUTPUT, context.temp_allocator)
	if main_log_error == nil && time.diff(facts.started, main_log_information.modification_time) >= 0 {
		if main_log, has_main_log := site_read_quiet(TEST_OUTPUT); has_main_log {
			record.boot_lines = measure_boot_lines(main_log, names)
		}
	}
	if len(record.boot_lines) == 0 {
		fmt.printfln("kerneltool: %s of this run has no line \"%s...\": the record has no stage of the start", TEST_OUTPUT, SITE_BOOT_STAGE_PREFIX)
	}

	text := measure_record_format(record)
	// The site reads the record: it must read back as it was written.
	if _, problem := measure_record_parse(text); problem != "" {
		fmt.eprintfln("kerneltool: %s is not written: it does not read back: %s", MEASURE_RECORD_FILE, problem)
		return false
	}
	make_folder(MEASURE_RECORD_FOLDER) or_return
	if error := os.write_entire_file(MEASURE_RECORD_FILE, transmute([]u8)text); error != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", MEASURE_RECORD_FILE, error)
		return false
	}
	found := 0
	for number in record.numbers {
		found += number.found ? 1 : 0
	}
	commit_text: string = record.commit != "" ? record.commit[:min(MEASURE_COMMIT_SHORT_LENGTH, len(record.commit))] : "unknown"
	fmt.printfln("kerneltool: wrote %s: %d of %d numbers, %d stages of the start, %d checks passed, the tree of %s (%s), the release %s", MEASURE_RECORD_FILE, found, len(record.numbers), len(record.boot_lines), record.checks_passed, commit_text, measure_tree_state_names[record.tree], record.release)
	return true
}
