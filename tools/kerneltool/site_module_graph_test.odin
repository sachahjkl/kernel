package kerneltool

import "core:strings"
import "core:testing"
import "support:graphics"

// site_graph_test_names gives a list of names in the memory of the test: a
// slice literal would live in the frame of the procedure that returns it.
@(private = "file")
site_graph_test_names :: proc(names: ..string) -> []string {
	list := make([]string, len(names), context.temp_allocator)
	copy(list, names)
	return list
}

// A small graph: base imports nothing; middle imports base; top imports
// middle and base; alone and other have no edge.
@(private = "file")
site_graph_test_inputs :: proc() -> []Site_Graph_Input {
	inputs := make([]Site_Graph_Input, 5, context.temp_allocator)
	inputs[0] = {name = "base", kind = .No_Entry, size = 1000}
	inputs[1] = {name = "middle", kind = .No_Entry, size = 4000, imports = site_graph_test_names("base")}
	inputs[2] = {name = "top", kind = .Program, size = 8000, imports = site_graph_test_names("middle", "base")}
	inputs[3] = {name = "alone", kind = .Program, size = 0}
	inputs[4] = {name = "kernel_like", kind = .Kernel, size = 16000}
	return inputs
}

// The box of a node: its bar and its name.
@(private = "file")
site_graph_test_box :: proc(node: Site_Graph_Node) -> (left, top, right, bottom: int) {
	return node.x, node.y, node.x + node.bar_width + SITE_GRAPH_LABEL_GAP + node.label_width, node.y + SITE_GRAPH_NODE_HEIGHT
}

// site_graph_test_layout_holds checks the rules that hold for each layout:
// no two nodes overlap, each importer is in a column at the right of each
// module that it imports, each line starts at the bar of the importer and
// ends after the name of the module that it imports, and each node is in
// the picture.
@(private = "file")
site_graph_test_layout_holds :: proc(t: ^testing.T, inputs: []Site_Graph_Input, layout: Site_Graph_Layout) {
	for a, first in layout.nodes {
		left, top, right, bottom := site_graph_test_box(a)
		testing.expectf(t, left >= 0 && top >= 0 && right <= layout.width && bottom <= layout.height, "%s is inside the picture", inputs[first].name)
		for b, second in layout.nodes {
			if second <= first {
				continue
			}
			other_left, other_top, other_right, other_bottom := site_graph_test_box(b)
			apart := right <= other_left || other_right <= left || bottom <= other_top || other_bottom <= top
			testing.expectf(t, apart, "%s and %s do not overlap", inputs[first].name, inputs[second].name)
		}
	}
	for edge in layout.edges {
		from, to := layout.nodes[edge.from], layout.nodes[edge.to]
		testing.expectf(t, from.layer > to.layer && from.x > to.x, "%s is at the right of %s, which it imports", inputs[edge.from].name, inputs[edge.to].name)
		testing.expect_value(t, edge.points[0][0], from.x)
		testing.expect_value(t, edge.points[3][0], to.x + to.bar_width + SITE_GRAPH_LABEL_GAP + to.label_width + 4)
		// The turn is in the gap at the right of the column of the import,
		// before the column of the importer.
		testing.expect(t, edge.points[1][0] > layout.column_x[to.layer] + layout.column_width && edge.points[1][0] < from.x)
		testing.expect(t, edge.points[1][0] == edge.points[2][0] && edge.points[0][1] == edge.points[1][1] && edge.points[2][1] == edge.points[3][1], "three straight segments: across, up or down, across")
	}
}

@(test)
site_graph_layout_rules :: proc(t: ^testing.T) {
	inputs := site_graph_test_inputs()
	layout, problem := site_graph_layout(inputs, 2)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, layout.layer_count, 3)
	testing.expect_value(t, layout.nodes[0].layer, 0)
	testing.expect_value(t, layout.nodes[1].layer, 1)
	testing.expect_value(t, layout.nodes[2].layer, 2)
	testing.expect_value(t, layout.nodes[3].layer, -1)
	testing.expect_value(t, layout.nodes[4].layer, -1)
	testing.expect_value(t, len(layout.edges), 3)
	testing.expect_value(t, layout.band_count, 2)
	// The band is under the layers, the kernel first.
	testing.expect(t, layout.nodes[3].y > layout.nodes[2].y && layout.band_top > layout.nodes[1].y)
	testing.expect(t, layout.nodes[4].row == 0 && layout.nodes[3].row == 1, "the band is by kind: the kernel before the programs")
	// A bar follows the bytes; a module of no known size has the least bar.
	testing.expect_value(t, layout.nodes[4].bar_width, SITE_GRAPH_BAR_MOST)
	testing.expect_value(t, layout.nodes[3].bar_width, SITE_GRAPH_BAR_LEAST)
	testing.expect(t, layout.nodes[0].bar_width < layout.nodes[1].bar_width && layout.nodes[1].bar_width < layout.nodes[2].bar_width)
	// The names are whole: the column holds the longest name.
	testing.expect(t, layout.column_width >= SITE_GRAPH_BAR_MOST + SITE_GRAPH_LABEL_GAP + len("kernel_like") * SITE_GRAPH_CHARACTER_WIDTH)
	site_graph_test_layout_holds(t, inputs, layout)

	// The same inputs give the same layout.
	again, _ := site_graph_layout(inputs, 2)
	testing.expect_value(t, again.width, layout.width)
	testing.expect_value(t, again.height, layout.height)
	for node, index in layout.nodes {
		testing.expect_value(t, again.nodes[index], node)
	}
	for edge, index in layout.edges {
		testing.expect_value(t, again.edges[index].points, edge.points)
	}
}

