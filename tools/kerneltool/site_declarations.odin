// The declarations of the sources on the site (docs/SITE.md, "The
// declarations of the sources"). The tool reads every procedure, type,
// constant and global variable that the sources of the system declare at
// the top of a package, with the parser of Odin, into one declaration
// index. A code span of a guide, of a news entry or of a source comment that
// names one of them becomes a link to it, with a short card that the page
// holds once; a code span that is a fragment of Odin is colored by the
// tokenizer of the compiler, as the blocks of code are.
package kerneltool

import "contract:value_kinds"
import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"

// The folders whose declarations the index holds: the sources of the system.
// The tool is not read: its names are not names of the system.
SITE_DECLARATION_FOLDERS :: [?]string{"kernel", "boot", "contract", "support", "modules", "programs"}
// The id of the card of a declaration on a page is this prefix and the
// place of the declaration in the index; its first sentence has the suffix
// of the type cards too, so that a screen reader reads it with the link.
SITE_DECLARATION_CARD_PREFIX :: "declaration-"
// The spans that the command names when it counts the spans that are
// ambiguous or that name no declaration.
SITE_DECLARATION_FIRST_LISTED :: 5
// Inside a fragment of code, a name shorter than this is a local of the
// example ("a", "d"), not a reference.
SITE_DECLARATION_SHORTEST_NAME_IN_CODE :: 3

Site_Declaration_Kind :: enum {
	Procedure,
	Type,
	Constant,
	Variable,
}

site_declaration_kind_names := [Site_Declaration_Kind]string {
	.Procedure = "procedure",
	.Type      = "type",
	.Constant  = "constant",
	.Variable  = "global variable",
}

// The value kind of each kind of declaration: its icon and its color.
site_declaration_value_kinds := [Site_Declaration_Kind]value_kinds.Value_Kind {
	.Procedure = .Procedure,
	.Type      = .Type,
	.Constant  = .Constant,
	.Variable  = .Variable,
}

// One declaration at the top of a package of the sources.
Site_Declaration :: struct {
	name:           string,
	package_name:   string, // The name after "package" in its file.
	folder:         string, // The folder of its file: "support/graphics".
	file:           string,
	line:           int,
	kind:           Site_Declaration_Kind,
	signature:      string, // One line of Odin, with no body and no comment.
	first_sentence: string, // Of the comment above it, or of its line; or "".
}

// The declaration index: each declaration, the declarations of each name,
// and the folders that hold one.
Site_Declaration_Index :: struct {
	declarations:          [dynamic]Site_Declaration,
	by_name:               map[string][dynamic]int,
	folders:               map[string]bool,
	packages:              map[string]bool, // The name of each package, and the last part of each folder.
	files_not_parsed:      int,
	first_file_not_parsed: string,
}

// What became of the code spans that name a declaration, for the summary of
// the command: a stale name in a guide is then seen.
Site_Declaration_Span_Counts :: struct {
	linked:          int,
	ambiguous:       int,
	not_found:       int,
	first_ambiguous: [SITE_DECLARATION_FIRST_LISTED]string,
	first_not_found: [SITE_DECLARATION_FIRST_LISTED]string,
}

// site_declaration_index_make gives an empty index.
site_declaration_index_make :: proc() -> Site_Declaration_Index {
	return Site_Declaration_Index {
		declarations = make([dynamic]Site_Declaration, context.temp_allocator),
		by_name = make(map[string][dynamic]int, context.temp_allocator),
		folders = make(map[string]bool, context.temp_allocator),
		packages = make(map[string]bool, context.temp_allocator),
	}
}

// site_declaration_add adds one declaration to an index.
site_declaration_add :: proc(index: ^Site_Declaration_Index, declaration: Site_Declaration) {
	append(&index.declarations, declaration)
	place := len(index.declarations) - 1
	list, found := index.by_name[declaration.name]
	if !found {
		list = make([dynamic]int, context.temp_allocator)
	}
	append(&list, place)
	index.by_name[declaration.name] = list
	index.folders[declaration.folder] = true
	index.packages[declaration.package_name] = true
	index.packages[declaration.folder[strings.last_index_byte(declaration.folder, '/') + 1:]] = true
}

