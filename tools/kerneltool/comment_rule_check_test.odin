package kerneltool

import "core:fmt"
import "core:testing"

@(private = "file")
comment_rule_forms_of :: proc(file, content: string) -> []Comment_Rule_Form {
	forms := make([dynamic]Comment_Rule_Form, context.temp_allocator)
	no_exemption: map[string]string
	for breach in comment_rule_breaches_of_source(file, content, no_exemption) {
		append(&forms, breach.form)
	}
	return forms[:]
}

@(private = "file")
comment_rule_forms_contain :: proc(forms: []Comment_Rule_Form, form: Comment_Rule_Form) -> bool {
	for found in forms {
		if found == form {
			return true
		}
	}
	return false
}

@(test)
comment_rule_finds_the_example_of_each_form :: proc(t: ^testing.T) {
	for form in Comment_Rule_Form {
		example := comment_rules[form].example
		testing.expectf(t, example != "", "the form %v has no example", form)
		forms := comment_rule_forms_of("a.odin", fmt.tprintf("x := 1\n// %s\n", example))
		testing.expectf(t, comment_rule_forms_contain(forms, form), "the example of %v is not found: %q gives %v", form, example, forms)
	}
}

@(test)
comment_rule_finds_more_forms_of_each_kind :: proc(t: ^testing.T) {
	cases := [?]struct {
		comment: string,
		form:    Comment_Rule_Form,
	} {
		{"A demonstration of rights (properties 2 and 20).", .Property_Number},
		{"Property 7 sets the machine.", .Property_Number},
		{"the docs/PROPERTIES.md, property 10 of the code.", .Property_Number},
		{"the share (P20): no more.", .Property_Short_Label},
		{"the share (P13; docs/ARCHITECTURE.md).", .Property_Short_Label},
		{"the choices 334 to 346 of the network.", .Choice_Number},
		{"the work of step 91 of the milestone.", .Step_Number},
		{"A canvas that wraps (findings W4 and W-new): no fault.", .Review_Finding},
		{"a body that held a request (finding F12 of the read).", .Review_Finding},
		{"the record is refused (W-new).", .Review_Label_In_Parenthesis},
		{"the alignment of its fields (N48).", .Review_Label_In_Parenthesis},
		{"F1 and F2: a RST with data before RCV.NXT.", .Review_Label_At_Start},
		{"each name must come once (the Hostile reads of the server).", .Review_Name},
		{"the order of reviews 3 and 4.", .Review_Number},
		{"the wording (Notes 12 of the read).", .Review_Note},
		{"the order of the work (D-1).", .Decision_Identifier},
		{"the work-around of HANDOFF.md, item 53.", .Handoff_Item},
		{"Paging as a tool (owner decision).", .Decision_Maker},
		{"Added on 2026-11-11 at the end of the record.", .Decision_Date},
		{"Paging as a tool (the decision of 2026-11-10).", .Decision_Date},
	}
	for item in cases {
		forms := comment_rule_forms_of("a.odin", fmt.tprintf("// %s\n", item.comment))
		testing.expectf(t, comment_rule_forms_contain(forms, item.form), "%q: %v expected, %v found", item.comment, item.form, forms)
	}
}

// The forms that look like a breach and are not one: each one gives no
// breach.
@(test)
comment_rule_refuses_no_correct_comment :: proc(t: ^testing.T) {
	comments := [?]string {
		"The console reads it (docs/CONSOLE.md, section 3).",
		"The rule (docs/MODULE_CONTRACT.md, sections 4 and 5; docs/ARCHITECTURE.md, U3).",
		"Across calls (docs/MODULE_CONTRACT.md, \"Did not fit, across calls\").",
		"The tests (docs/FIRST_MILESTONE.md, \"Faults of the library from the hostile read\").",
		"A key of P256 and X25519, hashed with SHA-256 and BLAKE3.",
		"The opcode 0xC2 and the field C2_FIELD; the bytes C2 0F 1A; the register FC2.",
		"A page of 4 KiB at 0x10, the port 4433, a size of 16 MiB.",
		"RFC 6582 3.2, step 4: recover is the highest sequence sent.",
		"The steps 1 to 5 of the scenario, and the step 9.",
		"Montgomery ladder step: replaces (P2, P3) by (P2*2, P2+P3).",
		"The magic \"P6\", the width, the height.",
		"The clock writes \"2026-11-11 16:30:05\" when the system has a date.",
		"The kernel of 2026-11-12 has 31 145 instructions in its listing.",
		"The pointer theme of the owner, and the owner of an interrupt.",
		"The hostile input of a program, and an independent implementation.",
		"A note of the wording, and the decision of a program.",
		"K1. Handle table is the heading; U2b is a label of a section.",
		"The release dev-2026-11a of Odin, and the file 2026-11-11-paper-mono.md.",
		"A review of the code, and the steps of a review.",
		"The kind D-type of a disk, and AD-12 of a standard.",
	}
	for comment in comments {
		forms := comment_rule_forms_of("a.odin", fmt.tprintf("// %s\n", comment))
		testing.expectf(t, len(forms) == 0, "%q is not a breach: %v found", comment, forms)
	}
}