// The barycentre pass: two importers of two modules are put in the order
// of what they import, and the lines do not cross.
@(test)
site_graph_layout_orders_by_the_imports :: proc(t: ^testing.T) {
	inputs := make([]Site_Graph_Input, 4, context.temp_allocator)
	inputs[0] = {name = "first", kind = .No_Entry, size = 10}
	inputs[1] = {name = "second", kind = .No_Entry, size = 10}
	inputs[2] = {name = "uses_second", kind = .Program, size = 10, imports = {"second"}}
	inputs[3] = {name = "uses_first", kind = .Program, size = 10, imports = {"first"}}
	layout, problem := site_graph_layout(inputs, 1)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, layout.nodes[3].row, 0)
	testing.expect_value(t, layout.nodes[2].row, 1)
	site_graph_test_layout_holds(t, inputs, layout)
}

@(test)
site_graph_layout_refusals :: proc(t: ^testing.T) {
	Case :: struct {
		about:    string,
		imports:  [2][]string,
		expected: string,
	}
	cases := [?]Case {
		{"a cycle", {{"b"}, {"a"}}, "an import cycle through "},
		{"an import of no module", {{"nothing"}, {}}, "a imports nothing, which is not a module of the build"},
		{"a module that imports itself", {{"a"}, {}}, "a imports itself"},
		{"an import named twice", {{"b", "b"}, {}}, "a imports b twice"},
	}
	for item in cases {
		inputs := []Site_Graph_Input{{name = "a", imports = item.imports[0]}, {name = "b", imports = item.imports[1]}}
		_, problem := site_graph_layout(inputs, 1)
		testing.expectf(t, strings.has_prefix(problem, item.expected), "%s: %q", item.about, problem)
	}
	twins := []Site_Graph_Input{{name = "a"}, {name = "a"}}
	_, problem := site_graph_layout(twins, 1)
	testing.expect_value(t, problem, "two modules are named a")
}

// The graph of the build: each import names a module of the build, no
// cycle, and the rules of the layout hold.
@(test)
site_graph_layout_of_the_build :: proc(t: ^testing.T) {
	inputs := make([]Site_Graph_Input, len(module_builds), context.temp_allocator)
	for build, index in module_builds {
		inputs[index] = {name = build.name, kind = build.kernel ? Site_Graph_Kind.Kernel : Site_Graph_Kind.No_Entry, imports = build.imports}
	}
	layout, problem := site_graph_layout(inputs, SITE_GRAPH_BAND_COLUMNS)
	testing.expect_value(t, problem, "")
	imports := 0
	for build in module_builds {
		imports += len(build.imports)
	}
	testing.expect_value(t, len(layout.edges), imports)
	site_graph_test_layout_holds(t, inputs, layout)
}