// site_declaration_one_line gives a text of Odin on one line: its tokens
// with no comment, one space where the text had spaces, no space inside
// the brackets and no comma before a closing bracket. A text that the
// tokenizer refuses has its spaces made single.
site_declaration_one_line :: proc(text: string) -> string {
	tokens, ok := site_code_odin_tokens(text)
	if !ok {
		words := strings.fields(text, context.temp_allocator)
		return strings.join(words, " ", context.temp_allocator)
	}
	b := strings.builder_make(context.temp_allocator)
	previous_end := -1
	previous_kind := tokenizer.Token_Kind.Invalid
	for token in tokens {
		if token.kind == .Comment {
			continue
		}
		closing := token.kind == .Close_Paren || token.kind == .Close_Bracket || token.kind == .Close_Brace
		if closing && strings.has_suffix(strings.to_string(b), ",") {
			strings.pop_byte(&b)
		}
		opened := previous_kind == .Open_Paren || previous_kind == .Open_Bracket || previous_kind == .Open_Brace
		if previous_end >= 0 && token.start > previous_end && !closing && !opened && token.kind != .Comma {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, text[token.start:token.end])
		previous_end = token.end
		previous_kind = token.kind
	}
	return strings.to_string(b)
}

// site_declaration_first_brace gives the offset in a text of its first
// "{", or -1.
site_declaration_first_brace :: proc(text: string) -> int {
	tokens, ok := site_code_odin_tokens(text)
	if !ok {
		return -1
	}
	for token in tokens {
		if token.kind == .Open_Brace {
			return token.start
		}
	}
	return -1
}

// site_declaration_kind_of gives the kind of a declaration from its value:
// a mutable one is a global variable; a procedure literal or a group of
// procedures is a procedure; a type expression is a type; a name with a
// capital and lowercase letters given another name is an alias of a type;
// any other value is a constant.
site_declaration_kind_of :: proc(name: string, is_mutable: bool, value: ^ast.Expr) -> Site_Declaration_Kind {
	if is_mutable {
		return .Variable
	}
	if value == nil {
		return .Constant
	}
	#partial switch _ in value.derived {
	case ^ast.Proc_Lit, ^ast.Proc_Group:
		return .Procedure
	case ^ast.Struct_Type, ^ast.Enum_Type, ^ast.Union_Type, ^ast.Bit_Set_Type, ^ast.Bit_Field_Type, ^ast.Distinct_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Fixed_Capacity_Dynamic_Array_Type, ^ast.Map_Type, ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Proc_Type, ^ast.Matrix_Type, ^ast.Typeid_Type, ^ast.Helper_Type:
		return .Type
	case ^ast.Ident, ^ast.Selector_Expr:
		if site_code_is_capital(name) && !site_code_is_constant_name(name) {
			return .Type
		}
	}
	return .Constant
}

// site_declaration_signature gives the one line of a declaration: its text
// up to the body of a procedure, or up to the first "{" of another value
// (the fields of a struct, the members of an enum, the items of a table),
// which become "{...}". The line is whole: a card never cuts a text.
site_declaration_signature :: proc(source: string, declaration: ^ast.Value_Decl, value: ^ast.Expr) -> string {
	start := declaration.pos.offset
	end := declaration.end.offset
	if start < 0 || end > len(source) || end < start {
		return ""
	}
	text := source[start:end]
	if value != nil {
		if procedure, is_procedure := value.derived.(^ast.Proc_Lit); is_procedure {
			if procedure.body != nil && procedure.body.pos.offset > start && procedure.body.pos.offset <= end {
				text = source[start:procedure.body.pos.offset]
			}
		} else if value.pos.offset >= start && value.end.offset <= end {
			if brace := site_declaration_first_brace(source[value.pos.offset:value.end.offset]); brace >= 0 {
				text = strings.concatenate({source[start:value.pos.offset + brace], "{...}"}, context.temp_allocator)
			}
		}
	}
	return site_declaration_one_line(text)
}

