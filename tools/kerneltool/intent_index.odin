// The intent folder (src/md/README.md; https://srcmd.org). A file of that
// folder records why a part of the system has its form. An agent reads the
// file index of the folder first, so a file that the index does not list is
// a file that nobody finds, and an entry with no file sends a reader
// nowhere. This check keeps the index and the files the same set, and each
// relative link of the folder on a file that exists.
package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// The folder of the intent files, from the root of the repository.
INTENT_FOLDER :: "src/md"
// The start of the path of each intent file.
INTENT_PREFIX :: INTENT_FOLDER + "/"
// The entry point of the folder: the overview and the file index.
INTENT_README :: "README.md"
// The heading of the file index, as the standard writes it.
INTENT_INDEX_HEADING :: "## File Index"

// One Markdown file of the intent folder.
Intent_File :: struct {
	path:    string, // From the intent folder: "features/palette.md".
	content: string,
}

// One relative link of an intent file.
Intent_Link :: struct {
	target: string, // As the file writes it, with no anchor: "../../docs/CONSOLE.md".
	line:   int, // The line of the link, from 1.
	text:   string, // The line that holds the link.
	after:  int, // The byte of the line after the ")" of the link: the labels of a pointer start there.
}

// intent_files_under adds each Markdown file of a folder and of its
// folders. inside is the path of the folder from the intent folder, or "".
intent_files_under :: proc(folder, inside: string, files: ^[dynamic]Intent_File) -> bool {
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if list_error != nil {
		return false
	}
	for entry in entries {
		path := strings.concatenate({folder, "/", entry.name}, context.temp_allocator)
		relative := strings.clone(entry.name, context.temp_allocator)
		if inside != "" {
			relative = strings.concatenate({inside, "/", entry.name}, context.temp_allocator)
		}
		if entry.type == .Directory {
			if !intent_files_under(path, relative, files) {
				return false
			}
		} else if strings.has_suffix(entry.name, ".md") {
			content, read_ok := site_read_quiet(path)
			if !read_ok {
				return false
			}
			append(files, Intent_File{path = relative, content = content})
		}
	}
	return true
}

// intent_files_read gives each Markdown file of the intent folder, in the
// order of the paths.
intent_files_read :: proc() -> (files: []Intent_File, ok: bool) {
	list := make([dynamic]Intent_File, context.temp_allocator)
	if !intent_files_under(INTENT_FOLDER, "", &list) {
		return nil, false
	}
	slice.sort_by(list[:], proc(first, second: Intent_File) -> bool {
		return first.path < second.path
	})
	return list[:], true
}

// intent_has_title tells whether the first heading of a file, outside the
// fences of code, is a heading of level 1.
intent_has_title :: proc(content: string) -> bool {
	fenced := false
	for line in site_lines(content) {
		if strings.has_prefix(strings.trim_space(line), "```") {
			fenced = !fenced
			continue
		}
		if fenced {
			continue
		}
		if level, _ := site_heading_level(line); level > 0 {
			return level == 1
		}
	}
	return false
}

// intent_links gives each link "[text](target)" of a file whose target is
// a path: outside the fences of code and outside a code span. A link to an
// address of another site and a link to a heading of the same file are not
// paths. A code span as the text of a link is read: the scan goes on after
// the span, at the "](" of the link.
intent_links :: proc(content: string) -> []Intent_Link {
	links := make([dynamic]Intent_Link, context.temp_allocator)
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
			if line[position] == '`' {
				span_end := strings.index_byte(line[position + 1:], '`')
				if span_end < 0 {
					break
				}
				position += span_end + 2
				continue
			}
			if line[position] != ']' || position + 1 >= len(line) || line[position + 1] != '(' {
				position += 1
				continue
			}
			target_end := strings.index_byte(line[position + 2:], ')')
			if target_end < 0 {
				break
			}
			target := line[position + 2:position + 2 + target_end]
			position += 2 + target_end + 1
			if anchor := strings.index_byte(target, '#'); anchor >= 0 {
				target = target[:anchor]
			}
			if target == "" || strings.contains(target, "://") || strings.has_prefix(target, "mailto:") {
				continue
			}
			append(&links, Intent_Link{target = target, line = line_index + 1, text = line, after = position})
		}
	}
	return links[:]
}

