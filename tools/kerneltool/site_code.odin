// The colors of the code on the site (docs/SITE.md, "The colors of the
// code"). The tool colors the code when it writes the pages, as static
// markup: no script, no request, nothing new in the Content-Security-Policy.
// Odin is read by the tokenizer of the compiler itself (core:odin/tokenizer),
// not by a grammar of regular expressions, so a token is what the compiler
// sees. The output holds every byte of the source: the text of the output
// with its tags removed is the source.
package kerneltool

import "core:fmt"
import "core:odin/tokenizer"
import "core:strings"
import "support:graphics"

// The classes of the code. Each one has a short class name, because a page
// of declarations holds thousands of them:
//   c-k  a keyword
//   c-t  a type: a built-in type, or a name in the place of a type
//   c-l  a literal: a number, a string, a rune, a constant, a member
//   c-n  a name at its declaration: "name :: proc", "Name :: struct"
//   c-d  a directive or an attribute: #assert, @(private)
//   c-c  a comment
//   c-p  an operator or punctuation: the one quiet class
// A type of the contract is a reference to its card (site_type_reference),
// in the color of c-t.
Site_Code_Class :: enum {
	None,
	Keyword,
	Type,
	Literal,
	Name,
	Directive,
	Comment,
	Punctuation,
	Reference, // A type of the contract: a reference to its card.
}

Site_Code_Class_Description :: struct {
	name:  string, // The class "c-<name>".
	title: string,
	class: graphics.Code_Class, // Its color: the table of the colors of code of the system.
}

// The classes of the site and the classes of the colors of code of the
// system (src/library/support/graphics/code_colors.odin): the terminal of the system
// reads the same table, so a type or a literal has one color on the site
// and in the console. Each color is at least SITE_VALUE_CONTRAST_LEAST on
// the background of a block of code (the track color) in both forms.
site_code_classes := [Site_Code_Class]Site_Code_Class_Description {
	.None        = {},
	.Keyword     = {name = "k", title = "Keyword", class = .Keyword},
	.Type        = {name = "t", title = "Type", class = .Type},
	.Literal     = {name = "l", title = "Literal, constant or member", class = .Literal},
	.Name        = {name = "n", title = "Name at its declaration", class = .Name},
	.Directive   = {name = "d", title = "Directive or attribute", class = .Directive},
	.Comment     = {name = "c", title = "Comment", class = .Comment},
	.Punctuation = {name = "p", title = "Operator and punctuation", class = .Punctuation},
	.Reference   = {},
}

// The built-in types of Odin: a name of this list in code is of the class
// Type.
SITE_CODE_BUILT_IN_TYPES :: [?]string {
	"bool", "b8", "b16", "b32", "b64",
	"int", "uint", "uintptr", "rawptr", "any", "typeid",
	"i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "byte",
	"i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le",
	"i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be",
	"f16", "f32", "f64", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be",
	"complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256",
	"rune", "string", "cstring",
}

// site_code_color gives the color of a class in one form.
site_code_color :: proc(class: Site_Code_Class, light: bool) -> graphics.Color {
	return graphics.code_class_color(site_code_classes[class].class, light)
}

// site_code_rules gives the rules of the style sheet for the classes of the
// code in one form; a reference to a card in a block of code takes the
// color of a type.
site_code_rules :: proc(light: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for class in Site_Code_Class {
		if site_code_classes[class].name == "" {
			continue
		}
		fmt.sbprintf(&b, ".c-%s {{ color: %s; }}\n", site_code_classes[class].name, site_color(site_code_color(class, light)))
	}
	fmt.sbprintf(&b, "pre .type-reference {{ color: %s; }}\n", site_color(site_code_color(.Type, light)))
	return strings.to_string(b)
}

// One token of a text of Odin: its kind and its bytes in the text.
Site_Code_Token :: struct {
	kind:  tokenizer.Token_Kind,
	start: int,
	end:   int,
}

// The tokenizer reports a fault of the text to its handler; the caller
// reads the count of faults, and a block with a fault is written plain.
site_code_quiet_error :: proc(pos: tokenizer.Pos, format: string, args: ..any) {}

