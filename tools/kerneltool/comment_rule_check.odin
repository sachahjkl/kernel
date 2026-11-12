package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// A comment of a source gives the reason itself, in plain words
// (docs/TOOLS.md, "The comments of the sources"). The number of a
// property, of a choice or of a step, the label of a finding of a review,
// the identifier of a decision and the date of a decision are not a reason:
// a reader of the code does not know what they stand for. This check finds
// each of these forms in the comments of the sources. It reads a comment
// with the scanner that the site uses for the pointers to documents, so a
// comment is the same text for both. Each rule is narrow: a rule that
// refuses a correct comment costs more than a breach that it does not see.

// The folders whose sources the check reads, with their tests, and the
// sources at the root of the repository.
COMMENT_RULE_FOLDERS :: [?]string{"kernel", "boot", "runtime", "contract", "support", "modules", "programs", "tools"}
COMMENT_RULE_ROOT_FILES :: [?]string{"flake.nix"}

// The forms that a comment must not have.
Comment_Rule_Form :: enum {
	Property_Number, // "property", or "properties", then a number.
	Property_Short_Label, // "(P", one or two digits, then ")", ";" or ":".
	Choice_Number, // "choice", or "choices", then a number.
	Step_Number, // "step", or "steps", "after" or not, then a number of two digits or more: a step of an algorithm has one digit.
	Review_Finding, // "finding", or "findings", then a label: a capital letter, then one or two digits or "-new".
	Review_Label_In_Parenthesis, // A label of a finding alone in a parenthesis, of the letters that the reviews use.
	Review_Label_At_Start, // A label of a finding, or two joined by "and", then ": ", at the start of a comment.
	Review_Name, // One of the two names of the reviews, which comment_rule_match lists.
	Review_Number, // "review", or "reviews", then a number.
	Review_Note, // "note", or "notes", one or two digits, then " of the".
	Decision_Identifier, // A capital D, a hyphen, then a number.
	Handoff_Item, // "HANDOFF", then " item " and a number.
	Decision_Maker, // The word "decision" with the owner or the coordinator, in the three phrases that comment_rule_match lists.
	Decision_Date, // A date "20yy-mm-dd" with "owner", "decision", "decided", "added on" or "coordinator" in the 48 bytes before it.
}

// One rule: a comment that breaks it, and what the breach names.
Comment_Rule :: struct {
	example: string, // The text of a comment that breaks the rule: the host tests find each one.
	names:   string, // What the comment names, in the message of a breach.
}

@(rodata)
comment_rules := [Comment_Rule_Form]Comment_Rule {
	.Property_Number             = {"the caller owns all memory (property 14).", "a property by its number"},
	.Property_Short_Label        = {"a program must not pay for the work of another (P20).", "a property by its short label"},
	.Choice_Number               = {"copy the name before the checks (choice 186).", "a choice by its number"},
	.Step_Number                 = {"the faults that a read found (the step after 309).", "a step by its number"},
	.Review_Finding              = {"the argument and why (finding W8).", "a finding of a review by its label"},
	.Review_Label_In_Parenthesis = {"the span of the next parameter (N2).", "a finding of a review by its label"},
	.Review_Label_At_Start       = {"W2: outside recovery, recover follows the acknowledged edge.", "a finding of a review by its label"},
	.Review_Name                 = {"each name must follow the rules (an independent read).", "a review by its name"},
	.Review_Number               = {"the table of Review 10.", "a review by its number"},
	.Review_Note                 = {"closes them (note 1 of the second read).", "a note of a review by its number"},
	.Decision_Identifier         = {"the limit of a boot (D-047).", "a decision by its identifier"},
	.Handoff_Item                = {"the work-around of HANDOFF item 53.", "an item of the handoff by its number"},
	.Decision_Maker              = {"the Append rule across calls (decision of the coordinator).", "who made a decision"},
	.Decision_Date               = {"a boot timed out (owner, 2026-11-11).", "the date of a decision"},
}

// A file that the check does not read. The table names a manifest: each
// line of the manifest starts with the path of a file that it lists.
Comment_Rule_Exemption :: struct {
	manifest: string,
	reason:   string,
}