// intent_link_path gives the path, from the root of the repository, that a
// relative link names. file is the path of the file that holds the link,
// from the root. A link that leaves the repository gives no path.
intent_link_path :: proc(file, target: string) -> (path: string, ok: bool) {
	parts := make([dynamic]string, context.temp_allocator)
	folder := file[:max(strings.last_index_byte(file, '/'), 0)]
	for part in strings.split(folder, "/", context.temp_allocator) {
		if part != "" {
			append(&parts, part)
		}
	}
	if strings.has_prefix(target, "/") {
		return "", false
	}
	for part in strings.split(target, "/", context.temp_allocator) {
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			if len(parts) == 0 {
				return "", false
			}
			resize(&parts, len(parts) - 1)
			continue
		}
		append(&parts, part)
	}
	if len(parts) == 0 {
		return "", false
	}
	return strings.join(parts[:], "/", context.temp_allocator), true
}

// intent_index_entry reads one line of the file index: "- [text](target):
// description". The standard asks for one link and a brief description on
// each line.
intent_index_entry :: proc(line: string) -> (target: string, description: string, ok: bool) {
	if !strings.has_prefix(line, "- [") {
		return "", "", false
	}
	middle := strings.index(line, "](")
	if middle < 0 {
		return "", "", false
	}
	target_end := strings.index_byte(line[middle + 2:], ')')
	if target_end < 0 {
		return "", "", false
	}
	found := line[middle + 2:middle + 2 + target_end]
	rest := line[middle + 2 + target_end + 1:]
	if !strings.has_prefix(rest, ": ") {
		return "", "", false
	}
	words := strings.trim_space(rest[2:])
	if found == "" || words == "" {
		return "", "", false
	}
	return found, words, true
}