// site_code_odin_tokens gives the tokens of a text, or false when the
// tokenizer refuses it (an illegal character, a string or a comment with no
// end). The tokenizer gives comments as tokens and skips the spaces and the
// line feeds; the caller writes the bytes between two tokens as they are.
site_code_odin_tokens :: proc(source: string) -> (tokens: []Site_Code_Token, ok: bool) {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, source, "", site_code_quiet_error)
	list := make([dynamic]Site_Code_Token, context.temp_allocator)
	position := 0
	for {
		token := tokenizer.scan(&t)
		if token.kind == .EOF {
			break
		}
		start, end := token.pos.offset, t.offset
		// Each token after the one before it, inside the text: else the
		// output would not be the text.
		if token.kind == .Invalid || start < position || end < start || end > len(source) || len(list) > len(source) {
			return nil, false
		}
		append(&list, Site_Code_Token{kind = token.kind, start = start, end = end})
		position = end
	}
	if t.error_count > 0 {
		return nil, false
	}
	return list[:], true
}

// site_code_is_capital tells whether a name starts with a capital letter.
site_code_is_capital :: proc(name: string) -> bool {
	return len(name) > 0 && name[0] >= 'A' && name[0] <= 'Z'
}

// site_code_is_constant_name tells whether a name is in capitals, with at
// least two letters: PAGE_SIZE.
site_code_is_constant_name :: proc(name: string) -> bool {
	letters := 0
	for character in transmute([]u8)name {
		switch {
		case character >= 'a' && character <= 'z':
			return false
		case character >= 'A' && character <= 'Z':
			letters += 1
		}
	}
	return letters >= 2
}

site_code_token_text :: proc(source: string, token: Site_Code_Token) -> string {
	return source[token.start:token.end]
}

// site_code_token_before gives the token before an index with no comment
// between, or -1.
site_code_token_before :: proc(tokens: []Site_Code_Token, index: int) -> int {
	for other := index - 1; other >= 0; other -= 1 {
		if tokens[other].kind != .Comment {
			return other
		}
	}
	return -1
}

// site_code_token_after gives the token after an index with no comment
// between, or -1.
site_code_token_after :: proc(tokens: []Site_Code_Token, index: int) -> int {
	for other := index + 1; other < len(tokens); other += 1 {
		if tokens[other].kind != .Comment {
			return other
		}
	}
	return -1
}

// site_code_in_type_place tells whether a name is in the place of a type:
// after ":" (but not "::"), "^", "]", "->" or "distinct"; a name after
// "qualifier." takes the place of its qualifier.
site_code_in_type_place :: proc(source: string, tokens: []Site_Code_Token, index: int) -> bool {
	previous := site_code_token_before(tokens, index)
	if previous < 0 {
		return false
	}
	#partial switch tokens[previous].kind {
	case .Period:
		qualifier := site_code_token_before(tokens, previous)
		return qualifier >= 0 && tokens[qualifier].kind == .Ident && site_code_in_type_place(source, tokens, qualifier)
	case .Colon:
		// The second colon of "::" is not the place of a type.
		first := site_code_token_before(tokens, previous)
		return !(first >= 0 && tokens[first].kind == .Colon && tokens[first].end == tokens[previous].start)
	case .Pointer, .Close_Bracket, .Arrow_Right, .Distinct:
		return true
	}
	return false
}