// The markup: one line for each edge with its two ends, the neighbours of
// each node, the card that a node names, no style of its own; the table
// has each module with its imports and its importers.
@(test)
site_graph_markup :: proc(t: ^testing.T) {
	site: Site
	inputs := site_graph_test_inputs()
	layout, _ := site_graph_layout(inputs, 2)
	page := site_page_file(SITE_MODULE_GRAPH_FOLDER)
	b := strings.builder_make(context.temp_allocator)
	site_graph_svg(&site, &b, page, inputs, layout, "The module graph", -1, true)
	svg := strings.to_string(b)
	testing.expect_value(t, strings.count(svg, "<polyline class=\"graph-edge\""), 3)
	testing.expect(t, strings.contains(svg, "data-from=\"top\" data-to=\"base\""))
	testing.expect_value(t, strings.count(svg, "<a class=\"graph-node"), 5)
	testing.expect(t, strings.contains(svg, "data-module=\"base\" aria-label=\"base, module with no entry, 1000 bytes\" data-card=\"module-card-base\" data-neighbours=\"middle top\""))
	testing.expect(t, strings.contains(svg, "graph-size-unknown"), "a module of no known size has its own class")
	testing.expect(t, strings.contains(svg, "depth 0: imports none") && strings.contains(svg, "no edge: imports none, imported by none (2)"))
	testing.expect(t, !strings.contains(svg, "style="), "no style attribute")
	testing.expect(t, strings.contains(svg, "href=\"../../../docs/reference/modules/base/index.html\""), "a node links to the page of its module")

	strings.builder_reset(&b)
	site_graph_table(&site, &b, page, inputs, layout)
	table := strings.to_string(b)
	testing.expect_value(t, strings.count(table, "<tr id=\"graph-"), 5)
	testing.expect(t, strings.contains(table, "<tr id=\"graph-alone\">"))
	// alone and kernel_like twice, base for its imports, top for its importers.
	testing.expect_value(t, strings.count(table, "none</td>"), 6)

	strings.builder_reset(&b)
	card := Site_Module_Card{name = "middle", kind = .No_Entry, page = site_module_page("middle"), hash_known = false, size = 4000, export_count = 2, import_count = 1, importer_count = 1, about = "A module of the test.", licenses = {{license = "MIT", what = "The system", anchor = "license-the-system"}}}
	site_module_card_write(&site, &b, page, card, true)
	card_html := strings.to_string(b)
	testing.expect(t, strings.has_prefix(card_html, "<div class=\"module-card graph-no-entry\" id=\"module-card-middle\" hidden>"))
	testing.expect(t, strings.contains(card_html, "4000 bytes") && strings.contains(card_html, "A module of the test.") && strings.contains(card_html, "#license-the-system"))
	// On its own page, the title of the card is not a link.
	strings.builder_reset(&b)
	site_module_card_write(&site, &b, site_module_page("middle"), card, false)
	own := strings.to_string(b)
	testing.expect(t, strings.has_prefix(own, "<div class=\"module-card graph-no-entry\" id=\"module-card-middle\">"))
	testing.expect(t, strings.contains(own, "<p class=\"module-card-title\">middle <span"))
}

// The neighbours of a module: the module, what it imports, what imports
// it, and the edges of the module only.
@(test)
site_graph_neighbours_figure :: proc(t: ^testing.T) {
	site: Site
	inputs := site_graph_test_inputs()
	neighbours, current := site_module_neighbours_inputs(inputs, "middle")
	testing.expect_value(t, current, 0)
	testing.expect_value(t, len(neighbours), 3)
	testing.expect_value(t, neighbours[1].name, "base")
	testing.expect_value(t, len(neighbours[1].imports), 0)
	testing.expect_value(t, neighbours[2].name, "top")
	testing.expect_value(t, len(neighbours[2].imports), 1)
	testing.expect_value(t, neighbours[2].imports[0], "middle")
	layout, problem := site_graph_layout(neighbours, 1)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(layout.edges), 2)
	testing.expect_value(t, layout.band_count, 0)
	site_graph_test_layout_holds(t, neighbours, layout)

	page := site_module_page("middle")
	b := strings.builder_make(context.temp_allocator)
	site_module_neighbours_write(&site, &b, page, inputs, "middle")
	figure := strings.to_string(b)
	testing.expect(t, strings.contains(figure, "<g class=\"graph-node graph-no-entry graph-current\" data-module=\"middle\""), "the module itself is not a link")
	testing.expect_value(t, strings.count(figure, "<polyline"), 2)
	testing.expect(t, !strings.contains(figure, "graph-heading"), "a subgraph has no headings of depth")

	strings.builder_reset(&b)
	site_module_neighbours_write(&site, &b, site_module_page("alone"), inputs, "alone")
	testing.expect(t, strings.contains(strings.to_string(b), "It imports no module, and no module imports it."))
}

// Each kind keeps the contrast of a graphic on the background and on the
// panel of the picture, in both forms.
@(test)
site_graph_kind_colors_keep_their_contrast :: proc(t: ^testing.T) {
	for light in ([]bool{false, true}) {
		colors := light ? site_light_colors() : site_dark_colors()
		for kind in Site_Graph_Kind {
			color := site_graph_kind_color(kind, light)
			for surface in ([]graphics.Color{colors.background, colors.card_bottom, colors.card_top}) {
				ratio := site_contrast_ratio(color, surface)
				testing.expectf(t, ratio >= SITE_VALUE_GRAPHIC_CONTRAST_LEAST, "%v (light form: %v) on %06x: %.2f", kind, light, surface, ratio)
			}
		}
	}
}
