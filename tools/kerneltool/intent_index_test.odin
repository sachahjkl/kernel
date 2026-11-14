package kerneltool

import "core:strings"
import "core:testing"

@(private = "file")
GOOD_INTENT_README :: `# The intent

An overview. A guide: [` + "`docs/CONSOLE.md`" + `](../../docs/CONSOLE.md), "The palette provider".

` + "```" + `
## File Index
- [in/a/fence.md](in/a/fence.md): an example, not an entry
` + "```" + `

## File Index

- [features/palette.md](features/palette.md): the palette and its provider
- [infrastructure/build.md](infrastructure/build.md): the build of a module
`

@(private = "file")
GOOD_INTENT_FILE :: `# The palette

The build is in [infrastructure/build.md](../infrastructure/build.md#the-key).
A site: [the standard](https://srcmd.org). A place of this file: [below](#below).
A code span is not a link: ` + "`[text](nowhere.md)`" + `.
`

// The one document outside the intent folder that the test tree has.
@(private = "file")
test_outside_exists :: proc(path: string) -> bool {
	return path == "docs/CONSOLE.md"
}

@(private = "file")
good_intent_files :: proc() -> []Intent_File {
	files := make([]Intent_File, 3, context.temp_allocator)
	files[0] = {path = "README.md", content = GOOD_INTENT_README}
	files[1] = {path = "features/palette.md", content = GOOD_INTENT_FILE}
	files[2] = {path = "infrastructure/build.md", content = "# The build\n\nText.\n"}
	return files
}

// An index that lists each other file once, with links that name files,
// has no fault. An entry inside a fence of code is an example.
@(test)
intent_index_of_a_good_folder :: proc(t: ^testing.T) {
	problems := intent_index_problems(good_intent_files(), test_outside_exists)
	testing.expectf(t, len(problems) == 0, "%v", problems)
}

// Each fault of the folder is named, one at a time.
@(test)
intent_index_names_each_fault :: proc(t: ^testing.T) {
	Case :: struct {
		change: proc(files: []Intent_File) -> []Intent_File,
		words:  string,
	}
	cases := [?]Case {
		{proc(files: []Intent_File) -> []Intent_File {
				return files[1:]
			}, "does not exist"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content, _ = strings.replace_all(files[0].content, "\n## File Index\n\n-", "\n## Files\n\n-", context.temp_allocator)
				return files
			}, "has 0 headings"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content, _ = strings.replace_all(files[0].content, "- [infrastructure/build.md](infrastructure/build.md): the build of a module\n", "", context.temp_allocator)
				return files
			}, "infrastructure/build.md is not in the file index"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [features/palette.md](features/palette.md): a second time\n"}, context.temp_allocator)
				return files
			}, "features/palette.md is 2 times in the file index"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [data/absent.md](data/absent.md): a file that is not there\n"}, context.temp_allocator)
				return files
			}, "the entry data/absent.md names no file"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [features/palette.md](features/palette.md)\n"}, context.temp_allocator)
				return files
			}, "one link and a description"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [README.md](README.md): the index itself\n"}, context.temp_allocator)
				return files
			}, "not itself"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[0].content = strings.concatenate({files[0].content, "- [../../docs/CONSOLE.md](../../docs/CONSOLE.md): a guide\n"}, context.temp_allocator)
				return files
			}, "is not a path from the intent folder"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[2].content = "## The build\n\nText.\n"
				return files
			}, "infrastructure/build.md: the first heading of the file is not a heading of level 1"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[1].content = strings.concatenate({files[1].content, "See [the scheduler](scheduler.md).\n"}, context.temp_allocator)
				return files
			}, "features/palette.md, line 6: the link to scheduler.md names no file"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[1].content = strings.concatenate({files[1].content, "See [a guide](../../docs/ABSENT.md).\n"}, context.temp_allocator)
				return files
			}, "the link to ../../docs/ABSENT.md names no file"},
		{proc(files: []Intent_File) -> []Intent_File {
				files[1].content = strings.concatenate({files[1].content, "See [outside](../../../other/file.md).\n"}, context.temp_allocator)
				return files
			}, "the link to ../../../other/file.md names no file"},
	}
	for test_case, case_index in cases {
		problems := intent_index_problems(test_case.change(good_intent_files()), test_outside_exists)
		found := false
		for problem in problems {
			found ||= strings.contains(problem, test_case.words)
		}
		testing.expectf(t, found, "case %d: no problem with the words %q in %v", case_index, test_case.words, problems)
	}
}

