// The check of the source paths in the documents
// (docs/TOOLS.md, "The source paths in the documents"). A code span of a
// guide that names a file of the repository is a link on the site; a span
// whose file is gone stays plain code, with no error, and the link is lost
// in silence. So a move or a rename of a source must change each document
// that names it, and this check is the proof: it refuses a span that
// starts as a source path and names nothing.
package kerneltool

import "core:fmt"
import "core:strings"

// The documents of docs/ that the check does not read: each is a record
// of its time. A choice or a decision of the past can name a file that
// was removed later, and that is not a fault of the record.
SOURCE_PATH_UNREAD_DOCUMENTS :: [?]string{"FIRST_MILESTONE.md", "HANDOFF.md", "REVIEWS.md", "DECISIONS.md"}

// The documents of the root of the repository that the check reads.
SOURCE_PATH_ROOT_DOCUMENTS :: [?]string{"README.md", "AGENTS.md"}

DOCUMENT_FOLDER :: "docs"

// One document that the check reads.
Source_Path_Document :: struct {
	path:    string, // From the root of the repository.
	content: string,
}

// source_path_starts gives each text that starts a source path in a code
// span, with its "/": for each folder of the sources, its path and the
// last part of its path. The last part is the name that the folder had at
// the root: a span that still starts with it after a move is read, and is
// refused, so it cannot stay in a document.
//
// The first part of a path that has more parts is not a start: a design
// names, under that part, a folder of a later state or of a refused form,
// and such a span names nothing on purpose.
source_path_starts :: proc(folders: []string) -> []string {
	starts := make([dynamic]string, context.temp_allocator)
	add :: proc(known_starts: ^[dynamic]string, name: string) {
		start := strings.concatenate({name, "/"}, context.temp_allocator)
		for known in known_starts^ {
			if known == start {
				return
			}
		}
		append(known_starts, start)
	}
	for folder in folders {
		add(&starts, folder)
		add(&starts, folder[strings.last_index_byte(folder, '/') + 1:])
	}
	return starts[:]
}

// source_path_name_byte tells whether a byte can be in the name of a file
// or of a folder of the sources, or between two names.
source_path_name_byte :: proc(character: u8) -> bool {
	switch character {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.', '-', '/':
		return true
	}
	return false
}

// source_path_of_span gives the path that a code span names, when the span
// starts as a source path. A span that only holds the name of a source
// folder inside a longer path ("build/modules/x", "docs/reference/modules/")
// or inside a word ("kerneltool") does not start as one.
//
// The path ends at the first byte that is not a byte of a name:
//   - a ":" (a line number: "kernel/enter.odin:34"), a space, a comma, a
//     semicolon, a parenthesis or a quote: the path before it is whole;
//   - each other byte ("*" of a pattern, "<" of a name that is not written
//     out): the last name is not whole, and the path is the folder before
//     it: "programs/*/main.odin" names the folder programs.
source_path_of_span :: proc(span: string, starts: []string) -> (path: string, is_source_path: bool) {
	for start in starts {
		if strings.has_prefix(span, start) {
			is_source_path = true
			break
		}
	}
	if !is_source_path {
		return "", false
	}
	end := 0
	for end < len(span) && source_path_name_byte(span[end]) {
		end += 1
	}
	path = span[:end]
	if end < len(span) {
		switch span[end] {
		case ':', ' ', ',', ';', ')', '"', '\'':
		case:
			path = path[:strings.last_index_byte(path, '/') + 1]
		}
	}
	// "kernel/" is the folder, and a period can end a sentence in the span.
	return strings.trim_right(path, "/."), true
}

// source_path_moved_place gives the place of a path that starts with the
// last part of the path of a source folder, under that folder: the path
// that a document must name after the folder moved. It gives "" when no
// such place exists.
source_path_moved_place :: proc(path: string, folders: []string, exists: proc(path: string) -> bool) -> string {
	for folder in folders {
		name := folder[strings.last_index_byte(folder, '/') + 1:]
		if name == folder || (path != name && !strings.has_prefix(path, strings.concatenate({name, "/"}, context.temp_allocator))) {
			continue
		}
		place := strings.concatenate({folder, path[len(name):]}, context.temp_allocator)
		if exists(place) {
			return place
		}
	}
	return ""
}

