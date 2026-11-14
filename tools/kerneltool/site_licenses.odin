// The tables of the licenses of the site (docs/SITE.md, "The licenses").
// One row for each thing that has a license, and a second table for what
// builds and tests the system and is not a part of it. Each cell comes from
// a file of the repository; a cell with no source says "not recorded", and
// the command lists those cells.
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

SITE_NOT_RECORDED :: "not recorded"
SITE_FLAKE_FILE :: "flake.nix"
SITE_FLAKE_LOCK_FILE :: "flake.lock"
SITE_FONT_FOLDER :: "resources/fonts"
SITE_SPLEEN_LICENSE_FILE :: SOURCE_FOLDER_SUPPORT + "/graphics/FONT_LICENSE"
SITE_PORTRAIT_LICENSE_FILE :: SOURCE_FOLDER_PROGRAMS + "/temple/PORTRAIT_LICENSE"
SITE_POSY_MANIFEST :: "resources/pointers/posy.manifest"
SITE_SYSTEM_POINTER_MANIFEST :: "resources/pointers/system.manifest"
SITE_ODIN_LICENSE_FILE :: CRYPTOGRAPHY_FOLDER + "/LICENSE.odin.txt"
SITE_FIAT_LICENSE_FILE :: CRYPTOGRAPHY_FOLDER + "/LICENSE.fiat-crypto.txt"

Site_License_Row :: struct {
	what:           string,
	place:          string, // A path of the repository, or "".
	license:        string, // An SPDX identifier, or the words of the file when it names no identifier.
	author:         string,
	author_address: string, // The address that the file records beside the author, or "".
	version:        string, // A version, a pinned commit, a hash.
	in_boot_image:  string,
}

Site_Licenses :: struct {
	system_rows: []Site_License_Row, // What the system holds.
	build_rows:  []Site_License_Row, // What builds and tests it, and is not a part of it.
	gaps:        []string, // Each cell that says "not recorded": "<row>: <column>".
}

// The license words that a file of the repository writes, and the SPDX
// identifier that each one names. This is a translation of recorded words,
// not a recorded fact: a phrase that is not here is shown as the file
// writes it.
@(rodata)
site_spdx_names := [?][2]string {
	{"SIL OFL 1.1", "OFL-1.1"},
	{"Bitstream Vera license", "Bitstream-Vera"},
	{"MIT License", "MIT"},
	{"MIT", "MIT"},
	{"CC-BY-NC-4.0", "CC-BY-NC-4.0"},
	{"BSD-1-Clause", "BSD-1-Clause"},
	{"zlib", "Zlib"},
}

site_spdx :: proc(words: string) -> string {
	for pair in site_spdx_names {
		if strings.has_prefix(words, pair[0]) {
			return pair[1]
		}
	}
	return words
}

// What a ".license" file beside a font subset records. The form: line 1 is
// the copyright, with the address of the source in parentheses at its end
// when the source gives one; a line "... carries the name "<family>"."; a
// line "License of the source: <words>.".
Site_Font_License :: struct {
	copyright: string,
	address:   string,
	family:    string,
	license:   string,
}

site_font_license_parse :: proc(file_name, content: string) -> (font: Site_Font_License, problem: string) {
	lines := site_lines(content)
	if len(lines) == 0 || strings.trim_space(lines[0]) == "" {
		return {}, fmt.tprintf("%s: line 1 must be the copyright", file_name)
	}
	font.copyright = strings.trim_space(lines[0])
	if open := strings.last_index(font.copyright, " (http"); open > 0 && strings.has_suffix(font.copyright, ")") {
		font.address = font.copyright[open + 2:len(font.copyright) - 1]
		font.copyright = font.copyright[:open]
	}
	FAMILY :: "carries the name \""
	LICENSE :: "License of the source: "
	for line in lines {
		if start := strings.index(line, FAMILY); start >= 0 {
			rest := line[start + len(FAMILY):]
			if end := strings.index_byte(rest, '"'); end > 0 {
				font.family = rest[:end]
			}
		}
		if strings.has_prefix(line, LICENSE) {
			font.license = strings.trim_suffix(strings.trim_space(line[len(LICENSE):]), ".")
		}
	}
	if font.family == "" {
		return {}, fmt.tprintf("%s: no line with %s<family>\"", file_name, FAMILY)
	}
	if font.license == "" {
		return {}, fmt.tprintf("%s: no line \"%s<words>.\"", file_name, LICENSE)
	}
	return font, ""
}

