// The news of the system (docs/GLOSSARY.md, "News entry"; docs/SITE.md,
// "The news"). The changelog is a technical list for each release; a news
// entry is a dated report in prose, for a reader who is not a developer of
// the system, of one thing that a person can now see or use. Each entry is
// one file of news/, named by its date and its subject, never moved and
// never merged with another, as a fragment of the changelog is one file.
//
//   kerneltool news new <subject>   write news/<today>-<subject>.md with its head
//   kerneltool news check           every entry well formed, and each file that it names present
//
// The form of an entry, a head of "key: value" lines, an empty line, then
// the text in the Markdown of the site:
//
//   title: The console completes names
//   date: 2026-11-11
//   release: 0.73.0
//   picture: docs/screenshots/console_completion.png
//   kind: Shown
//   guide: docs/CONSOLE.md
//
//   The text: a few sentences, one fact in each.
package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

NEWS_FOLDER :: "news"
// The one file of the news folder that is not an entry.
NEWS_FOLDER_GUIDE :: "README.md"
// The longest text of an entry: a few sentences for a reader, not a guide.
// A longer report belongs in a guide of docs/, which the entry names.
NEWS_TEXT_LIMIT :: 1200
// The longest title: one line of a card and of a feed reader.
NEWS_TITLE_LIMIT :: 80
// The release of an entry whose thing is not in a release yet.
NEWS_NEXT_RELEASE :: "next"
// The value of picture or guide when the entry has none.
NEWS_NONE :: "none"
// "yyyy-mm-dd-": the date at the start of an entry name.
NEWS_DATE_LENGTH :: 11
// The folders that the picture of an entry can be in: the pictures that the
// machine test takes, and the files of the mark.
NEWS_PICTURE_FOLDERS :: [2]string{"docs/screenshots/", "resources/logo/"}
NEWS_KEYS :: [6]string{"title", "date", "release", "picture", "kind", "guide"}

// What an entry reports. The kind is the colored mark of its card.
News_Kind :: enum {
	Shown, // A person can now see or use a new thing in the running system.
	Measured, // A number about a thing that exists is measured, with its conditions.
	Decided, // The owner chose a thing that a person sees: a name, a mark, a font.
	Fixed, // A thing that a person saw fail now works.
}

news_kind_names := [News_Kind]string {
	.Shown    = "Shown",
	.Measured = "Measured",
	.Decided  = "Decided",
	.Fixed    = "Fixed",
}

News_Entry :: struct {
	file_name: string, // "2026-11-11-paper-mono.md"
	subject:   string, // "paper-mono"
	title:     string,
	date:      string, // yyyy-mm-dd
	release:   string, // A release number of CHANGELOG.md, or NEWS_NEXT_RELEASE.
	picture:   string, // A path of the repository, or NEWS_NONE.
	kind:      News_Kind,
	guide:     string, // A document of docs/, or NEWS_NONE.
	text:      string, // The Markdown of the text, with no head.
	text_line: int, // The line of the file where the text starts, from 1.
}