@(rodata)
comment_rule_exemptions := [?]Comment_Rule_Exemption {
	{CRYPTOGRAPHY_MANIFEST, "a file taken from the cryptography of Odin: `kerneltool cryptography-origin` proves that it is its origin with listed changes only, so its comments are those of Odin, and its header gives the release of the copy"},
}

// One comment that breaks a rule.
Comment_Rule_Breach :: struct {
	file: string,
	line: int, // From 1.
	form: Comment_Rule_Form,
	text: string, // The words of the comment that break the rule.
}

// The letters of the labels of the findings of the reviews.
COMMENT_RULE_REVIEW_LETTERS :: "BCFKNW"
COMMENT_RULE_CAPITAL_LETTERS :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
// The bytes before a date that the check reads for a word of a decision.
COMMENT_RULE_DATE_WINDOW :: 48

@(private = "file")
comment_rule_word_starts :: proc(text: string, at: int) -> bool {
	return at == 0 || !(site_is_word_byte(text[at - 1]) || text[at - 1] == '-')
}

@(private = "file")
comment_rule_word_ends :: proc(text: string, end: int) -> bool {
	return end >= len(text) || !site_is_word_byte(text[end])
}

@(private = "file")
comment_rule_digits_end :: proc(text: string, at: int) -> int {
	end := at
	for end < len(text) && text[end] >= '0' && text[end] <= '9' {
		end += 1
	}
	return end
}

// comment_rule_prefix_end gives the byte after the first of words that
// starts at an index of a text.
@(private = "file")
comment_rule_prefix_end :: proc(text: string, at: int, words: []string) -> (end: int, found: bool) {
	for word in words {
		if strings.has_prefix(text[at:], word) {
			return at + len(word), true
		}
	}
	return 0, false
}

// comment_rule_number_follows tells whether a digit is at an index.
@(private = "file")
comment_rule_number_follows :: proc(text: string, at: int) -> bool {
	return at < len(text) && text[at] >= '0' && text[at] <= '9'
}

// comment_rule_label_end reads a label of a finding at an index: one of
// letters, then one or two digits or "-new", then the end of a word.
@(private = "file")
comment_rule_label_end :: proc(text: string, at: int, letters: string) -> (end: int, found: bool) {
	if at >= len(text) || strings.index_byte(letters, text[at]) < 0 {
		return 0, false
	}
	after := at + 1
	if strings.has_prefix(text[after:], "-new") {
		end = after + len("-new")
	} else {
		end = comment_rule_digits_end(text, after)
		if end == after || end - after > 2 {
			return 0, false
		}
	}
	return end, comment_rule_word_ends(text, end)
}

// comment_rule_date_end reads a date "20yy-mm-dd" at an index.
@(private = "file")
comment_rule_date_end :: proc(text: string, at: int) -> (end: int, found: bool) {
	if !strings.has_prefix(text[at:], "20") {
		return 0, false
	}
	// The digits of each part, from the start of the date.
	end = at
	for part_length, part_index in ([]int{4, 2, 2}) {
		if part_index > 0 {
			if end >= len(text) || text[end] != '-' {
				return 0, false
			}
			end += 1
		}
		if comment_rule_digits_end(text, end) != end + part_length {
			return 0, false
		}
		end += part_length
	}
	return end, comment_rule_word_ends(text, end)
}