// What a pointer manifest records in its head: "theme <name>",
// "license <SPDX identifier>", and lines "attribution <text>".
Site_Pointer_Manifest :: struct {
	theme:       string,
	license:     string,
	attribution: []string,
}

site_pointer_manifest_parse :: proc(file_name, content: string) -> (manifest: Site_Pointer_Manifest, problem: string) {
	attribution := make([dynamic]string, context.temp_allocator)
	for line in site_lines(content) {
		switch {
		case strings.has_prefix(line, "theme "):
			manifest.theme = strings.trim_space(line[len("theme "):])
		case strings.has_prefix(line, "license "):
			manifest.license = strings.trim_space(line[len("license "):])
		case strings.has_prefix(line, "attribution "):
			append(&attribution, strings.trim_space(line[len("attribution "):]))
		}
	}
	manifest.attribution = attribution[:]
	if manifest.theme == "" || manifest.license == "" {
		return {}, fmt.tprintf("%s: a line \"theme <name>\" and a line \"license <identifier>\" are expected", file_name)
	}
	return manifest, ""
}

// One source that flake.nix pins for a vector font: a fetcher of the file
// at one commit, or a package of nixpkgs.
Site_Flake_Source :: struct {
	fetcher: string, // "paperMonoFile", or "" for a package.
	file:    string,
	hash:    string,
	nix_package: string, // "dejavu_fonts", or "" for a fetcher.
}

// A fetcher of flake.nix: "<name> = name: hash:" and, in its body, the
// line "url = "https://raw.githubusercontent.com/<owner>/<repository>/<commit>/...".
Site_Flake_Fetcher :: struct {
	owner, repository, commit: string,
}

// What the site reads in flake.nix. The forms it relies on, each a whole
// line after its indentation:
//   odinRelease = "<release>";
//   owner = "<owner>"; repo = "<repository>"; hash = "<hash>"; (the first ones after odinRelease)
//   buildTools = [<item> <item> ...];
//   config.allowUnfreePredicate = package: inputs.nixpkgs.lib.getName package == "<name>";
//   <fetcher> = name: hash: (and its url line)
//   "<font>=${<fetcher> "<file>" "<hash>"}" or "<font>=${pkgs.<package>}/<path>"
//   OVMF_CODE = "${pkgs.<package>.fd}/<path>";
//   FONT_SOURCE = "${pkgs.<package>}/<path>";
Site_Flake :: struct {
	odin_release:     string,
	odin_owner:       string,
	odin_repository:  string,
	odin_hash:        string,
	build_tools:      []string,
	unfree_allowed:   string,
	fetchers:         map[string]Site_Flake_Fetcher,
	font_sources:     map[string]Site_Flake_Source,
	firmware_package: string,
	spleen_package:   string,
}

// site_quoted gives the text between the first two quotes after start.
site_quoted :: proc(line: string, start: int = 0) -> (text: string, end: int, found: bool) {
	first := strings.index_byte(line[start:], '"')
	if first < 0 {
		return "", 0, false
	}
	first += start + 1
	second := strings.index_byte(line[first:], '"')
	if second < 0 {
		return "", 0, false
	}
	return line[first:first + second], first + second + 1, true
}

// site_package_after gives the name after "${pkgs." up to the next "." or "}".
site_package_after :: proc(line: string) -> string {
	start := strings.index(line, "${pkgs.")
	if start < 0 {
		return ""
	}
	rest := line[start + len("${pkgs."):]
	end := 0
	for end < len(rest) && rest[end] != '.' && rest[end] != '}' {
		end += 1
	}
	return rest[:end]
}