// site_code_odin_classes gives the class of each token, and for a reference
// the key of its type. The rules, from the tokens only:
//   a comment, a number, a string, a rune: their class;
//   a keyword of the tokenizer: Keyword;
//   "#" and the name after it, "@" and the first name of its attribute: Directive;
//   a name before "::": Name;
//   true, false, nil, a name in capitals, ".Member" (a period with no value
//   before it), a member of an enum body: Literal;
//   "package.Name" of a documented package, or Name of the package of the
//   text, that is a type of the contract: Reference;
//   a built-in type: Type;
//   a name with a capital in the place of a type (after ":", "^", "]",
//   "->" or "distinct", or after "qualifier." in that place): Type;
//   an operator or punctuation: Punctuation; any other name: no class.
// A name with a capital elsewhere is not guessed to be a type.
site_code_odin_classes :: proc(site: ^Site, source: string, tokens: []Site_Code_Token, package_name: string) -> (classes: []Site_Code_Class, keys: []string) {
	classes = make([]Site_Code_Class, len(tokens), context.temp_allocator)
	keys = make([]string, len(tokens), context.temp_allocator)
	text := site_code_token_text
	before := site_code_token_before
	after := site_code_token_after
	in_type_place := site_code_in_type_place
	documented := make(map[string]bool, context.temp_allocator)
	packages := SITE_TYPE_PACKAGES
	for folder in packages {
		documented[folder[strings.last_index_byte(folder, '/') + 1:]] = true
	}
	built_in := make(map[string]bool, context.temp_allocator)
	built_in_names := SITE_CODE_BUILT_IN_TYPES
	for name in built_in_names {
		built_in[name] = true
	}
	braces := make([dynamic]bool, context.temp_allocator) // For each open brace: is it the body of an enum.
	enum_pending := false
	directive_next := false
	attribute_open := false

	for token, index in tokens {
		kind := token.kind
		switch {
		case kind == .Comment:
			classes[index] = .Comment
			continue
		case kind == .File_Tag:
			classes[index] = .Directive
			continue
		case kind == .Integer || kind == .Float || kind == .Imag || kind == .String || kind == .Rune:
			classes[index] = .Literal
		case kind == .Hash:
			classes[index] = .Directive
			directive_next = true
			continue
		case kind == .At:
			classes[index] = .Directive
			directive_next = true
			continue
		case kind == .Typeid:
			classes[index] = .Type
		case tokenizer.is_keyword(kind):
			classes[index] = .Keyword
			if kind == .Enum {
				enum_pending = true
			} else if kind == .Struct || kind == .Union || kind == .Proc || kind == .Bit_Set || kind == .Bit_Field {
				enum_pending = false
			}
		case kind == .Ident:
			name := text(source, token)
			previous := before(tokens, index)
			next := after(tokens, index)
			declares := next >= 0 && tokens[next].kind == .Colon && next + 1 < len(tokens) && tokens[next + 1].kind == .Colon && tokens[next].end == tokens[next + 1].start
			after_period := previous >= 0 && tokens[previous].kind == .Period
			qualifier := after_period ? before(tokens, previous) : -1
			qualified := qualifier >= 0 && tokens[qualifier].kind == .Ident
			in_enum := len(braces) > 0 && braces[len(braces) - 1] && previous >= 0 && (tokens[previous].kind == .Open_Brace || tokens[previous].kind == .Comma)
			switch {
			case directive_next || attribute_open:
				classes[index] = .Directive
				attribute_open = false
			case declares:
				classes[index] = .Name
			case name == "true" || name == "false" || name == "nil":
				classes[index] = .Literal
			case qualified && documented[text(source, tokens[qualifier])]:
				key := strings.concatenate({text(source, tokens[qualifier]), ".", name}, context.temp_allocator)
				if _, found := site_type_index(site, key); found {
					classes[index] = .Reference
					keys[index] = key
				} else if site_code_is_constant_name(name) {
					classes[index] = .Literal
				} else if site_code_is_capital(name) && in_type_place(source, tokens, index) {
					classes[index] = .Type
				}
			case after_period && !qualified:
				// ".Member": a period with no name before it.
				previous_value := before(tokens, previous)
				if previous_value < 0 || (tokens[previous_value].kind != .Close_Paren && tokens[previous_value].kind != .Close_Bracket && tokens[previous_value].kind != .Pointer && tokens[previous_value].kind != .Close_Brace) {
					classes[index] = .Literal
				}
			case in_enum:
				classes[index] = .Literal
			case !after_period && package_name != "" && site_code_is_capital(name):
				key := strings.concatenate({package_name, ".", name}, context.temp_allocator)
				if _, found := site_type_index(site, key); found {
					classes[index] = .Reference
					keys[index] = key
				} else if site_code_is_constant_name(name) {
					classes[index] = .Literal
				} else if in_type_place(source, tokens, index) {
					classes[index] = .Type
				}
			case built_in[name]:
				classes[index] = .Type
			case site_code_is_constant_name(name):
				classes[index] = .Literal
			case site_code_is_capital(name) && in_type_place(source, tokens, index):
				classes[index] = .Type
			}
		case kind > .B_Operator_Begin && kind < .B_Operator_End:
			classes[index] = .Punctuation
			#partial switch kind {
			case .Open_Brace:
				append(&braces, enum_pending)
				enum_pending = false
			case .Close_Brace:
				if len(braces) > 0 {
					pop(&braces)
				}
			case .Open_Paren:
				// "@(" opens an attribute: its first name is a directive.
				previous := before(tokens, index)
				if previous >= 0 && tokens[previous].kind == .At {
					attribute_open = true
				}
			}
		}
		directive_next = false
	}
	return classes, keys
}

// What a fragment of code in a text needs to link its names to their
// declarations: the page that holds it and the folders that the text
// around it names (docs/SITE.md, "The declarations of the sources").
Site_Code_Links :: struct {
	site:            ^Site,
	from_page:       string,
	context_folders: []string,
}