// intent_index_problems gives each fault of the intent folder: a file with
// no title, a link to a file that does not exist, a README with no file
// index, a line of the index that is not an entry, an entry that names no
// file, and a file that the index does not list exactly once.
// outside_exists tells whether a path from the root of the repository,
// outside the intent folder, exists: a host test gives its own answer.
intent_index_problems :: proc(files: []Intent_File, outside_exists: proc(path: string) -> bool) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	known := make(map[string]bool, context.temp_allocator)
	readme := -1
	for file, file_index in files {
		known[file.path] = true
		if file.path == INTENT_README {
			readme = file_index
		}
	}
	for file in files {
		from := strings.concatenate({INTENT_PREFIX, file.path}, context.temp_allocator)
		if !intent_has_title(file.content) {
			append(&problems, fmt.tprintf("%s: the first heading of the file is not a heading of level 1", from))
		}
		for link in intent_links(file.content) {
			path, inside_repository := intent_link_path(from, link.target)
			exists := false
			if inside_repository && strings.has_prefix(path, INTENT_PREFIX) {
				exists = path[len(INTENT_PREFIX):] in known
			} else if inside_repository {
				exists = outside_exists(path)
			}
			if !exists {
				append(&problems, fmt.tprintf("%s, line %d: the link to %s names no file of the repository", from, link.line, link.target))
			}
		}
	}
	if readme < 0 {
		append(&problems, fmt.tprintf("%s%s does not exist: the intent folder has no entry point", INTENT_PREFIX, INTENT_README))
		return problems[:]
	}
	listed := make(map[string]int, context.temp_allocator)
	index_headings := 0
	in_index := false
	fenced := false
	for line, line_index in site_lines(files[readme].content) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			fenced = !fenced
			continue
		}
		if fenced {
			continue
		}
		if level, _ := site_heading_level(line); level > 0 {
			in_index = line == INTENT_INDEX_HEADING
			if in_index {
				index_headings += 1
			}
			continue
		}
		if !in_index || trimmed == "" {
			continue
		}
		target, _, is_entry := intent_index_entry(line)
		if !is_entry {
			append(&problems, fmt.tprintf("%s%s, line %d: a line of the file index is one link and a description, \"- [path](path): description\"", INTENT_PREFIX, INTENT_README, line_index + 1))
			continue
		}
		if strings.has_prefix(target, "/") || strings.contains(target, "..") || strings.contains(target, "://") || strings.contains(target, "#") {
			append(&problems, fmt.tprintf("%s%s, line %d: the entry %s is not a path from the intent folder", INTENT_PREFIX, INTENT_README, line_index + 1, target))
			continue
		}
		if target == INTENT_README {
			append(&problems, fmt.tprintf("%s%s, line %d: the file index lists the other files, not itself", INTENT_PREFIX, INTENT_README, line_index + 1))
			continue
		}
		if !(target in known) {
			append(&problems, fmt.tprintf("%s%s, line %d: the entry %s names no file of the intent folder", INTENT_PREFIX, INTENT_README, line_index + 1, target))
			continue
		}
		listed[target] += 1
	}
	if index_headings != 1 {
		append(&problems, fmt.tprintf("%s%s has %d headings \"%s\": it has exactly one", INTENT_PREFIX, INTENT_README, index_headings, INTENT_INDEX_HEADING))
	}
	for file in files {
		if file.path == INTENT_README {
			continue
		}
		switch count := listed[file.path]; count {
		case 0:
			append(&problems, fmt.tprintf("%s%s is not in the file index of %s", INTENT_PREFIX, file.path, INTENT_README))
		case 1:
		case:
			append(&problems, fmt.tprintf("%s%s is %d times in the file index of %s", INTENT_PREFIX, file.path, count, INTENT_README))
		}
	}
	return problems[:]
}

// intent_repository_path_exists tells whether a path from the root of the
// repository exists: the answer of the check for a link that leaves the
// intent folder.
intent_repository_path_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

// intent_pointer_problems checks each link of an intent file to a guide
// that has the heading of a place after it:
// [`docs/CONSOLE.md`](../../docs/CONSOLE.md), "8. The palette provider".
// The link opens the guide for a reader of the repository; the labels are
// those of a pointer of a source comment, and they find their heading by
// the same rule. A link with no label names the guide alone.
intent_pointer_problems :: proc(site: ^Site, file: Intent_File) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	from := strings.concatenate({INTENT_PREFIX, file.path}, context.temp_allocator)
	for link in intent_links(file.content) {
		path, inside_repository := intent_link_path(from, link.target)
		if !inside_repository {
			continue
		}
		if _, is_document := site_document_path_end(path, 0); !is_document {
			continue
		}
		labels, _ := site_pointer_labels(link.text, link.after)
		if len(labels) == 0 {
			continue
		}
		if problem := site_pointer_problem(site, from, link.line, path, labels); problem != "" {
			append(&problems, problem)
		}
	}
	return problems[:]
}

// intent_index_check refuses an intent folder whose file index and whose
// files are not the same set (src/md/README.md, "The rules of this
// folder").
intent_index_check :: proc() -> bool {
	files, read_ok := intent_files_read()
	if !read_ok {
		fmt.eprintfln("kerneltool: test failed: cannot read the Markdown files of %s", INTENT_FOLDER)
		return false
	}
	problems := intent_index_problems(files, intent_repository_path_exists)
	for problem in problems {
		fmt.eprintfln("kerneltool: test failed: %s", problem)
	}
	if len(problems) > 0 {
		return false
	}
	test_passed_print("the file index of %s%s lists each of the %d other files of the folder once, each file has its title, and each link of the folder names a file", INTENT_PREFIX, INTENT_README, len(files) - 1)
	return true
}