// comment_rule_match tells whether a form starts at an index of the text of
// a comment, and gives the byte after it.
comment_rule_match :: proc(form: Comment_Rule_Form, text: string, at: int) -> (end: int, matched: bool) {
	if at >= len(text) {
		return 0, false
	}
	starts := comment_rule_word_starts(text, at)
	switch form {
	case .Property_Number:
		if !starts {
			return 0, false
		}
		end = comment_rule_prefix_end(text, at, {"property ", "Property ", "properties ", "Properties "}) or_return
		return comment_rule_digits_end(text, end), comment_rule_number_follows(text, end)
	case .Property_Short_Label:
		if !strings.has_prefix(text[at:], "(P") {
			return 0, false
		}
		end = comment_rule_digits_end(text, at + 2)
		if end == at + 2 || end - (at + 2) > 2 || end >= len(text) || strings.index_byte(");:", text[end]) < 0 {
			return 0, false
		}
		return end + 1, true
	case .Choice_Number:
		if !starts {
			return 0, false
		}
		end = comment_rule_prefix_end(text, at, {"choice ", "Choice ", "choices ", "Choices "}) or_return
		return comment_rule_digits_end(text, end), comment_rule_number_follows(text, end)
	case .Step_Number:
		if !starts {
			return 0, false
		}
		end = comment_rule_prefix_end(text, at, {"step ", "Step ", "steps ", "Steps "}) or_return
		if strings.has_prefix(text[end:], "after ") {
			end += len("after ")
		}
		number_end := comment_rule_digits_end(text, end)
		return number_end, number_end - end >= 2 && comment_rule_word_ends(text, number_end)
	case .Review_Finding:
		if !starts {
			return 0, false
		}
		end = comment_rule_prefix_end(text, at, {"finding ", "Finding ", "findings ", "Findings "}) or_return
		return comment_rule_label_end(text, end, COMMENT_RULE_CAPITAL_LETTERS)
	case .Review_Label_In_Parenthesis:
		if text[at] != '(' {
			return 0, false
		}
		end = comment_rule_label_end(text, at + 1, COMMENT_RULE_REVIEW_LETTERS) or_return
		if end >= len(text) || text[end] != ')' {
			return 0, false
		}
		return end + 1, true
	case .Review_Label_At_Start:
		if at != 0 {
			return 0, false
		}
		end = comment_rule_label_end(text, 0, COMMENT_RULE_REVIEW_LETTERS) or_return
		if strings.has_prefix(text[end:], " and ") {
			end = comment_rule_label_end(text, end + len(" and "), COMMENT_RULE_REVIEW_LETTERS) or_return
		}
		return end + 1, strings.has_prefix(text[end:], ": ")
	case .Review_Name:
		if !starts {
			return 0, false
		}
		end = comment_rule_prefix_end(text, at, {"hostile read", "Hostile read", "independent read", "Independent read"}) or_return
		if end < len(text) && text[end] == 's' {
			end += 1
		}
		return end, comment_rule_word_ends(text, end)
	case .Review_Number:
		if !starts {
			return 0, false
		}
		end = comment_rule_prefix_end(text, at, {"review ", "Review ", "reviews ", "Reviews "}) or_return
		return comment_rule_digits_end(text, end), comment_rule_number_follows(text, end)
	case .Review_Note:
		if !starts {
			return 0, false
		}
		end = comment_rule_prefix_end(text, at, {"note ", "Note ", "notes ", "Notes "}) or_return
		number_end := comment_rule_digits_end(text, end)
		if number_end == end || number_end - end > 2 || !strings.has_prefix(text[number_end:], " of the") {
			return 0, false
		}
		return number_end + len(" of the"), true
	case .Decision_Identifier:
		if !starts || !strings.has_prefix(text[at:], "D-") {
			return 0, false
		}
		end = comment_rule_digits_end(text, at + 2)
		return end, end > at + 2 && end - (at + 2) <= 4 && comment_rule_word_ends(text, end)
	case .Handoff_Item:
		if !starts || !strings.has_prefix(text[at:], "HANDOFF") {
			return 0, false
		}
		end = at + len("HANDOFF")
		if strings.has_prefix(text[end:], ".md") {
			end += len(".md")
		}
		if strings.has_prefix(text[end:], ",") {
			end += 1
		}
		if !strings.has_prefix(text[end:], " item ") {
			return 0, false
		}
		end += len(" item ")
		return comment_rule_digits_end(text, end), comment_rule_number_follows(text, end)
	case .Decision_Maker:
		if !starts {
			return 0, false
		}
		return comment_rule_prefix_end(text, at, {"decision of the owner", "Decision of the owner", "decision of the coordinator", "Decision of the coordinator", "owner decision", "Owner decision"})
	case .Decision_Date:
		if !starts {
			return 0, false
		}
		end = comment_rule_date_end(text, at) or_return
		before := text[max(0, at - COMMENT_RULE_DATE_WINDOW):at]
		for word in ([]string{"owner", "Owner", "decision", "Decision", "decided", "Decided", "added on", "Added on", "coordinator"}) {
			if strings.contains(before, word) {
				return end, true
			}
		}
		return 0, false
	}
	return 0, false
}