// site_code_link_place gives the declaration that a name of a fragment of
// code links to, or -1. A name after "package." is looked for in that
// package; a name after another value and a period is a field, and a short
// name is a local of the example: neither links.
site_code_link_place :: proc(links: ^Site_Code_Links, source: string, tokens: []Site_Code_Token, index: int) -> int {
	if links == nil || links.site == nil || len(links.site.declarations.declarations) == 0 {
		return -1
	}
	name := site_code_token_text(source, tokens[index])
	if len(name) < SITE_DECLARATION_SHORTEST_NAME_IN_CODE || site_is_odin_word(name) {
		return -1
	}
	span := Site_Declaration_Span{name = name}
	previous := site_code_token_before(tokens, index)
	if previous >= 0 && tokens[previous].kind == .Period {
		qualifier := site_code_token_before(tokens, previous)
		if qualifier < 0 || tokens[qualifier].kind != .Ident {
			return -1
		}
		span.qualifier = site_code_token_text(source, tokens[qualifier])
		if span.qualifier not_in links.site.declarations.packages {
			return -1
		}
	}
	next := site_code_token_after(tokens, index)
	span.called = next >= 0 && tokens[next].kind == .Open_Paren
	place, resolution := site_declaration_resolve(&links.site.declarations, span, links.context_folders)
	return resolution == .Linked ? place : -1
}

// site_code_odin writes a text of Odin with the class of each token, and
// each type of the contract as a reference to its card. package_name is the
// package of the text ("operation" for a declaration of src/library/contract/operation),
// or "" when it is not known (a block of a guide): then only "package.Name"
// of a documented package is a reference. With links, each name that the
// declaration index resolves is a link to its declaration. It writes
// nothing and gives false when the tokenizer refuses the text.
site_code_odin :: proc(site: ^Site, b: ^strings.Builder, source, package_name: string, links: ^Site_Code_Links = nil) -> bool {
	tokens, ok := site_code_odin_tokens(source)
	if !ok {
		return false
	}
	classes, keys := site_code_odin_classes(site, source, tokens, package_name)
	position := 0
	open := Site_Code_Class.None // The class of the span that is open.
	close_span :: proc(b: ^strings.Builder, open: ^Site_Code_Class) {
		if open^ != .None {
			strings.write_string(b, "</span>")
			open^ = .None
		}
	}
	for token, index in tokens {
		gap := source[position:token.start]
		class := classes[index]
		// Two tokens of one class with only spaces between share one span:
		// the pages stay smaller.
		if open != .None && (class != open || strings.trim_space(gap) != "") {
			close_span(b, &open)
		}
		site_escape(b, gap)
		bytes := source[token.start:token.end]
		if token.kind == .Ident && links != nil && (class == .None || class == .Type || class == .Literal) {
			if place := site_code_link_place(links, source, tokens, index); place >= 0 {
				close_span(b, &open)
				site_declaration_link_in_code(links.site, b, links.from_page, bytes, class, place)
				position = token.end
				continue
			}
		}
		switch class {
		case .None:
			close_span(b, &open)
			site_escape(b, bytes)
		case .Reference:
			close_span(b, &open)
			site_type_reference(site, b, keys[index], bytes, false)
		case .Keyword, .Type, .Literal, .Name, .Directive, .Comment, .Punctuation:
			if open != class {
				close_span(b, &open)
				fmt.sbprintf(b, "<span class=\"c-%s\">", site_code_classes[class].name)
				open = class
			}
			site_escape(b, bytes)
		}
		position = token.end
	}
	close_span(b, &open)
	site_escape(b, source[position:])
	return true
}

// site_code_block_html gives a text of Odin as the inside of a block of
// code: colored, or plain when the tokenizer refuses it. A plain block is
// counted, and the first one is named by its place, so that it is seen.
site_code_block_html :: proc(site: ^Site, source, package_name, place: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	if site_code_odin(site, &b, source, package_name) {
		return strings.to_string(b)
	}
	site.code_blocks_not_colored += 1
	if site.first_code_block_not_colored == "" {
		site.first_code_block_not_colored = place
	}
	plain := strings.builder_make(context.temp_allocator)
	site_escape(&plain, source)
	return strings.to_string(plain)
}

// site_code_span writes a part of a signature in the span of a class: the
// signatures are built from their parts, so each part has its role with no
// tokenizer.
site_code_span :: proc(b: ^strings.Builder, class: Site_Code_Class, text: string) {
	fmt.sbprintf(b, "<span class=\"c-%s\">", site_code_classes[class].name)
	site_escape(b, text)
	strings.write_string(b, "</span>")
}