// site_declarations_of_statements adds the declarations of a list of
// statements of the top of a file, and of the blocks of a "when" there.
site_declarations_of_statements :: proc(list: ^[dynamic]Site_Declaration, statements: []^ast.Stmt, path, folder, package_name, source: string) {
	for statement in statements {
		if statement == nil {
			continue
		}
		#partial switch item in statement.derived {
		case ^ast.When_Stmt:
			site_declarations_of_when(list, item, path, folder, package_name, source)
		case ^ast.Value_Decl:
			description := text_of(item.docs)
			if description == "" {
				description = text_of(item.comment)
			}
			first := about_of(description, "")
			for name_expression, name_index in item.names {
				identifier, has_name := name_expression.derived.(^ast.Ident)
				if !has_name || identifier.name == "_" {
					continue
				}
				value: ^ast.Expr
				if len(item.values) == len(item.names) {
					value = item.values[name_index]
				} else if len(item.values) == 1 {
					value = item.values[0]
				}
				append(list, Site_Declaration {
					name = identifier.name,
					package_name = package_name,
					folder = folder,
					file = path,
					line = item.pos.line,
					kind = site_declaration_kind_of(identifier.name, item.is_mutable, value),
					signature = site_declaration_signature(source, item, value),
					first_sentence = first,
				})
			}
		}
	}
}

// site_declarations_of_when adds the declarations of the blocks of a
// "when" at the top of a file: a declaration for one machine is still a
// declaration of the package.
site_declarations_of_when :: proc(list: ^[dynamic]Site_Declaration, statement: ^ast.When_Stmt, path, folder, package_name, source: string) {
	for part in ([]^ast.Stmt{statement.body, statement.else_stmt}) {
		if part == nil {
			continue
		}
		#partial switch block in part.derived {
		case ^ast.Block_Stmt:
			site_declarations_of_statements(list, block.stmts, path, folder, package_name, source)
		case ^ast.When_Stmt:
			site_declarations_of_when(list, block, path, folder, package_name, source)
		}
	}
}

// site_declarations_of_file gives the declarations of one source file. The
// tree of the parser lives in an arena of its own, freed before the next
// file: the index keeps only its texts, which are parts of the source or
// strings of the temporary allocator.
site_declarations_of_file :: proc(path, source: string) -> (found: []Site_Declaration, parsed: bool) {
	list := make([dynamic]Site_Declaration, context.temp_allocator)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, false
	}
	defer virtual.arena_destroy(&arena)
	folder := path[:max(strings.last_index_byte(path, '/'), 0)]
	{
		context.allocator = virtual.arena_allocator(&arena)
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source
		file.fullpath = path
		reader := parser.default_parser()
		// The command reports a file that the parser refuses by its count.
		reader.err = site_code_quiet_error
		reader.warn = site_code_quiet_error
		if !parser.parse_file(&reader, file) || file.syntax_error_count > 0 {
			return nil, false
		}
		// The texts are cloned out of the arena: the name of the package is
		// a part of the source, but a copy costs nothing here.
		package_name := strings.clone(file.pkg_name, context.temp_allocator)
		site_declarations_of_statements(&list, file.decls[:], path, folder, package_name, source)
	}
	return list[:], true
}

// site_declarations_read makes the declaration index of the sources of the
// system. A file that the parser refuses is counted, not fatal: the build
// of the system checks its sources.
site_declarations_read :: proc(site: ^Site) -> bool {
	site.declarations = site_declaration_index_make()
	paths := make([dynamic]string, context.temp_allocator)
	folders := SITE_DECLARATION_FOLDERS
	for folder in folders {
		site_odin_files_under(folder, &paths)
	}
	for path in paths {
		source, read_ok := site_read_quiet(path)
		if !read_ok {
			fmt.eprintfln("kerneltool: site: cannot read %s", path)
			return false
		}
		found, parsed := site_declarations_of_file(path, source)
		if !parsed {
			site.declarations.files_not_parsed += 1
			if site.declarations.first_file_not_parsed == "" {
				site.declarations.first_file_not_parsed = path
			}
			continue
		}
		for declaration in found {
			site_declaration_add(&site.declarations, declaration)
		}
	}
	return true
}