site_flake_parse :: proc(content: string) -> (flake: Site_Flake, problem: string) {
	flake.fetchers = make(map[string]Site_Flake_Fetcher, context.temp_allocator)
	flake.font_sources = make(map[string]Site_Flake_Source, context.temp_allocator)
	lines := site_lines(content)
	odin_line := -1
	current_fetcher := ""
	for raw_line, index in lines {
		line := strings.trim_space(raw_line)
		switch {
		case strings.has_prefix(line, "odinRelease = "):
			flake.odin_release, _, _ = site_quoted(line)
			odin_line = index
		case odin_line >= 0 && flake.odin_owner == "" && strings.has_prefix(line, "owner = "):
			flake.odin_owner, _, _ = site_quoted(line)
		case odin_line >= 0 && flake.odin_repository == "" && strings.has_prefix(line, "repo = "):
			flake.odin_repository, _, _ = site_quoted(line)
		case odin_line >= 0 && flake.odin_hash == "" && strings.has_prefix(line, "hash = \""):
			flake.odin_hash, _, _ = site_quoted(line)
		case strings.has_prefix(line, "buildTools = [") && strings.has_suffix(line, "];"):
			inner := line[len("buildTools = ["):len(line) - len("];")]
			tools := make([dynamic]string, context.temp_allocator)
			for item in strings.split(inner, " ", context.temp_allocator) {
				if item != "" {
					append(&tools, item)
				}
			}
			flake.build_tools = tools[:]
		case strings.has_prefix(line, "config.allowUnfreePredicate = "):
			flake.unfree_allowed, _, _ = site_quoted(line)
		case strings.has_suffix(line, " = name: hash:"):
			current_fetcher = line[:len(line) - len(" = name: hash:")]
		case current_fetcher != "" && strings.has_prefix(line, "url = \"https://raw.githubusercontent.com/"):
			address, _, _ := site_quoted(line)
			parts := strings.split(address[len("https://raw.githubusercontent.com/"):], "/", context.temp_allocator)
			if len(parts) >= 3 {
				flake.fetchers[current_fetcher] = {owner = parts[0], repository = parts[1], commit = parts[2]}
			}
			current_fetcher = ""
		case strings.has_prefix(line, "OVMF_CODE = "):
			flake.firmware_package = site_package_after(line)
		case strings.has_prefix(line, "FONT_SOURCE = "):
			flake.spleen_package = site_package_after(line)
		case strings.has_prefix(line, "\"") && strings.contains(line, "=${"):
			// A vector font source: "<font>=${...}".
			equal := strings.index(line, "=${")
			name := line[1:equal]
			rest := line[equal + len("=${"):]
			source: Site_Flake_Source
			if strings.has_prefix(rest, "pkgs.") {
				source.nix_package = site_package_after(line)
			} else {
				space := strings.index_byte(rest, ' ')
				if space < 0 {
					return {}, fmt.tprintf("%s, line %d: a font source \"<font>=${<fetcher> \"<file>\" \"<hash>\"}\" is expected", SITE_FLAKE_FILE, index + 1)
				}
				source.fetcher = rest[:space]
				end: int
				found: bool
				source.file, end, found = site_quoted(rest, space)
				hash_found: bool
				source.hash, _, hash_found = site_quoted(rest, end)
				if !found || !hash_found {
					return {}, fmt.tprintf("%s, line %d: a font source \"<font>=${<fetcher> \"<file>\" \"<hash>\"}\" is expected", SITE_FLAKE_FILE, index + 1)
				}
			}
			flake.font_sources[name] = source
		}
	}
	switch {
	case flake.odin_release == "" || flake.odin_owner == "" || flake.odin_repository == "" || flake.odin_hash == "":
		return {}, SITE_FLAKE_FILE + ": the lines odinRelease = \"<release>\", then owner = \"...\", repo = \"...\" and hash = \"...\" are expected"
	case len(flake.build_tools) == 0:
		return {}, SITE_FLAKE_FILE + ": the line buildTools = [<item> ...]; is expected"
	case flake.firmware_package == "":
		return {}, SITE_FLAKE_FILE + ": the line OVMF_CODE = \"${pkgs.<package>.fd}/...\" is expected"
	case len(flake.font_sources) == 0:
		return {}, SITE_FLAKE_FILE + ": no font source \"<font>=${...}\""
	}
	return flake, ""
}