// source_path_problems reads the code spans of one document, outside the
// fences of code: a fence holds a tree or a log, not a pointer. It gives
// one sentence for each span that starts as a source path and names no
// file and no folder, and the count of the spans that it read as source
// paths. A path is read from the root of the repository.
source_path_problems :: proc(file, content: string, folders: []string, exists: proc(path: string) -> bool) -> (problems: []string, span_count: int) {
	list := make([dynamic]string, context.temp_allocator)
	starts := source_path_starts(folders)
	fenced := false
	for line, line_index in site_lines(content) {
		if strings.has_prefix(strings.trim_space(line), "```") {
			fenced = !fenced
			continue
		}
		if fenced {
			continue
		}
		position := 0
		for position < len(line) {
			open := strings.index_byte(line[position:], '`')
			if open < 0 {
				break
			}
			open += position
			closing := strings.index_byte(line[open + 1:], '`')
			if closing < 0 {
				break
			}
			span := line[open + 1:open + 1 + closing]
			position = open + 1 + closing + 1
			path, is_source_path := source_path_of_span(span, starts)
			if !is_source_path {
				continue
			}
			span_count += 1
			if path != "" && exists(path) {
				continue
			}
			if place := source_path_moved_place(path, folders, exists); place != "" {
				append(&list, fmt.tprintf("%s, line %d: the code span `%s` names %s, which is now %s: write the path from the root of the repository", file, line_index + 1, span, path, place))
			} else {
				append(&list, fmt.tprintf("%s, line %d: the code span `%s` names %s, and the repository has no such file and no such folder", file, line_index + 1, span, path))
			}
		}
	}
	return list[:], span_count
}

// source_path_documents_read gives each document that the check reads:
// the documents of docs/ but the records of their time, the documents of
// the root, and the intent files.
source_path_documents_read :: proc() -> (documents: []Source_Path_Document, ok: bool) {
	list := make([dynamic]Source_Path_Document, context.temp_allocator)
	unread := SOURCE_PATH_UNREAD_DOCUMENTS
	paths := make([dynamic]string, context.temp_allocator)
	guides := files_with_suffix(DOCUMENT_FOLDER, ".md") or_return
	for guide in guides {
		is_unread := false
		for name in unread {
			is_unread ||= strings.has_suffix(guide, strings.concatenate({"/", name}, context.temp_allocator))
		}
		if !is_unread {
			append(&paths, guide)
		}
	}
	roots := SOURCE_PATH_ROOT_DOCUMENTS
	for root in roots {
		append(&paths, root)
	}
	for path in paths {
		content, read_ok := site_read_quiet(path)
		if !read_ok {
			fmt.eprintfln("kerneltool: test failed: cannot read %s", path)
			return nil, false
		}
		append(&list, Source_Path_Document{path = path, content = content})
	}
	intent_files, intent_ok := intent_files_read()
	if !intent_ok {
		fmt.eprintfln("kerneltool: test failed: cannot read the Markdown files of %s", INTENT_FOLDER)
		return nil, false
	}
	for intent_file in intent_files {
		append(&list, Source_Path_Document{path = strings.concatenate({INTENT_PREFIX, intent_file.path}, context.temp_allocator), content = intent_file.content})
	}
	return list[:], true
}

// source_path_problems_of_the_repository reads each document of the
// repository that the check reads, with the folders of the sources of the
// tool.
source_path_problems_of_the_repository :: proc() -> (problems: []string, span_count: int, document_count: int, ok: bool) {
	documents := source_path_documents_read() or_return
	list := make([dynamic]string, context.temp_allocator)
	folders := SOURCE_FOLDERS
	for document in documents {
		document_problems, document_spans := source_path_problems(document.path, document.content, folders[:], intent_repository_path_exists)
		append(&list, ..document_problems)
		span_count += document_spans
	}
	return list[:], span_count, len(documents), true
}

// source_paths_check refuses a document whose code span starts with the
// name of a folder of the sources and names no file and no folder.
source_paths_check :: proc() -> bool {
	problems, span_count, document_count, read_ok := source_path_problems_of_the_repository()
	if !read_ok {
		return false
	}
	for problem in problems {
		fmt.eprintfln("kerneltool: test failed: %s", problem)
	}
	if len(problems) > 0 {
		return false
	}
	test_passed_print("each of the %d code spans of the %d documents (the guides, the glossary, the documents of the root and the intent files) that starts as the path of a source names a file or a folder of the repository", span_count, document_count)
	return true
}