// The forms of a code span that can name a declaration: a name, a name
// with empty parentheses, and either one after the name of its package.
Site_Declaration_Span :: struct {
	qualifier: string, // The package that the span names, or "".
	name:      string,
	called:    bool, // "name()": a procedure.
}

// The extensions of the files that a span names: "boot.image" and
// "flake.nix" are files, not a name after its package.
SITE_FILE_EXTENSIONS :: [?]string{"odin", "md", "nix", "lock", "json", "js", "css", "html", "txt", "png", "svg", "ico", "xml", "toml", "yaml", "yml", "sh", "image", "img", "efi", "bin", "manifest", "license", "webmanifest", "c", "h", "rs", "py", "asm", "ld", "log", "pem", "der", "wgsl"}

// site_declaration_span_read reads the form of a code span: a name,
// "name()", "package.name" or "package.name()". A file name with a known
// extension, a keyword or a built-in type is not a name of a declaration.
site_declaration_span_read :: proc(code: string) -> (span: Site_Declaration_Span, is_name: bool) {
	text := code
	if strings.has_suffix(text, "()") {
		text = text[:len(text) - 2]
		span.called = true
	}
	if period := strings.index_byte(text, '.'); period >= 0 {
		span.qualifier = text[:period]
		text = text[period + 1:]
		extensions := SITE_FILE_EXTENSIONS
		for extension in extensions {
			if text == extension {
				return {}, false
			}
		}
		if !site_is_identifier(span.qualifier) {
			return {}, false
		}
	}
	if !site_is_identifier(text) || site_is_odin_word(text) {
		return {}, false
	}
	span.name = text
	return span, true
}

// site_is_odin_word tells whether a name is a keyword of the tokenizer or a
// built-in type of Odin: no declaration of the sources has it.
site_is_odin_word :: proc(name: string) -> bool {
	built_in := SITE_CODE_BUILT_IN_TYPES
	for type_name in built_in {
		if name == type_name {
			return true
		}
	}
	tokens, ok := site_code_odin_tokens(name)
	return ok && len(tokens) == 1 && tokenizer.is_keyword(tokens[0].kind)
}

// site_is_plain_word tells whether a name is a common word: lowercase
// letters only, as "count" or "build". Such a name is linked only when the
// text around it names the package of the declaration, or when the span
// calls it.
site_is_plain_word :: proc(name: string) -> bool {
	for character in transmute([]u8)name {
		if character < 'a' || character > 'z' {
			return false
		}
	}
	return true
}

// What the resolution of a name gives.
Site_Declaration_Resolution :: enum {
	Linked,
	Ambiguous, // Several declarations, or a common word that nothing places.
	Not_Found,
}