run_news :: proc(args: []string) -> int {
	usage_text :: "kerneltool news new <subject> | check"
	if len(args) == 2 && args[0] == "new" {
		return news_new(args[1]) ? 0 : EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "check" {
		return news_check() ? 0 : EXIT_FAILURE
	}
	fmt.eprintln(usage_text)
	return EXIT_USAGE
}

news_kind_parse :: proc(name: string) -> (kind: News_Kind, ok: bool) {
	for candidate in News_Kind {
		if news_kind_names[candidate] == name {
			return candidate, true
		}
	}
	return .Shown, false
}

// news_name_problem reads the name of an entry file: the date and the
// subject, or the fault of the name.
news_name_problem :: proc(file_name: string) -> (date: string, subject: string, problem: string) {
	expected :: "the name of a news entry is <yyyy-mm-dd>-<subject>.md"
	if !strings.has_suffix(file_name, ".md") || len(file_name) <= NEWS_DATE_LENGTH + len(".md") || file_name[NEWS_DATE_LENGTH - 1] != '-' {
		return "", "", expected
	}
	date = file_name[:NEWS_DATE_LENGTH - 1]
	if !date_text_valid(date) {
		return "", "", fmt.tprintf("%s: %s is not a date of the calendar", expected, date)
	}
	subject = file_name[NEWS_DATE_LENGTH:len(file_name) - len(".md")]
	if subject_problem_text := subject_problem(subject); subject_problem_text != "" {
		return "", "", fmt.tprintf("%s: %s", expected, subject_problem_text)
	}
	return date, subject, ""
}

// news_picture_problem gives the fault of the value of the key picture,
// with no read of a file, or "".
news_picture_problem :: proc(picture: string) -> string {
	if picture == NEWS_NONE {
		return ""
	}
	folders := NEWS_PICTURE_FOLDERS
	inside := false
	for folder in folders {
		inside ||= strings.has_prefix(picture, folder)
	}
	if !inside || !strings.has_suffix(picture, ".png") || strings.contains(picture, "..") || strings.contains_any(picture, " \\") {
		return fmt.tprintf("the picture %q is not a PNG file of docs/screenshots/ or resources/logo/, or \"none\"", picture)
	}
	return ""
}

// news_guide_problem gives the fault of the value of the key guide, with
// no read of a file, or "".
news_guide_problem :: proc(guide: string) -> string {
	if guide == NEWS_NONE {
		return ""
	}
	if !strings.has_prefix(guide, "docs/") || !strings.has_suffix(guide, ".md") || strings.contains(guide[len("docs/"):], "/") {
		return fmt.tprintf("the guide %q is not a document of docs/ (docs/<NAME>.md), or \"none\"", guide)
	}
	records := SITE_WORKING_RECORDS
	for record in records {
		if guide[len("docs/"):] == record {
			return fmt.tprintf("the guide %q is a working record of the project, not a page of the site", guide)
		}
	}
	return ""
}

// news_parse reads one entry and checks its form, with no read of another
// file. Each problem is one sentence that names the file and the line.
news_parse :: proc(file_name: string, content: string) -> (entry: News_Entry, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	entry.file_name = file_name
	place := strings.concatenate({NEWS_FOLDER, "/", file_name}, context.temp_allocator)
	name_date, subject, name_problem := news_name_problem(file_name)
	if name_problem != "" {
		append(&problems, fmt.tprintf("%s: %s", place, name_problem))
	}
	entry.subject = subject
	lines := strings.split(content, "\n", context.temp_allocator)

	// The head: "key: value" lines up to the first empty line.
	keys := NEWS_KEYS
	seen := make(map[string]int, context.temp_allocator) // A key to its line.
	index := 0
	for index < len(lines) && lines[index] != "" {
		line := lines[index]
		number := index + 1
		index += 1
		if strings.contains_any(line, "\t\r") {
			append(&problems, fmt.tprintf("%s, line %d: the line has a tab or a carriage return", place, number))
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			append(&problems, fmt.tprintf("%s, line %d: a line \"<key>: <value>\" of the head is expected, or an empty line before the text", place, number))
			continue
		}
		key := line[:colon]
		value := strings.trim_prefix(line[colon + 1:], " ")
		known := false
		for name in keys {
			known ||= name == key
		}
		if !known {
			append(&problems, fmt.tprintf("%s, line %d: the key %q is not known; the keys are title, date, release, picture, kind, guide", place, number, key))
			continue
		}
		if earlier, repeated := seen[key]; repeated {
			append(&problems, fmt.tprintf("%s, line %d: the key %s is also on the line %d", place, number, key, earlier))
			continue
		}
		seen[key] = number
		if value == "" || value != strings.trim_space(value) {
			append(&problems, fmt.tprintf("%s, line %d: the key %s has no value, or a space at the start or the end of its value", place, number, key))
			continue
		}
		switch key {
		case "title":
			entry.title = value
			if len(value) > NEWS_TITLE_LIMIT {
				append(&problems, fmt.tprintf("%s, line %d: the title has %d bytes; it can have at most %d", place, number, len(value), NEWS_TITLE_LIMIT))
			}
			if strings.contains_any(value, "`*[]<>") {
				append(&problems, fmt.tprintf("%s, line %d: the title is plain text: no ` * [ ] < >; a feed reader shows it as it is", place, number))
			}
		case "date":
			entry.date = value
			if !date_text_valid(value) {
				append(&problems, fmt.tprintf("%s, line %d: the date %q is not a date of the calendar yyyy-mm-dd", place, number, value))
			} else if name_date != "" && value != name_date {
				append(&problems, fmt.tprintf("%s, line %d: the date %s is not the date %s of the file name", place, number, value, name_date))
			}
		case "release":
			entry.release = value
			if _, number_ok := release_number_parse(value); !number_ok && value != NEWS_NEXT_RELEASE {
				append(&problems, fmt.tprintf("%s, line %d: the release %q is not a release number <major>.<minor>.<patch>, or \"next\"", place, number, value))
			}
		case "picture":
			entry.picture = value
			if problem := news_picture_problem(value); problem != "" {
				append(&problems, fmt.tprintf("%s, line %d: %s", place, number, problem))
			}
		case "kind":
			kind, kind_ok := news_kind_parse(value)
			entry.kind = kind
			if !kind_ok {
				append(&problems, fmt.tprintf("%s, line %d: the kind %q is not known; the kinds are Shown, Measured, Decided, Fixed", place, number, value))
			}
		case "guide":
			entry.guide = value
			if problem := news_guide_problem(value); problem != "" {
				append(&problems, fmt.tprintf("%s, line %d: %s", place, number, problem))
			}
		}
	}
	for key in keys {
		if key not_in seen {
			append(&problems, fmt.tprintf("%s: the head has no line \"%s: <value>\"", place, key))
		}
	}

	// The text, after the empty line.
	entry.text_line = index + 2
	text_lines: []string
	if index + 1 <= len(lines) {
		text_lines = lines[index + 1:]
	}
	entry.text = strings.trim_space(strings.join(text_lines, "\n", context.temp_allocator))
	if entry.text == "" {
		append(&problems, fmt.tprintf("%s, line %d: the text of the entry is expected after the empty line; it is empty", place, entry.text_line))
	}
	if len(entry.text) > NEWS_TEXT_LIMIT {
		append(&problems, fmt.tprintf("%s: the text has %d bytes; it can have at most %d: a longer report belongs in the guide that the entry names", place, len(entry.text), NEWS_TEXT_LIMIT))
	}
	for line, offset in text_lines {
		number := index + 2 + offset
		switch {
		case strings.contains_any(line, "\t\r"):
			append(&problems, fmt.tprintf("%s, line %d: the line has a tab or a carriage return", place, number))
		case strings.has_prefix(line, "#"):
			append(&problems, fmt.tprintf("%s, line %d: a heading in the text; the title of the entry is its heading", place, number))
		case strings.has_prefix(strings.trim_space(line), "<"):
			append(&problems, fmt.tprintf("%s, line %d: a line of HTML; the site renders the Markdown of docs/SITE.md only", place, number))
		}
	}
	return
}

// news_text gives the content of a new entry file: the head with the date,
// and no title and no text, so that `news check` fails until a person
// writes them.
news_text :: proc(date: string) -> string {
	return fmt.tprintf("title: \ndate: %s\nrelease: %s\npicture: %s\nkind: %s\nguide: %s\n\n", date, NEWS_NEXT_RELEASE, NEWS_NONE, news_kind_names[.Shown], NEWS_NONE)
}

// news_read reads each entry of a folder, newest first: the date starts
// the name, so the order of the names is the order of the dates.
news_read :: proc(folder: string, problems: ^[dynamic]string) -> []News_Entry {
	entries := make([dynamic]News_Entry, context.temp_allocator)
	if !os.exists(folder) {
		return nil
	}
	files, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		append(problems, fmt.tprintf("%s: cannot list the folder: %v", folder, err))
		return nil
	}
	for file in files {
		if file.name == NEWS_FOLDER_GUIDE {
			continue
		}
		if file.type == .Directory {
			append(problems, fmt.tprintf("%s/%s: a folder; the news folder holds only entry files", NEWS_FOLDER, file.name))
			continue
		}
		content, read_err := os.read_entire_file(strings.concatenate({folder, "/", file.name}, context.temp_allocator), context.temp_allocator)
		if read_err != nil {
			append(problems, fmt.tprintf("%s/%s: cannot read: %v", NEWS_FOLDER, file.name, read_err))
			continue
		}
		entry, entry_problems := news_parse(file.name, string(content))
		append(problems, ..entry_problems[:])
		append(&entries, entry)
	}
	slice.sort_by(entries[:], proc(a, b: News_Entry) -> bool {return a.file_name > b.file_name})
	return entries[:]
}