// site_flake_lock_revision reads the commit of nixpkgs in flake.lock: the
// first line "rev": "<commit>" after the line "nixpkgs": {.
site_flake_lock_revision :: proc(content: string) -> (revision: string, problem: string) {
	in_nixpkgs := false
	for line in site_lines(content) {
		trimmed := strings.trim_space(line)
		if trimmed == "\"nixpkgs\": {" {
			in_nixpkgs = true
			continue
		}
		if in_nixpkgs && strings.has_prefix(trimmed, "\"rev\": \"") {
			text, _, found := site_quoted(trimmed, len("\"rev\":"))
			if found && text != "" {
				return text, ""
			}
		}
	}
	return "", SITE_FLAKE_LOCK_FILE + ": no line \"rev\": \"<commit>\" after the line \"nixpkgs\": {"
}

// site_line_after gives the rest of the first line that starts with start.
site_line_after :: proc(content, start: string) -> string {
	for line in site_lines(content) {
		if strings.has_prefix(line, start) {
			return strings.trim_space(line[len(start):])
		}
	}
	return ""
}

site_licenses_read :: proc(boot_image: []Site_Image_Entry, release_number: string) -> (licenses: Site_Licenses, ok: bool) {
	system_rows := make([dynamic]Site_License_Row, context.temp_allocator)
	build_rows := make([dynamic]Site_License_Row, context.temp_allocator)
	gaps := make([dynamic]string, context.temp_allocator)
	fail :: proc(problem: string) -> bool {
		fmt.eprintfln("kerneltool: site: %s", problem)
		return false
	}
	in_image :: proc(boot_image: []Site_Image_Entry, name: string) -> string {
		if len(boot_image) == 0 {
			return SITE_NOT_RECORDED
		}
		for entry in boot_image {
			if entry.name == name {
				return "yes"
			}
		}
		return "no"
	}

	flake_text := site_read(SITE_FLAKE_FILE) or_return
	flake, flake_problem := site_flake_parse(flake_text)
	if flake_problem != "" {
		return {}, fail(flake_problem)
	}
	lock_text := site_read(SITE_FLAKE_LOCK_FILE) or_return
	nixpkgs_revision, lock_problem := site_flake_lock_revision(lock_text)
	if lock_problem != "" {
		return {}, fail(lock_problem)
	}
	nixpkgs_version := strings.concatenate({"nixpkgs ", nixpkgs_revision[:min(12, len(nixpkgs_revision))]}, context.temp_allocator)

	// The system itself.
	license_text := site_read(SITE_LICENSE_FILE) or_return
	license_lines := site_lines(license_text)
	system_row := Site_License_Row {
		what          = SITE_SYSTEM_NAME,
		place         = SITE_LICENSE_FILE,
		license       = site_spdx(strings.trim_space(license_lines[0])),
		author        = site_line_after(license_text, "Copyright "),
		version       = release_number,
		in_boot_image = "yes",
	}
	if system_row.author != "" {
		system_row.author = strings.concatenate({"Copyright ", system_row.author}, context.temp_allocator)
	}
	append(&system_rows, system_row)

	// The fonts that the repository holds as subsets: the candidates, the
	// emphasis and the interface fonts of vector_fonts.odin.
	fonts := make([dynamic]Vector_Font_Candidate, context.temp_allocator)
	append(&fonts, ..vector_font_candidates[:])
	append(&fonts, ..vector_font_emphasis[:])
	append(&fonts, ..vector_font_interface[:])
	for candidate in fonts {
		file_name := strings.concatenate({SITE_FONT_FOLDER, "/", candidate.name, ".license"}, context.temp_allocator)
		text := site_read(file_name) or_return
		font, font_problem := site_font_license_parse(file_name, text)
		if font_problem != "" {
			return {}, fail(font_problem)
		}
		row := Site_License_Row {
			what           = font.family,
			place          = strings.concatenate({SITE_FONT_FOLDER, "/", candidate.name, ".ttf"}, context.temp_allocator),
			license        = site_spdx(font.license),
			author         = font.copyright,
			author_address = font.address,
		}
		if source, found := flake.font_sources[candidate.name]; found {
			if source.nix_package != "" {
				row.version = strings.concatenate({"package ", source.nix_package, ", ", nixpkgs_version}, context.temp_allocator)
			} else if fetcher, has_fetcher := flake.fetchers[source.fetcher]; has_fetcher {
				row.version = strings.concatenate({fetcher.owner, "/", fetcher.repository, " ", fetcher.commit[:min(12, len(fetcher.commit))], ", ", source.file, " ", source.hash}, context.temp_allocator)
			}
		}
		// The glyph caches of the boot image are made from the default font
		// and from its emphasis (vector_fonts.odin).
		row.in_boot_image = candidate.name == DEFAULT_VECTOR_FONT || candidate.name == EMPHASIS_VECTOR_FONT ? "yes, as a glyph cache" : "no"
		append(&system_rows, row)
	}

	// Spleen: the fallback font, compiled into support/graphics.
	spleen_text := site_read(SITE_SPLEEN_LICENSE_FILE) or_return
	spleen_lines := site_lines(spleen_text)
	spleen := Site_License_Row {
		what          = "Spleen 8x16",
		place         = SITE_SPLEEN_LICENSE_FILE,
		license       = SITE_NOT_RECORDED, // The file holds the text of the license, not its name.
		author        = site_line_after(spleen_text, "Copyright "),
		in_boot_image = "yes, in each program that draws text",
	}
	SPLEEN_ORIGIN :: "comes from Spleen 8x16 "
	if start := strings.index(spleen_lines[0], SPLEEN_ORIGIN); start >= 0 {
		spleen.version = strings.trim_space(spleen_lines[0][start + len(SPLEEN_ORIGIN):])
	}
	if len(spleen_lines) > 1 && strings.has_prefix(spleen_lines[1], "(http") {
		spleen.author_address = strings.trim_suffix(strings.trim_suffix(spleen_lines[1][1:], "."), ")")
	}
	if spleen.author != "" {
		spleen.author = strings.concatenate({"Copyright ", spleen.author}, context.temp_allocator)
	}
	if flake.spleen_package != "" && spleen.version != "" {
		spleen.version = strings.concatenate({spleen.version, ", package ", flake.spleen_package, ", ", nixpkgs_version}, context.temp_allocator)
	}
	append(&system_rows, spleen)

	// The pointer themes.
	for manifest_path in ([]string{SITE_SYSTEM_POINTER_MANIFEST, SITE_POSY_MANIFEST}) {
		text := site_read(manifest_path) or_return
		manifest, manifest_problem := site_pointer_manifest_parse(manifest_path, text)
		if manifest_problem != "" {
			return {}, fail(manifest_problem)
		}
		row := Site_License_Row {
			what    = strings.concatenate({"Pointer theme ", manifest.theme}, context.temp_allocator),
			place   = manifest_path,
			license = site_spdx(manifest.license),
		}
		if len(manifest.attribution) > 0 {
			row.author = manifest.attribution[0]
		}
		resource := manifest_path == SITE_POSY_MANIFEST ? "pointers_posy" : "pointers_system"
		row.in_boot_image = in_image(boot_image, resource)
		if manifest_path == SITE_POSY_MANIFEST {
			// flake.nix allows this one package of nixpkgs by its name; the
			// repository holds no file of the theme.
			row.version = flake.unfree_allowed != "" ? strings.concatenate({"package ", flake.unfree_allowed, ", ", nixpkgs_version, "; not redistributed: allowed by name in flake.nix, converted at each build"}, context.temp_allocator) : ""
		}
		append(&system_rows, row)
	}

	// The cryptography taken from Odin.
	odin_license_text := site_read(SITE_ODIN_LICENSE_FILE) or_return
	fiat_text := site_read(SITE_FIAT_LICENSE_FILE) or_return
	manifest_text := site_read(CRYPTOGRAPHY_MANIFEST) or_return
	taken := 0
	for line in site_lines(manifest_text) {
		if strings.trim_space(line) != "" && !strings.has_prefix(line, "#") {
			taken += 1
		}
	}
	crypto := Site_License_Row {
		what          = fmt.tprintf("Cryptography taken from Odin's core:crypto (%d files)", taken),
		place         = CRYPTOGRAPHY_FOLDER,
		license       = strings.contains(odin_license_text, "(zlib)") ? "Zlib" : SITE_NOT_RECORDED,
		author        = site_line_after(odin_license_text, "Copyright "),
		in_boot_image = in_image(boot_image, "cryptography"),
	}
	if crypto.author != "" {
		crypto.author = strings.concatenate({"Copyright ", crypto.author}, context.temp_allocator)
	}
	TAG :: "tag "
	if start := strings.index(odin_license_text, TAG); start >= 0 {
		rest := odin_license_text[start + len(TAG):]
		if end := strings.index_any(rest, " \n"); end > 0 {
			crypto.version = strings.concatenate({"taken at the tag ", rest[:end], "; the origin check compares with ", CRYPTOGRAPHY_ORIGIN_RELEASE}, context.temp_allocator)
		}
	}
	if open := strings.index(odin_license_text, "(https://"); open >= 0 {
		rest := odin_license_text[open + 1:]
		if end := strings.index_byte(rest, ')'); end > 0 {
			crypto.author_address = rest[:end]
		}
	}
	append(&system_rows, crypto)
	fiat := Site_License_Row {
		what          = "Field arithmetic of fiat-crypto, in Odin's port",
		place         = SITE_FIAT_LICENSE_FILE,
		license       = strings.contains(fiat_text, "(BSD-1-Clause)") ? "BSD-1-Clause" : SITE_NOT_RECORDED,
		author        = site_line_after(fiat_text, "Copyright "),
		version       = crypto.version,
		in_boot_image = crypto.in_boot_image,
	}
	if open := strings.index(fiat_text, "(https://"); open >= 0 {
		rest := fiat_text[open + 1:]
		if end := strings.index_byte(rest, ')'); end > 0 {
			fiat.author_address = rest[:end]
		}
	}
	if fiat.author != "" {
		fiat.author = strings.concatenate({"Copyright ", fiat.author}, context.temp_allocator)
	}
	append(&system_rows, fiat)

	// The portrait of the program temple.
	portrait_text := site_read(SITE_PORTRAIT_LICENSE_FILE) or_return
	portrait := Site_License_Row {
		what          = "Portrait of the program temple",
		place         = SITE_PORTRAIT_LICENSE_FILE,
		license       = strings.contains(portrait_text, "as public domain") ? "public domain (as Wikimedia Commons marks it)" : SITE_NOT_RECORDED,
		author        = strings.trim_suffix(site_line_after(portrait_text, "Author: "), "."),
		in_boot_image = in_image(boot_image, "temple"),
	}
	for line in site_lines(portrait_text) {
		if strings.has_prefix(line, "https://") {
			portrait.author_address = strings.trim_space(line)
			break
		}
	}
	append(&system_rows, portrait)

	// What builds and tests the system: the tools of the development shell,
	// and the firmware of the test machine.
	for tool in flake.build_tools {
		row := Site_License_Row {
			place         = SITE_FLAKE_FILE,
			license       = SITE_NOT_RECORDED,
			in_boot_image = "no",
		}
		if tool == "odin" {
			row.what = "Odin compiler"
			row.version = strings.concatenate({flake.odin_release, ", ", flake.odin_hash}, context.temp_allocator)
			row.author_address = strings.concatenate({"https://github.com/", flake.odin_owner, "/", flake.odin_repository}, context.temp_allocator)
		} else if strings.has_prefix(tool, "pkgs.") {
			row.what = strings.concatenate({"package ", tool[len("pkgs."):]}, context.temp_allocator)
			row.version = nixpkgs_version
		} else {
			row.what = tool
		}
		append(&build_rows, row)
	}
	append(&build_rows, Site_License_Row{what = "UEFI firmware of the test machine", place = SITE_FLAKE_FILE, license = SITE_NOT_RECORDED, version = strings.concatenate({"package ", flake.firmware_package, ", ", nixpkgs_version}, context.temp_allocator), in_boot_image = "no"})

	// The cells with no source.
	for rows in ([][]Site_License_Row{system_rows[:], build_rows[:]}) {
		for &row in rows {
			cells := [?]struct {
				name:  string,
				value: ^string,
			}{{"license", &row.license}, {"author", &row.author}, {"version", &row.version}, {"in the boot image", &row.in_boot_image}}
			for cell in cells {
				if cell.value^ == "" {
					cell.value^ = SITE_NOT_RECORDED
				}
				if cell.value^ == SITE_NOT_RECORDED {
					append(&gaps, strings.concatenate({row.what, ": ", cell.name}, context.temp_allocator))
				}
			}
		}
	}
	licenses.system_rows = system_rows[:]
	licenses.build_rows = build_rows[:]
	licenses.gaps = gaps[:]
	return licenses, true
}