// The text of a string is not a comment, also with a marker inside it, and
// a rune literal does not open a string that hides the comment after it.
@(test)
comment_rule_reads_comments_only :: proc(t: ^testing.T) {
	testing.expect_value(t, len(comment_rule_forms_of("a.odin", "text := \"// (property 14)\"\n")), 0)
	testing.expect_value(t, len(comment_rule_forms_of("a.odin", "text := \"a \\\" // (property 14)\"\n")), 0)
	testing.expect(t, comment_rule_forms_contain(comment_rule_forms_of("a.odin", "quote := '\"' // the share (P20).\n"), .Property_Short_Label))
	testing.expect(t, comment_rule_forms_contain(comment_rule_forms_of("a.asm", "\tmov al, ';' ; the ring (property 4).\n"), .Property_Number))
	testing.expect(t, comment_rule_forms_contain(comment_rule_forms_of("flake.nix", "  url = \"github:a/b#c\"; # the machine (property 7).\n"), .Property_Number))
	testing.expect_value(t, len(comment_rule_forms_of("flake.nix", "  url = \"github:a/b#property 7\";\n")), 0)
	testing.expect_value(t, len(comment_rule_forms_of("a.txt", "// (property 14)\n")), 0)
}

// The lines of comment that follow each other are one text: a form that a
// line break cuts is found, at the line where it starts.
@(test)
comment_rule_gives_the_line_of_a_breach :: proc(t: ^testing.T) {
	no_exemption: map[string]string
	content := "package a\n\n// A module of commands (property\n// 19). It has no entry.\nx := 1 // The share (P20).\n"
	breaches := comment_rule_breaches_of_source("a.odin", content, no_exemption)
	testing.expect_value(t, len(breaches), 2)
	if len(breaches) == 2 {
		testing.expect_value(t, breaches[0].form, Comment_Rule_Form.Property_Number)
		testing.expect_value(t, breaches[0].line, 3)
		testing.expect_value(t, breaches[0].text, "property 19")
		testing.expect_value(t, breaches[1].form, Comment_Rule_Form.Property_Short_Label)
		testing.expect_value(t, breaches[1].line, 5)
		testing.expect_value(t, breaches[1].text, "(P20)")
	}
}

// A file that a manifest of the exemptions lists is not read: the header of
// a copied file gives the date of its copy.
@(test)
comment_rule_does_not_read_an_exempt_file :: proc(t: ^testing.T) {
	exempt_files := make(map[string]string, context.temp_allocator)
	exempt_files["support/cryptography/_example/copied.odin"] = "taken from Odin"
	content := "// Altered source: Odin dev-2026-11a, copied on 2026-11-11 (decision of the owner), only its imports changed.\npackage copied\n"
	testing.expect_value(t, len(comment_rule_breaches_of_source("support/cryptography/_example/copied.odin", content, exempt_files)), 0)
	testing.expect(t, len(comment_rule_breaches_of_source("support/cryptography/_example/written.odin", content, exempt_files)) > 0)
}

// The exemptions come from the manifest of the files that the system takes
// from Odin; the system writes the other files of src/library/support/cryptography, and
// the check reads them.
@(test)
comment_rule_exemptions_are_the_copied_cryptography :: proc(t: ^testing.T) {
	exempt_files, ok := comment_rule_exempt_files()
	testing.expect(t, ok)
	testing.expect(t, (CRYPTOGRAPHY_FOLDER + "/_chacha20/chacha20.odin") in exempt_files)
	testing.expect(t, (CRYPTOGRAPHY_FOLDER + "/x25519/x25519.odin") in exempt_files)
	testing.expect(t, !((CRYPTOGRAPHY_FOLDER + "/vectors/vectors.odin") in exempt_files))
	testing.expect(t, !((SOURCE_FOLDER_KERNEL + "/schedule.odin") in exempt_files))
}

// The repository has no breach: the comments of each source give their
// reasons.
@(test)
comment_rule_repository_has_no_breach :: proc(t: ^testing.T) {
	breaches, files_read, ok := comment_rule_tree_breaches()
	testing.expect(t, ok)
	testing.expectf(t, files_read > 400, "%d files read", files_read)
	for breach in breaches {
		testing.expectf(t, false, "%s:%d: %v: %q", breach.file, breach.line, breach.form, breach.text)
	}
}