// site_declaration_in_context tells whether a declaration is in one of the
// folders that the text around a span names, or under one of them.
site_declaration_in_context :: proc(declaration: Site_Declaration, context_folders: []string) -> bool {
	for folder in context_folders {
		if declaration.folder == folder || strings.has_prefix(declaration.folder, strings.concatenate({folder, "/"}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

// site_declaration_resolve finds the declaration that a span names. A name
// that several packages declare is resolved by the package that the span
// names, else by the folders that the text around it names (the heading
// and the paragraph); else it stays plain. A common word is linked only
// when that text places it, or when the span calls it.
site_declaration_resolve :: proc(index: ^Site_Declaration_Index, span: Site_Declaration_Span, context_folders: []string) -> (place: int, resolution: Site_Declaration_Resolution) {
	list, found := index.by_name[span.name]
	if !found || len(list) == 0 {
		return -1, .Not_Found
	}
	candidates := make([dynamic]int, context.temp_allocator)
	for candidate in list {
		declaration := index.declarations[candidate]
		if span.qualifier != "" && declaration.package_name != span.qualifier && declaration.folder[strings.last_index_byte(declaration.folder, '/') + 1:] != span.qualifier {
			continue
		}
		if span.called && declaration.kind != .Procedure {
			continue
		}
		append(&candidates, candidate)
	}
	if len(candidates) == 0 {
		return -1, .Not_Found
	}
	placed := make([dynamic]int, context.temp_allocator)
	for candidate in candidates {
		if site_declaration_in_context(index.declarations[candidate], context_folders) {
			append(&placed, candidate)
		}
	}
	if len(placed) == 1 {
		return placed[0], .Linked
	}
	if len(candidates) == 1 && (span.qualifier != "" || span.called || !site_is_plain_word(span.name)) {
		return candidates[0], .Linked
	}
	return -1, .Ambiguous
}

// site_context_folders gives the folders of the index that a text names:
// "support/graphics" and "support/graphics/blend.odin" both give
// "support/graphics". The heading and the paragraph of a span give the
// packages that the span most likely means.
site_context_folders :: proc(index: ^Site_Declaration_Index, text: string) -> []string {
	folders := make([dynamic]string, context.temp_allocator)
	if index == nil || len(index.folders) == 0 {
		return folders[:]
	}
	start := 0
	for start < len(text) {
		for start < len(text) && strings.index_byte(" `()[],;\"'*", text[start]) >= 0 {
			start += 1
		}
		end := start
		for end < len(text) && strings.index_byte(" `()[],;\"'*", text[end]) < 0 {
			end += 1
		}
		word := strings.trim_right(text[start:end], ".:")
		if colon := strings.index_byte(word, ':'); colon > 0 {
			word = word[:colon]
		}
		if strings.contains(word, "/") {
			candidate := strings.trim_suffix(word, "/")
			if strings.has_suffix(candidate, ".odin") {
				candidate = candidate[:max(strings.last_index_byte(candidate, '/'), 0)]
			}
			if candidate in index.folders {
				append(&folders, candidate)
			}
		}
		start = end
	}
	return folders[:]
}

// site_declaration_count records what became of a span that has the form
// of a name, with its place, so that the command names the first ones.
site_declaration_count :: proc(site: ^Site, resolution: Site_Declaration_Resolution, place, code: string) {
	counts := &site.declaration_spans
	// A span is listed once, among the first ones.
	listed :: proc(list: ^[SITE_DECLARATION_FIRST_LISTED]string, entry: string) {
		for slot in 0 ..< SITE_DECLARATION_FIRST_LISTED {
			if list[slot] == entry {
				return
			}
			if list[slot] == "" {
				list[slot] = entry
				return
			}
		}
	}
	entry := fmt.tprintf("%s: `%s`", place, code)
	switch resolution {
	case .Linked:
		counts.linked += 1
	case .Ambiguous:
		counts.ambiguous += 1
		listed(&counts.first_ambiguous, entry)
	case .Not_Found:
		counts.not_found += 1
		listed(&counts.first_not_found, entry)
	}
}

// site_declaration_summary gives the lines that the command prints: the
// declarations of the index and the files that the parser refused, then
// the code spans that have the form of a name: linked, ambiguous and not
// found, with the first ones of the last two. A name that is not found does
// not stop the command: many spans are words of a log or of a command.
site_declaration_summary :: proc(site: ^Site) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	index := &site.declarations
	counts := site.declaration_spans
	by_kind: [Site_Declaration_Kind]int
	for declaration in index.declarations {
		by_kind[declaration.kind] += 1
	}
	parsed := fmt.tprintf("%d declarations of the sources: %d procedures, %d types, %d constants, %d global variables; %d files not parsed", len(index.declarations), by_kind[.Procedure], by_kind[.Type], by_kind[.Constant], by_kind[.Variable], index.files_not_parsed)
	if index.first_file_not_parsed != "" {
		parsed = strings.concatenate({parsed, ", the first: ", index.first_file_not_parsed}, context.temp_allocator)
	}
	append(&lines, parsed)
	first :: proc(list: [SITE_DECLARATION_FIRST_LISTED]string) -> string {
		parts := make([dynamic]string, context.temp_allocator)
		for item in list {
			if item != "" {
				append(&parts, item)
			}
		}
		return strings.join(parts[:], "; ", context.temp_allocator)
	}
	append(&lines, fmt.tprintf("%d code spans name a declaration and link to it, %d are ambiguous, %d name no declaration", counts.linked, counts.ambiguous, counts.not_found))
	if counts.ambiguous > 0 {
		append(&lines, strings.concatenate({"ambiguous, the first: ", first(counts.first_ambiguous)}, context.temp_allocator))
	}
	if counts.not_found > 0 {
		append(&lines, strings.concatenate({"no declaration, the first: ", first(counts.first_not_found)}, context.temp_allocator))
	}
	return lines[:]
}

// site_declaration_card_id gives the id of the card of a declaration.
site_declaration_card_id :: proc(place: int) -> string {
	return fmt.tprintf("%s%d", SITE_DECLARATION_CARD_PREFIX, place)
}

// site_declaration_export_page gives the place of a declaration on the page
// of its module when it is an export of a module of the build, or "".
site_declaration_export_page :: proc(site: ^Site, declaration: Site_Declaration) -> string {
	if declaration.kind != .Procedure {
		return ""
	}
	for item in site.reference.modules {
		if item.build.source != declaration.folder {
			continue
		}
		for export in item.description.exports {
			if export.name == declaration.name {
				return strings.concatenate({item.page, "#export-", site_slug(export.name)}, context.temp_allocator)
			}
		}
	}
	return ""
}

// site_declaration_address gives the link of a declaration from a page: the
// page of its module for an export, else its line in the repository at the
// commit of the build.
site_declaration_address :: proc(site: ^Site, from_page: string, declaration: Site_Declaration) -> string {
	if page := site_declaration_export_page(site, declaration); page != "" {
		return site_page_link(site, from_page, page)
	}
	return fmt.tprintf("%s#L%d", site_repository_file(site, declaration.file), declaration.line)
}

// site_declaration_type_key gives the key of the type card of a declaration
// that is a type of the contract, or "".
site_declaration_type_key :: proc(site: ^Site, declaration: Site_Declaration) -> string {
	if declaration.kind != .Type || !strings.has_prefix(declaration.folder, "contract/") {
		return ""
	}
	key := strings.concatenate({declaration.package_name, ".", declaration.name}, context.temp_allocator)
	if _, found := site_type_index(site, key); found {
		return key
	}
	return ""
}

// site_declaration_reference writes a code span that names a declaration:
// a type of the contract as the reference to its type card; another
// declaration as a link in the color and with the icon of its kind, whose
// card the script opens when the pointer rests on it or the focus reaches
// it. With no script the link works and no card opens.
site_declaration_reference :: proc(site: ^Site, b: ^strings.Builder, from_page, code: string, place: int) {
	declaration := site.declarations.declarations[place]
	if key := site_declaration_type_key(site, declaration); key != "" {
		site_type_reference(site, b, key, code, true)
		return
	}
	id := site_declaration_card_id(place)
	strings.write_string(b, "<a class=\"declaration-reference\" href=\"")
	site_escape(b, site_declaration_address(site, from_page, declaration))
	fmt.sbprintf(b, "\" data-declaration-card=\"%s\" aria-describedby=\"%s%s\">", id, id, SITE_TYPE_CARD_SUMMARY_SUFFIX)
	site_value(b, site_declaration_value_kinds[declaration.kind], code, true)
	strings.write_string(b, "</a>")
}

// site_declaration_link_in_code writes a name inside a colored fragment of
// code as a link to its declaration, with no card: the link is enough
// inside an expression.
site_declaration_link_in_code :: proc(site: ^Site, b: ^strings.Builder, from_page, text: string, class: Site_Code_Class, place: int) {
	declaration := site.declarations.declarations[place]
	strings.write_string(b, "<a class=\"declaration-link\" href=\"")
	site_escape(b, site_declaration_address(site, from_page, declaration))
	strings.write_string(b, "\">")
	if class != .None && site_code_classes[class].name != "" {
		fmt.sbprintf(b, "<span class=\"c-%s\">", site_code_classes[class].name)
		site_escape(b, text)
		strings.write_string(b, "</span>")
	} else {
		site_escape(b, text)
	}
	strings.write_string(b, "</a>")
}

// The commands that start a code span of a shell: such a span is not Odin.
SITE_COMMAND_NAMES :: [?]string{"kerneltool", "nix", "odin", "git", "gh", "qemu-system-x86_64", "qemu-img", "cargo", "make", "sh", "bash", "fish", "cd", "ls", "cat", "curl", "ssh", "sudo", "rm", "cp", "mv", "mkdir", "echo", "grep", "rg", "objdump", "readelf", "llvm-objdump", "swtpm", "sbsign", "openssl", "python", "node"}

// site_code_span_is_odin tells whether a code span that is not a single
// name is a fragment of Odin that the site colors. The test leaves a span
// plain when it is unsure; it refuses:
//   a text that the tokenizer refuses, or of one token;
//   a command of a shell (its first word is a known command, or it has
//   "--", "$" or "~/");
//   a path (a "/" with no space on either side) or a file name;
//   a setting "NAME=value" (an "=" with no space on either side);
//   a line of a log or of prose: two names or values side by side with no
//   operator between ("test return_fault", "1031293 us"), or two labels
//   "name: " in one span ("kernel: boot: firmware");
//   a combination of keys or names with "+" alone ("Ctrl+C"): a fragment
//   must hold one part that only code has (a keyword, a literal, a bracket,
//   ":", "::", "->", "^", "." between names, "#" or "@").
site_code_span_is_odin :: proc(code: string) -> bool {
	text := strings.trim_space(code)
	if text == "" || (strings.contains(text, "--") && !strings.contains(text, "---")) || strings.contains_any(text, "$\\") || strings.contains(text, "~/") {
		return false
	}
	first_word := text
	if space := strings.index_byte(text, ' '); space >= 0 {
		first_word = text[:space]
	}
	commands := SITE_COMMAND_NAMES
	for command in commands {
		if first_word == command {
			return false
		}
	}
	if strings.has_prefix(text, "./") || strings.has_prefix(text, "/") {
		return false
	}
	for index in 0 ..< len(text) {
		if text[index] == '/' && index > 0 && index + 1 < len(text) && text[index - 1] != ' ' && text[index + 1] != ' ' {
			return false
		}
		// "NAME=value" with no space is a setting of a command or of the
		// environment, not an assignment of the code.
		if text[index] == '=' && index > 0 && index + 1 < len(text) && site_is_word_byte(text[index - 1]) && site_is_word_byte(text[index + 1]) {
			return false
		}
	}
	labels := 0
	for index in 1 ..< len(text) {
		if text[index] == ':' && index + 1 < len(text) && text[index + 1] == ' ' && site_is_word_byte(text[index - 1]) {
			labels += 1
		}
	}
	if labels >= 2 {
		return false
	}
	tokens, ok := site_code_odin_tokens(text)
	if !ok || len(tokens) < 2 {
		return false
	}
	is_operand :: proc(kind: tokenizer.Token_Kind) -> bool {
		return kind == .Ident || kind == .Integer || kind == .Float || kind == .Imag || kind == .String || kind == .Rune
	}
	has_code_part := false
	for token, index in tokens {
		if token.kind == .Comment {
			return false
		}
		if index > 0 && is_operand(token.kind) && is_operand(tokens[index - 1].kind) {
			return false
		}
		#partial switch token.kind {
		case .Integer, .Float, .Imag, .String, .Rune, .Open_Paren, .Open_Bracket, .Open_Brace, .Colon, .Arrow_Right, .Pointer, .Hash, .At, .Period, .Ellipsis, .Range_Half, .Range_Full, .Shl, .Shr, .Cmp_Eq, .Not_Eq, .Eq:
			has_code_part = true
		case:
			if tokenizer.is_keyword(token.kind) {
				has_code_part = true
			}
		}
		// An extension after a name and a period is a file: "build.sh".
		if token.kind == .Ident && index >= 2 && tokens[index - 1].kind == .Period && tokens[index - 1].start == tokens[index - 2].end {
			extensions := SITE_FILE_EXTENSIONS
			for extension in extensions {
				if text[token.start:token.end] == extension && token.end == len(text) {
					return false
				}
			}
		}
	}
	return has_code_part
}

// site_declaration_code_span writes a code span that may name a declaration
// or be a fragment of Odin, and tells whether it wrote it. A span of one
// name is resolved and counted; a fragment of Odin is colored, each name of
// the index in it a link; any other span is left to the caller.
site_declaration_code_span :: proc(site: ^Site, b: ^strings.Builder, from_page, place, code: string, context_folders: []string) -> bool {
	if site == nil {
		return false
	}
	span, is_name := site_declaration_span_read(code)
	// "header.size" is a field of a value, not a name after its package:
	// it is not counted, and it is colored as a fragment of code. With no
	// index (a test of the renderer alone) no name is resolved.
	if is_name && (len(site.declarations.declarations) == 0 || (span.qualifier != "" && span.qualifier not_in site.declarations.packages)) {
		is_name = false
	}
	if is_name {
		found, resolution := site_declaration_resolve(&site.declarations, span, context_folders)
		site_declaration_count(site, resolution, place, code)
		if resolution != .Linked {
			return false
		}
		site_declaration_reference(site, b, from_page, code, found)
		return true
	}
	if !site_code_span_is_odin(code) {
		return false
	}
	links := Site_Code_Links{site = site, from_page = from_page, context_folders = context_folders}
	strings.write_string(b, "<code class=\"code-inline\">")
	if !site_code_odin(site, b, code, "", &links) {
		site_escape(b, code)
	}
	strings.write_string(b, "</code>")
	return true
}

// site_declaration_cards_html gives the cards of the declarations that the
// text of a page links to: one for each declaration, in the order of the
// first link to it, at the end of the text, as the type cards.
site_declaration_cards_html :: proc(site: ^Site, from_page, body: string) -> string {
	seen := make(map[string]bool, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for id in site_attribute_values(body, "data-declaration-card=\"") {
		if id in seen || !strings.has_prefix(id, SITE_DECLARATION_CARD_PREFIX) {
			continue
		}
		seen[id] = true
		place := site_digits_value(id[len(SITE_DECLARATION_CARD_PREFIX):])
		if place < 0 || place >= len(site.declarations.declarations) {
			continue // The check of the page names it.
		}
		if strings.builder_len(b) == 0 {
			strings.write_string(&b, "<div class=\"declaration-cards\">\n")
		}
		site_declaration_card_write(site, &b, from_page, place)
	}
	if strings.builder_len(b) > 0 {
		strings.write_string(&b, "</div>\n")
	}
	return strings.to_string(b)
}

// site_declaration_card_write writes the card of a declaration: its name
// as the link to it, its kind and its package, its one line colored, the
// first sentence of its comment, and its file and line.
site_declaration_card_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string, place: int) {
	declaration := site.declarations.declarations[place]
	id := site_declaration_card_id(place)
	address := site_declaration_address(site, from_page, declaration)
	fmt.sbprintf(b, "<div class=\"declaration-card\" id=\"%s\" popover>\n<p class=\"declaration-card-title\"><a href=\"", id)
	site_escape(b, address)
	strings.write_string(b, "\">")
	site_value(b, site_declaration_value_kinds[declaration.kind], declaration.name, true)
	strings.write_string(b, "</a> <span class=\"declaration-card-kind\">")
	site_escape(b, fmt.tprintf("%s of the package %s", site_declaration_kind_names[declaration.kind], declaration.package_name))
	strings.write_string(b, "</span></p>\n<pre class=\"declaration-card-signature\"><code>")
	if !site_code_odin(site, b, declaration.signature, "", nil) {
		site_escape(b, declaration.signature)
	}
	fmt.sbprintf(b, "</code></pre>\n<p class=\"declaration-card-summary\" id=\"%s%s\">", id, SITE_TYPE_CARD_SUMMARY_SUFFIX)
	if declaration.first_sentence != "" {
		site_escape(b, site_source_comment_plain(site, declaration.first_sentence))
		strings.write_byte(b, '.')
	} else {
		site_escape(b, fmt.tprintf("A %s with no comment in its source.", site_declaration_kind_names[declaration.kind]))
	}
	strings.write_string(b, "</p>\n<p class=\"declaration-card-place\"><a href=\"")
	site_escape(b, fmt.tprintf("%s#L%d", site_repository_file(site, declaration.file), declaration.line))
	strings.write_string(b, "\">")
	site_escape(b, fmt.tprintf("%s:%d", declaration.file, declaration.line))
	strings.write_string(b, "</a></p>\n</div>\n")
}