// One entry of the boot image of this build: a module or a resource.
Site_Image_Entry :: struct {
	name:     string,
	hash:     [32]u8,
	size:     u64,
	resource: bool,
}

// site_boot_image_read reads the table of the boot image of the last build
// (contract/boot_info: a header, then one entry for each module and each
// resource). An absent file gives no entry: the image is not built.
site_boot_image_read :: proc(path: string) -> (entries: []Site_Image_Entry, problem: string) {
	if !os.exists(path) {
		return nil, ""
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, fmt.tprintf("%s: cannot read: %v", path, err)
	}
	HEADER_SIZE :: 16 // magic (8 bytes), count (4), resource_count (4).
	ENTRY_SIZE :: 32 + 32 + 8 + 8 // name, hash, offset, size.
	little :: proc(bytes: []u8) -> u64 {
		value: u64
		for index := len(bytes) - 1; index >= 0; index -= 1 {
			value = value << 8 | u64(bytes[index])
		}
		return value
	}
	if len(data) < HEADER_SIZE || little(data[0:8]) != 0x4547414D49544F42 {
		return nil, fmt.tprintf("%s: not a boot image (no magic \"BOTIMAGE\")", path)
	}
	count := int(little(data[8:12]))
	resource_count := int(little(data[12:16]))
	total := count + resource_count
	if total < 0 || total > 4096 || HEADER_SIZE + total * ENTRY_SIZE > len(data) {
		return nil, fmt.tprintf("%s: the table of the boot image does not fit in the file", path)
	}
	list := make([]Site_Image_Entry, total, context.temp_allocator)
	for index in 0 ..< total {
		entry := data[HEADER_SIZE + index * ENTRY_SIZE:][:ENTRY_SIZE]
		name_end := 0
		for name_end < 32 && entry[name_end] != 0 {
			name_end += 1
		}
		list[index].name = string(entry[:name_end])
		copy(list[index].hash[:], entry[32:64])
		list[index].size = little(entry[72:80])
		list[index].resource = index >= count
	}
	return list, ""
}