// news_files_problems checks what an entry names outside itself: the
// release is in CHANGELOG.md, the picture is a PNG file, the guide is a
// file, and no two entries have the same title.
news_files_problems :: proc(entries: []News_Entry, changelog: Changelog, problems: ^[dynamic]string) {
	releases := make(map[string]bool, context.temp_allocator)
	for changelog_release in changelog.releases {
		releases[release_number_text(changelog_release.number)] = true
	}
	titles := make(map[string]string, context.temp_allocator)
	for entry in entries {
		place := strings.concatenate({NEWS_FOLDER, "/", entry.file_name}, context.temp_allocator)
		if entry.release != "" && entry.release != NEWS_NEXT_RELEASE && entry.release not_in releases {
			append(problems, fmt.tprintf("%s: the release %s is not a release of %s; an entry whose thing is not released yet has \"release: next\"", place, entry.release, CHANGELOG_FILE))
		}
		if entry.picture != "" && entry.picture != NEWS_NONE && news_picture_problem(entry.picture) == "" {
			data, err := os.read_entire_file(entry.picture, context.temp_allocator)
			if _, _, is_png := site_png_size(data); err != nil || !is_png {
				append(problems, fmt.tprintf("%s: the picture %s is not a PNG file of the repository", place, entry.picture))
			}
		}
		if entry.guide != "" && entry.guide != NEWS_NONE && news_guide_problem(entry.guide) == "" && !os.exists(entry.guide) {
			append(problems, fmt.tprintf("%s: the guide %s is not a file of the repository", place, entry.guide))
		}
		if entry.title != "" {
			if other, found := titles[entry.title]; found {
				append(problems, fmt.tprintf("%s: the title \"%s\" is also the title of %s/%s", place, entry.title, NEWS_FOLDER, other))
			}
			titles[entry.title] = entry.file_name
		}
	}
}