// The path that a relative link names, from the root of the repository.
@(test)
intent_link_paths :: proc(t: ^testing.T) {
	Case :: struct {
		file, target, path: string,
		ok:                 bool,
	}
	cases := [?]Case {
		{"src/md/README.md", "features/palette.md", "src/md/features/palette.md", true},
		{"src/md/features/palette.md", "../infrastructure/build.md", "src/md/infrastructure/build.md", true},
		{"src/md/features/palette.md", "./form.md", "src/md/features/form.md", true},
		{"src/md/features/palette.md", "../../../docs/CONSOLE.md", "docs/CONSOLE.md", true},
		{"src/md/README.md", "../../../outside.md", "", false},
		{"src/md/README.md", "/etc/hosts", "", false},
	}
	for test_case in cases {
		path, ok := intent_link_path(test_case.file, test_case.target)
		testing.expectf(t, path == test_case.path && ok == test_case.ok, "%s from %s: %q, %v", test_case.target, test_case.file, path, ok)
	}
}

// A link of an intent file to a guide, with the heading of a place after
// it, is a pointer: a heading that the guide does not have is a fault, a
// heading that it has is none, and a link with no label is not read.
@(test)
intent_pointers_to_a_guide :: proc(t: ^testing.T) {
	site := reference_test_site()
	good := Intent_File {
		path    = "features/kernel.md",
		content = "# The kernel\n\nSee [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md), \"Kernel systems\".\nAnd [the guide](../../docs/ARCHITECTURE.md) alone.\n",
	}
	testing.expectf(t, len(intent_pointer_problems(&site, good)) == 0, "%v", intent_pointer_problems(&site, good))
	stale := Intent_File {
		path    = "features/kernel.md",
		content = "# The kernel\n\nText.\n\nSee [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md), \"No such heading\".\n",
	}
	problems := intent_pointer_problems(&site, stale)
	testing.expectf(t, len(problems) == 1, "%v", problems)
	if len(problems) == 1 {
		testing.expect(t, strings.has_prefix(problems[0], "src/md/features/kernel.md, line 5: "), problems[0])
	}
}

// An intent file is a working record: a code span of a guide and a pointer
// of a comment that name one are references to the file in the repository,
// and a pointer to a file that the folder does not have is a fault.
@(test)
intent_files_are_working_records :: proc(t: ^testing.T) {
	testing.expect(t, site_is_working_record("src/md/README.md"))
	testing.expect(t, site_is_working_record("src/md/features/palette.md"))
	testing.expect(t, !site_is_working_record("src/programs/console/README.md"))
	end, found := site_document_path_end("see src/md/features/palette.md, \"The form\"", 4)
	testing.expect(t, found)
	testing.expect_value(t, end, len("see src/md/features/palette.md"))
	_, in_a_longer_path := site_document_path_end("other/src/md/README.md", len("other/"))
	testing.expect(t, !in_a_longer_path)
	_, not_markdown := site_document_path_end("src/md/features/palette.odin", 0)
	testing.expect(t, !not_markdown)
	pointers := site_document_pointers("The form (src/md/README.md, \"File Index\") and docs/ARCHITECTURE.md.")
	testing.expect_value(t, len(pointers), 2)
	if len(pointers) == 2 {
		testing.expect_value(t, pointers[0].path, "src/md/README.md")
		testing.expect_value(t, len(pointers[0].labels), 1)
		testing.expect_value(t, pointers[1].path, "docs/ARCHITECTURE.md")
	}
	site := reference_test_site()
	path, names_document := site_document_of_code_span(&site, "src/md/README.md")
	testing.expect(t, names_document)
	testing.expect_value(t, path, "src/md/README.md")
	targets := site_document_targets(&site, "src/md/README.md", []string{"\"File Index\""})
	testing.expect_value(t, len(targets), 1)
	if len(targets) == 1 {
		testing.expect(t, targets[0].outside && targets[0].resolved, "the file index of the intent folder is not found")
		testing.expect(t, strings.has_prefix(targets[0].link, SITE_REPOSITORY_ADDRESS + "/blob/master/src/md/README.md#L"), targets[0].link)
	}
	absent := site_pointer_problem(&site, "a.odin", 3, "src/md/features/no_such_file.md", nil)
	testing.expect(t, strings.contains(absent, "no such file"), absent)
}

// The intent folder of the repository passes its check.
@(test)
intent_index_of_the_repository :: proc(t: ^testing.T) {
	files, read_ok := intent_files_read()
	testing.expect(t, read_ok, "the intent folder cannot be read")
	problems := intent_index_problems(files, intent_repository_path_exists)
	testing.expectf(t, len(problems) == 0, "%d faults: %v", len(problems), problems)
}
