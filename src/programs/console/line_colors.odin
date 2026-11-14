package console

// The colors of the code of the console (docs/CONSOLE.md, section 7): the
// edit line at each key, the line that the console writes back when the
// input enters it, and the rows of the completion list. The scanner of
// src/library/support/console_language gives what each part is; the console gives the
// roles of its names; the terminal maps each kind to a color.

import "modus:support/console_language"
import "modus:support/line_editor"
import "modus:support/system"
import terminal "modus:support/terminal"

// console_name_role gives what a name is for this console now: a command or
// an export, a command that makes a record, a service or a module that the
// console loaded, a variable. The tables have at most 256 commands, 8
// services, the loaded modules and 16 variables.
console_name_role :: proc "contextless" (data: rawptr, name: string) -> console_language.Name_Role {
	if name == "" {
		return .Unknown
	}
	for &item in commands[:command_count] {
		if item.name == name {
			return item.record != 0 ? console_language.Name_Role.Record : console_language.Name_Role.Function
		}
	}
	for &variable in variables {
		if variable.name_count > 0 && string(variable.name[:clamp(variable.name_count, 0, VARIABLE_NAME_SIZE)]) == name {
			return .Variable
		}
	}
	for &sandbox in sandboxes {
		if sandbox.service && !sandbox.quiet && sandbox.name == name {
			return .Module
		}
	}
	for &module_loaded in loaded[:loaded_count] {
		if module_loaded.name == name {
			return .Module
		}
	}
	return .Unknown
}

console_names := console_language.Name_Lookup {
	role_of = console_name_role,
}

// edit_runs gives the runs of the edit line: the prompt, then the line, with
// the caret at caret (a place in text).
edit_runs :: proc "contextless" (text: string, caret: int, runs: []terminal.Code_Run) -> int {
	return console_language.line_runs(text, len(PROMPT), caret, console_names, runs)
}

// echo_write writes the line that the input entered, after the prompt, as
// runs of text with the kind of each part: the terminal keeps it with its
// colors. A part with no kind is in the tone Strong, as the whole line was.
// The caller holds output_lock.
echo_write :: proc "contextless" (text: string) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	count := console_language.line_runs(text, 0, console_language.NO_CARET, console_names, runs[:])
	parts: [2 * terminal.CODE_RUN_LIMIT + 2]terminal.Run
	part_count := 0
	parts[part_count] = {PROMPT, {tone = .Accent}}
	part_count += 1
	written := 0 // The bytes of the line in the parts so far.
	for run in runs[:count] {
		start := int(run.start)
		end := start + int(run.length)
		if start > written {
			parts[part_count] = {text[written:start], {tone = .Strong}}
			part_count += 1
		}
		parts[part_count] = {text[start:end], {tone = .Strong, code = run.kind}}
		part_count += 1
		written = end
	}
	// The rest of the line: past the runs, or the whole line with none.
	parts[part_count] = {text[written:], {tone = .Strong}}
	part_count += 1
	terminal.line(&output, ..parts[:part_count])
}

// row_text_make writes the text of a row of the list as the terminal keeps
// it: the name and what it is, cut to RUN_LIMIT bytes together, the name
// first (terminal.list_row). The runs are made on these bytes, so each
// run is inside the row that the terminal checks.
row_text_make :: proc "contextless" (buffer: ^[terminal.RUN_LIMIT]u8, name, about: string) -> (row: string, name_length: int) {
	name_length = copy(buffer[:], name)
	about_length := copy(buffer[name_length:], about)
	return string(buffer[:name_length + about_length]), name_length
}

// row_runs gives the runs of a row of the list: its name, in the kind of
// what the name is, then what the console says about it. A name with a dot
// is a module, the dot and its export. A line of the history is a line of
// code; the name of a module or of a program in quotes is a text.
row_runs :: proc "contextless" (row: string, name_length: int, kind: line_editor.Candidate_Kind, runs: []terminal.Code_Run) -> int {
	count := 0
	name_kind := terminal.Code_Kind.None
	switch kind {
	case .Command, .Export:
		name_kind = .Function
	case .Record:
		name_kind = .Type
	case .Service:
		name_kind = .Module
	case .Module, .Program:
		name_kind = .Text
	case .Variable:
		name_kind = .Variable
	case .History_Line:
		count = console_language.line_runs(row[:name_length], 0, console_language.NO_CARET, console_names, runs)
	}
	if name_kind != .None {
		last_dot := -1
		if name_kind == .Function || name_kind == .Type {
			for index in 0 ..< name_length {
				if row[index] == '.' {
					last_dot = index
				}
			}
		}
		if last_dot > 0 {
			count = console_language.run_add(runs, count, 0, last_dot, .Module)
			count = console_language.run_add(runs, count, last_dot, last_dot + 1, .Operator)
			count = console_language.run_add(runs, count, last_dot + 1, name_length, name_kind)
		} else {
			count = console_language.run_add(runs, count, 0, name_length, name_kind)
		}
	}
	return count + console_language.signature_runs(row, name_length, runs[count:])
}

// candidate_row_runs writes the text of the row of a candidate, and its runs.
candidate_row_runs :: proc "contextless" (buffer: ^[terminal.RUN_LIMIT]u8, candidate: line_editor.Candidate, runs: []terminal.Code_Run) -> (row: string, name_length: int, count: int) {
	about: [160]u8
	writer := system.Writer {
		buffer = about[:],
	}
	candidate_about(&writer, candidate)
	row, name_length = row_text_make(buffer, candidate.name, system.written(&writer))
	return row, name_length, row_runs(row, name_length, candidate.kind, runs)
}