// news_all_read reads CHANGELOG.md and the entries, and checks all.
news_all_read :: proc() -> (entries: []News_Entry, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	changelog, changelog_ok := changelog_read(&problems)
	entries = news_read(NEWS_FOLDER, &problems)
	if changelog_ok {
		news_files_problems(entries, changelog, &problems)
	}
	return
}

news_check :: proc() -> bool {
	entries, problems := news_all_read()
	if len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintfln("kerneltool: test failed: the news has %d problems", len(problems))
		return false
	}
	fmt.printfln("kerneltool: test passed: %s has %d news entries, all well formed, each picture, release and guide present", NEWS_FOLDER, len(entries))
	return true
}

news_new :: proc(subject: string) -> bool {
	if problem := subject_problem(subject); problem != "" {
		fmt.eprintfln("kerneltool: %s", problem)
		return false
	}
	now := local_date_and_time()
	date := fmt.tprintf("%04d-%02d-%02d", now.year, now.month, now.day)
	file_name := fmt.tprintf("%s-%s.md", date, subject)
	path := strings.concatenate({NEWS_FOLDER, "/", file_name}, context.temp_allocator)
	if os.exists(path) {
		fmt.eprintfln("kerneltool: %s exists; choose another subject", path)
		return false
	}
	if !os.exists(NEWS_FOLDER) {
		make_folder(NEWS_FOLDER) or_return
	}
	if err := os.write_entire_file(path, transmute([]u8)news_text(date)); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
		return false
	}
	fmt.printfln("kerneltool: wrote %s: write its title, its release, its picture, its kind, its guide and its text (%s); `kerneltool news check` names what is missing", path, NEWS_FOLDER + "/" + NEWS_FOLDER_GUIDE)
	return true
}