// comment_rule_text gives the text of a comment that the rules read, with
// the same offsets: the heading in quotes of each pointer to a document is
// blank. It is the text of a heading of a guide, which can name a review,
// not a word of the comment; the site checks that the heading exists.
comment_rule_text :: proc(text: string) -> string {
	pointers := site_document_pointers(text)
	if len(pointers) == 0 {
		return text
	}
	blanked := strings.clone(text, context.temp_allocator)
	bytes := transmute([]u8)blanked
	for pointer in pointers {
		for label in pointer.labels {
			quote := strings.index_byte(label, '"')
			if quote < 0 {
				continue
			}
			found := strings.index(text[pointer.start:pointer.end], label)
			if found < 0 {
				continue
			}
			for index in pointer.start + found + quote ..< pointer.start + found + len(label) {
				bytes[index] = ' '
			}
		}
	}
	return string(bytes)
}

// comment_rule_breaches_of_source gives each breach of the comments of one
// source file. A file of exempt_files, or a file that is not a source, has
// none.
comment_rule_breaches_of_source :: proc(file, content: string, exempt_files: map[string]string) -> []Comment_Rule_Breach {
	breaches := make([dynamic]Comment_Rule_Breach, context.temp_allocator)
	if file in exempt_files {
		return breaches[:]
	}
	syntax, known := comment_syntax_of(file)
	if !known {
		return breaches[:]
	}
	for block in comment_blocks(content, syntax) {
		text := comment_rule_text(block.text)
		for at in 0 ..< len(text) {
			for form in Comment_Rule_Form {
				if end, matched := comment_rule_match(form, text, at); matched {
					append(&breaches, Comment_Rule_Breach{file = file, line = comment_block_line(block, at), form = form, text = block.text[at:end]})
				}
			}
		}
	}
	return breaches[:]
}

// comment_rule_exempt_files gives each file that a manifest of the table of
// exemptions lists, with the reason of its exemption.
comment_rule_exempt_files :: proc() -> (files: map[string]string, ok: bool) {
	files = make(map[string]string, context.temp_allocator)
	for exemption in comment_rule_exemptions {
		lines := manifest_lines(exemption.manifest) or_return
		for fields in lines {
			if len(fields) > 0 {
				files[fields[0]] = exemption.reason
			}
		}
	}
	return files, true
}

// comment_rule_source_files adds each source file of a folder and of its
// folders, with the tests, to files.
comment_rule_source_files :: proc(folder: string, files: ^[dynamic]string) -> bool {
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if list_error != nil {
		fmt.eprintfln("kerneltool: cannot list %s: %v", folder, list_error)
		return false
	}
	for entry in entries {
		path := join(folder, "/", entry.name)
		if entry.type == .Directory {
			comment_rule_source_files(path, files) or_return
		} else if _, is_source := comment_syntax_of(entry.name); is_source {
			append(files, path)
		}
	}
	return true
}

// comment_rule_tree_breaches reads the comments of each source of the
// repository, from its root, and gives each breach and the count of the
// files that it read.
comment_rule_tree_breaches :: proc() -> (breaches: []Comment_Rule_Breach, files_read: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := COMMENT_RULE_FOLDERS
	for folder in folders {
		comment_rule_source_files(folder, &files) or_return
	}
	root_files := COMMENT_RULE_ROOT_FILES
	append(&files, ..root_files[:])
	exempt_files := comment_rule_exempt_files() or_return
	list := make([dynamic]Comment_Rule_Breach, context.temp_allocator)
	for file in files {
		content, read_error := os.read_entire_file(file, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("kerneltool: cannot read %s: %v", file, read_error)
			return nil, 0, false
		}
		append(&list, ..comment_rule_breaches_of_source(file, string(content), exempt_files))
	}
	return list[:], len(files), true
}

// comment_rule_check runs the rules on the repository: each breach is a
// line of the output, and one breach fails the check.
comment_rule_check :: proc() -> bool {
	breaches, files_read := comment_rule_tree_breaches() or_return
	for breach in breaches {
		fmt.eprintfln("kerneltool: test failed: %s:%d: the comment names %s (\"%s\"): write the reason in plain words, or a pointer to a document and its heading (docs/<NAME>.md, \"<heading>\")", breach.file, breach.line, comment_rules[breach.form].names, breach.text)
	}
	if len(breaches) > 0 {
		return false
	}
	test_passed_print("no comment of a source names a property, a choice, a step, a review or a decision by its number, its label or its date (%d files read)", files_read)
	return true
}
