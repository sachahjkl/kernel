// The module graph of the site (docs/SITE.md, "The module graph"): each
// module of module_builds as a node, and each import as an edge, in layers
// by the depth of the imports. The layout is computed here, in whole
// pixels, with no randomness: the same build gives the same picture. The
// same layout draws the neighbours of one module on its page, and one
// procedure writes the identity card of a module on both pages.
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modus:support/graphics"

SITE_MODULE_GRAPH_FOLDER :: SITE_REFERENCE_FOLDER + "/module-graph"
SITE_MODULE_GRAPH_SCRIPT :: "module_graph.js"

// The sizes of the layout, in pixels of the picture.
SITE_GRAPH_MARGIN :: 16
SITE_GRAPH_HEADING :: 24 // The line of a heading above a part of the picture.
SITE_GRAPH_ROW_PITCH :: 24
SITE_GRAPH_NODE_HEIGHT :: 16
SITE_GRAPH_BAR_LEAST :: 4 // The bar of the smallest module, or of a module whose size is not known.
SITE_GRAPH_BAR_MOST :: 96 // The bar of the largest module.
SITE_GRAPH_LABEL_GAP :: 6
// The width of one character of a name: the names are ASCII, in the
// monospace font of the reader at 12 pixels. The common monospace fonts
// advance 0.6 em; 8 pixels leaves room for one that advances 0.66 em, so
// that no name runs into the next column.
SITE_GRAPH_CHARACTER_WIDTH :: 8
SITE_GRAPH_LABEL_END :: 8
SITE_GRAPH_EDGE_GAP_LEAST :: 48
SITE_GRAPH_LANE_STEP :: 6
SITE_GRAPH_LANE_MARGIN :: 16
SITE_GRAPH_BAND_GAP :: 32
SITE_GRAPH_BAND_COLUMN_GAP :: 16
SITE_GRAPH_BAND_COLUMNS :: 2 // The columns of the modules with no edge, on the page of the graph.

// The kind of a node: the kinds of the card of the boot image, and the
// kernel. A resource of the boot image is not a module, imports nothing
// and is imported by none: it is not a node.
Site_Graph_Kind :: enum {
	Kernel, // Runs in kernel mode.
	Program, // A module with an entry: a program starts from it.
	No_Entry, // A module with no entry: another module imports it, or a program loads it.
}

site_graph_kind_names := [Site_Graph_Kind]string {
	.Kernel   = "kernel",
	.Program  = "program",
	.No_Entry = "module with no entry",
}

site_graph_kind_classes := [Site_Graph_Kind]string {
	.Kernel   = "graph-kernel",
	.Program  = "graph-program",
	.No_Entry = "graph-no-entry",
}

site_graph_kind_meanings := [Site_Graph_Kind]string {
	.Kernel   = "runs in kernel mode",
	.Program  = "has an entry: a program starts from it",
	.No_Entry = "has no entry: another module imports it, or a program loads it by its name",
}

// The accent of each kind: the colors of the card of the boot image.
site_graph_kind_colors := [Site_Graph_Kind]graphics.Color {
	.Kernel   = graphics.COLOR_KERNEL,
	.Program  = graphics.COLOR_PROGRAM,
	.No_Entry = graphics.COLOR_NO_ENTRY,
}

// The shade of each accent in the light form, so that a bar keeps the
// contrast of a graphic on the light background.
site_graph_kind_light_shades := [Site_Graph_Kind]u32 {
	.Kernel   = 73,
	.Program  = 58,
	.No_Entry = 55,
}

// site_graph_kind_color gives the color of a kind in one form.
site_graph_kind_color :: proc(kind: Site_Graph_Kind, light: bool) -> graphics.Color {
	if light {
		return graphics.shade(site_graph_kind_colors[kind], site_graph_kind_light_shades[kind])
	}
	return site_graph_kind_colors[kind]
}

// One module, as the layout and the card read it.
Site_Graph_Input :: struct {
	name:       string,
	kind:       Site_Graph_Kind,
	size:       u64, // The bytes of the module file. 0: not known.
	hash:       [32]u8,
	hash_known: bool,
	imports:    []string, // The names of the modules that it imports.
}

Site_Graph_Node :: struct {
	layer:       int, // The depth of its imports, or -1: the node has no edge, and is in the band under the layers.
	row:         int, // Its place in its layer, or in the band, from 0.
	x, y:        int, // The top left corner of its bar.
	bar_width:   int,
	label_width: int,
}

// An edge: the module `from` imports the module `to`. Its line goes from
// the left end of the bar of the importer to the end of the name of the
// module that it imports: four points, three straight segments.
Site_Graph_Edge :: struct {
	from, to: int, // Indices of the inputs and of the nodes.
	points:   [4][2]int,
}

Site_Graph_Layout :: struct {
	nodes:        []Site_Graph_Node, // In the order of the inputs.
	edges:        []Site_Graph_Edge, // In the order of the inputs and of their imports.
	layer_count:  int, // 0 when no node has an edge.
	column_x:     []int, // The left side of each layer.
	column_width: int,
	band_count:   int, // The nodes with no edge.
	band_top:     int, // The line of the heading of the band, when the band has a node.
	width:        int,
	height:       int,
}

// site_graph_layout places the nodes and the edges.
//
// The rule:
//   - an edge is an import of module_builds: A imports B. An import that
//     names no module of the build, a module that imports itself, an
//     import named twice and a cycle stop the command;
//   - the layer of a node is the depth of its imports: 0 for a module that
//     imports nothing, else one more than the deepest of its imports. A
//     layer is a column, the layer 0 at the left: each importer is to the
//     right of each module that it imports;
//   - a node with no edge is in the band under the layers, by kind, then in
//     the order of the build, column by column;
//   - in a layer, the nodes start in the order of the build. One pass from
//     the left orders each layer by the mean place of the imports of each
//     node, then one pass from the right orders each layer by the mean
//     place of its importers. A node with no such neighbour keeps its
//     place; equal means keep their order;
//   - each edge turns in the gap at the right of the layer of the module
//     that it imports, on a lane of its own, in the order of the place of
//     that module, then of the importer.
site_graph_layout :: proc(inputs: []Site_Graph_Input, band_columns: int) -> (layout: Site_Graph_Layout, problem: string) {
	count := len(inputs)
	index_of := make(map[string]int, context.temp_allocator)
	for input, index in inputs {
		if _, found := index_of[input.name]; found {
			return {}, fmt.tprintf("two modules are named %s", input.name)
		}
		index_of[input.name] = index
	}
	edges := make([dynamic]Site_Graph_Edge, context.temp_allocator)
	has_edge := make([]bool, count, context.temp_allocator)
	for input, from in inputs {
		for name, place in input.imports {
			to, found := index_of[name]
			if !found {
				return {}, fmt.tprintf("%s imports %s, which is not a module of the build", input.name, name)
			}
			if to == from {
				return {}, fmt.tprintf("%s imports itself", input.name)
			}
			for earlier in input.imports[:place] {
				if earlier == name {
					return {}, fmt.tprintf("%s imports %s twice", input.name, name)
				}
			}
			append(&edges, Site_Graph_Edge{from = from, to = to})
			has_edge[from], has_edge[to] = true, true
		}
	}

	// The depth of each node. A path has at most count - 1 edges, so the
	// depths stop changing within count rounds; a change after that is a
	// cycle. Imports are hashes, so the files of a build cannot hold one.
	depth := make([]int, count, context.temp_allocator)
	for round in 0 ..= count {
		changed := -1
		for edge in edges {
			if depth[edge.from] < depth[edge.to] + 1 {
				depth[edge.from] = depth[edge.to] + 1
				changed = edge.from
			}
		}
		if changed < 0 {
			break
		}
		if round == count {
			return {}, fmt.tprintf("an import cycle through %s", inputs[changed].name)
		}
	}

	nodes := make([]Site_Graph_Node, count, context.temp_allocator)
	layer_count := 0
	for index in 0 ..< count {
		nodes[index].layer = has_edge[index] ? depth[index] : -1
		layer_count = max(layer_count, nodes[index].layer + 1)
	}
	layers := make([][dynamic]int, layer_count, context.temp_allocator)
	for &layer in layers {
		layer = make([dynamic]int, context.temp_allocator)
	}
	for index in 0 ..< count {
		if nodes[index].layer >= 0 {
			append(&layers[nodes[index].layer], index)
		}
	}
	for layer in layers {
		for node, row in layer {
			nodes[node].row = row
		}
	}
	for layer in 1 ..< layer_count {
		site_graph_order(layers[layer][:], nodes, edges[:], true)
	}
	for layer := layer_count - 2; layer >= 0; layer -= 1 {
		site_graph_order(layers[layer][:], nodes, edges[:], false)
	}

	// The sizes of the bars and of the names.
	largest: u64 = 0
	longest := 0
	for input in inputs {
		largest = max(largest, input.size)
		longest = max(longest, len(input.name))
	}
	for input, index in inputs {
		nodes[index].bar_width = SITE_GRAPH_BAR_LEAST
		if input.size > 0 && largest > 0 {
			nodes[index].bar_width = SITE_GRAPH_BAR_LEAST + int(u64(SITE_GRAPH_BAR_MOST - SITE_GRAPH_BAR_LEAST) * input.size / largest)
		}
		nodes[index].label_width = len(input.name) * SITE_GRAPH_CHARACTER_WIDTH
	}
	column_width := SITE_GRAPH_BAR_MOST + SITE_GRAPH_LABEL_GAP + longest * SITE_GRAPH_CHARACTER_WIDTH + SITE_GRAPH_LABEL_END

	// The lanes of the edges in each gap.
	lane_counts := make([]int, max(layer_count, 1), context.temp_allocator)
	lanes := make([]int, len(edges), context.temp_allocator)
	order := make([]int, len(edges), context.temp_allocator)
	for index in 0 ..< len(edges) {
		order[index] = index
	}
	// An insertion sort: stable, and the lists are short.
	for index in 1 ..< len(order) {
		held := order[index]
		place := index
		for place > 0 && site_graph_lane_before(nodes, edges[held], edges[order[place - 1]]) {
			order[place] = order[place - 1]
			place -= 1
		}
		order[place] = held
	}
	for index in order {
		gap := nodes[edges[index].to].layer
		lanes[index] = lane_counts[gap]
		lane_counts[gap] += 1
	}
	column_x := make([]int, layer_count, context.temp_allocator)
	gap_widths := make([]int, layer_count, context.temp_allocator)
	for layer in 0 ..< layer_count {
		gap_widths[layer] = max(SITE_GRAPH_EDGE_GAP_LEAST, 2 * SITE_GRAPH_LANE_MARGIN + lane_counts[layer] * SITE_GRAPH_LANE_STEP)
		column_x[layer] = SITE_GRAPH_MARGIN
		if layer > 0 {
			column_x[layer] = column_x[layer - 1] + column_width + gap_widths[layer - 1]
		}
	}

	// The layers.
	layers_top := SITE_GRAPH_MARGIN + SITE_GRAPH_HEADING
	bottom := SITE_GRAPH_MARGIN
	right := SITE_GRAPH_MARGIN
	for layer in 0 ..< layer_count {
		for node in layers[layer] {
			nodes[node].x = column_x[layer]
			nodes[node].y = layers_top + nodes[node].row * SITE_GRAPH_ROW_PITCH
		}
		bottom = max(bottom, layers_top + len(layers[layer]) * SITE_GRAPH_ROW_PITCH)
		right = column_x[layer] + column_width
	}

	// The band: the nodes with no edge, by kind, then in the order of the
	// build, column by column.
	band := make([dynamic]int, context.temp_allocator)
	for kind in Site_Graph_Kind {
		for input, index in inputs {
			if nodes[index].layer < 0 && input.kind == kind {
				append(&band, index)
			}
		}
	}
	band_top := 0
	if len(band) > 0 {
		band_top = layer_count > 0 ? bottom + SITE_GRAPH_BAND_GAP : SITE_GRAPH_MARGIN
		columns := clamp(band_columns, 1, len(band))
		rows := (len(band) + columns - 1) / columns
		rows_top := band_top + SITE_GRAPH_HEADING
		for node, place in band {
			nodes[node].row = place
			nodes[node].x = SITE_GRAPH_MARGIN + (place / rows) * (column_width + SITE_GRAPH_BAND_COLUMN_GAP)
			nodes[node].y = rows_top + (place % rows) * SITE_GRAPH_ROW_PITCH
		}
		used_columns := (len(band) + rows - 1) / rows
		bottom = rows_top + rows * SITE_GRAPH_ROW_PITCH
		right = max(right, SITE_GRAPH_MARGIN + used_columns * column_width + (used_columns - 1) * SITE_GRAPH_BAND_COLUMN_GAP)
	}

	// The lines of the edges.
	for &edge, index in edges {
		from, to := nodes[edge.from], nodes[edge.to]
		turn := column_x[to.layer] + column_width + SITE_GRAPH_LANE_MARGIN + lanes[index] * SITE_GRAPH_LANE_STEP
		from_y := from.y + SITE_GRAPH_NODE_HEIGHT / 2
		to_y := to.y + SITE_GRAPH_NODE_HEIGHT / 2
		end := to.x + to.bar_width + SITE_GRAPH_LABEL_GAP + to.label_width + 4
		edge.points = {{from.x, from_y}, {turn, from_y}, {turn, to_y}, {end, to_y}}
	}

	return Site_Graph_Layout{nodes = nodes, edges = edges[:], layer_count = layer_count, column_x = column_x, column_width = column_width, band_count = len(band), band_top = band_top, width = right + SITE_GRAPH_MARGIN, height = bottom + SITE_GRAPH_MARGIN}, ""
}

// site_graph_lane_before says if edge a takes a lane before edge b: by the
// place of the module that it imports, then of the importer.
site_graph_lane_before :: proc(nodes: []Site_Graph_Node, a, b: Site_Graph_Edge) -> bool {
	if nodes[a.to].layer != nodes[b.to].layer {
		return nodes[a.to].layer < nodes[b.to].layer
	}
	if nodes[a.to].row != nodes[b.to].row {
		return nodes[a.to].row < nodes[b.to].row
	}
	return nodes[a.from].row < nodes[b.from].row
}

// site_graph_order orders one layer by the mean place of the neighbours of
// each node: its imports (by_imports), or its importers. The mean is kept
// as a whole number in 1024ths of a row, so that the order is the same on
// every machine. The rows of the layer are numbered again after it.
site_graph_order :: proc(layer: []int, nodes: []Site_Graph_Node, edges: []Site_Graph_Edge, by_imports: bool) {
	keys := make([]int, len(nodes), context.temp_allocator)
	for node in layer {
		sum, count := 0, 0
		for edge in edges {
			if by_imports && edge.from == node {
				sum += nodes[edge.to].row
				count += 1
			} else if !by_imports && edge.to == node {
				sum += nodes[edge.from].row
				count += 1
			}
		}
		keys[node] = count > 0 ? sum * 1024 / count : nodes[node].row * 1024
	}
	for index in 1 ..< len(layer) {
		held := layer[index]
		place := index
		for place > 0 && keys[held] < keys[layer[place - 1]] {
			layer[place] = layer[place - 1]
			place -= 1
		}
		layer[place] = held
	}
	for node, row in layer {
		nodes[node].row = row
	}
}

// site_graph_neighbours gives the names of the modules that a node imports
// and that import it, each once, in the order of the edges.
site_graph_neighbours :: proc(inputs: []Site_Graph_Input, layout: Site_Graph_Layout, node: int) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	add :: proc(names: ^[dynamic]string, name: string) {
		for present in names {
			if present == name {
				return
			}
		}
		append(names, name)
	}
	for edge in layout.edges {
		if edge.from == node {
			add(&names, inputs[edge.to].name)
		} else if edge.to == node {
			add(&names, inputs[edge.from].name)
		}
	}
	return names[:]
}

// site_graph_importer_count gives the count of the modules that import a node.
site_graph_importer_count :: proc(layout: Site_Graph_Layout, node: int) -> (count: int) {
	for edge in layout.edges {
		count += int(edge.to == node)
	}
	return count
}

// site_graph_size_text gives the size of a module for a reader.
site_graph_size_text :: proc(size: u64) -> string {
	return size == 0 ? "size not known" : fmt.tprintf("%d bytes", size)
}

// site_graph_hash_text gives a hash in hexadecimal, 64 digits.
site_graph_hash_text :: proc(hash: [32]u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	for byte_value in hash {
		fmt.sbprintf(&b, "%02x", byte_value)
	}
	return strings.to_string(b)
}

// site_graph_svg writes the picture of a layout in a box that scrolls
// sideways, as a table does: the picture keeps its pixels, so that a name
// is never smaller than 12 pixels. Each node is a link to the page of its
// module, but the node `current`, which is the page itself. With `cards`,
// a node names the identity card that the script opens for it.
site_graph_svg :: proc(site: ^Site, b: ^strings.Builder, page: string, inputs: []Site_Graph_Input, layout: Site_Graph_Layout, label: string, current: int, cards: bool) {
	strings.write_string(b, "<div class=\"graph-box\" role=\"region\" tabindex=\"0\" aria-label=\"")
	site_escape(b, label)
	fmt.sbprintf(b, "\">\n<svg class=\"graph\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"group\" aria-label=\"", layout.width, layout.height, layout.width, layout.height)
	site_escape(b, label)
	strings.write_string(b, "\">\n")
	// The heading of each layer, and of the band.
	for x, layer in layout.column_x {
		if !cards {
			break
		}
		heading: string = layer == 0 ? "depth 0: imports none" : fmt.tprintf("depth %d", layer)
		fmt.sbprintf(b, "<text class=\"graph-heading\" x=\"%d\" y=\"%d\">%s</text>\n", x, SITE_GRAPH_MARGIN + 12, heading)
	}
	if layout.band_count > 0 {
		fmt.sbprintf(b, "<text class=\"graph-heading\" x=\"%d\" y=\"%d\">no edge: imports none, imported by none (%d)</text>\n", SITE_GRAPH_MARGIN, layout.band_top + 12, layout.band_count)
	}
	// The edges first, so that a node is drawn over a line.
	strings.write_string(b, "<g class=\"graph-edges\">\n")
	for edge in layout.edges {
		fmt.sbprintf(b, "<polyline class=\"graph-edge\" data-from=\"%s\" data-to=\"%s\" points=\"", inputs[edge.from].name, inputs[edge.to].name)
		for point, index in edge.points {
			fmt.sbprintf(b, "%s%d,%d", index > 0 ? " " : "", point[0], point[1])
		}
		strings.write_string(b, "\"/>\n")
	}
	strings.write_string(b, "</g>\n<g class=\"graph-nodes\">\n")
	for input, index in inputs {
		node := layout.nodes[index]
		classes := strings.concatenate({"graph-node ", site_graph_kind_classes[input.kind], input.size == 0 ? " graph-size-unknown" : "", index == current ? " graph-current" : ""}, context.temp_allocator)
		described := fmt.tprintf("%s, %s, %s", input.name, site_graph_kind_names[input.kind], site_graph_size_text(input.size))
		if index == current {
			fmt.sbprintf(b, "<g class=\"%s\" data-module=\"%s\" aria-label=\"%s\">", classes, input.name, described)
		} else {
			item, found := site_module_by_name(site, input.name)
			address := found ? site_page_link(site, page, item.page) : site_page_link(site, page, site_module_page(input.name))
			fmt.sbprintf(b, "<a class=\"%s\" href=\"%s\" data-module=\"%s\" aria-label=\"%s\"", classes, address, input.name, described)
			if cards {
				fmt.sbprintf(b, " data-card=\"%s\" data-neighbours=\"%s\"", site_module_card_id(input.name), strings.join(site_graph_neighbours(inputs, layout, index), " ", context.temp_allocator))
			}
			strings.write_string(b, ">")
		}
		fmt.sbprintf(b, "<rect class=\"graph-bar\" x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"/>", node.x, node.y, node.bar_width, SITE_GRAPH_NODE_HEIGHT)
		fmt.sbprintf(b, "<text class=\"graph-name\" x=\"%d\" y=\"%d\">%s</text>", node.x + node.bar_width + SITE_GRAPH_LABEL_GAP, node.y + 12, input.name)
		strings.write_string(b, index == current ? "</g>\n" : "</a>\n")
	}
	strings.write_string(b, "</g>\n</svg>\n</div>\n")
}

// site_graph_legend writes the legend of the picture: the color of each
// kind, and what a line, a bar and a column are.
site_graph_legend :: proc(b: ^strings.Builder) {
	strings.write_string(b, "<ul class=\"graph-legend\">\n")
	for kind in Site_Graph_Kind {
		fmt.sbprintf(b, "<li class=\"%s\"><svg class=\"graph-swatch\" width=\"16\" height=\"12\" aria-hidden=\"true\" focusable=\"false\"><rect class=\"graph-bar\" width=\"16\" height=\"12\"/></svg>%s: %s</li>\n", site_graph_kind_classes[kind], site_graph_kind_names[kind], site_graph_kind_meanings[kind])
	}
	fmt.sbprintf(b, "<li class=\"graph-legend-line\"><svg class=\"graph-swatch\" width=\"16\" height=\"12\" aria-hidden=\"true\" focusable=\"false\"><polyline class=\"graph-edge\" points=\"0,6 16,6\"/></svg>an import: the line leaves the left end of the bar of the importer and ends after the name of the module that it imports, which is in a column at its left</li>\n")
	fmt.sbprintf(b, "<li>A bar is as long as the bytes of the module: %d pixels for the largest, %d for the smallest; an empty bar: the size is not known</li>\n", SITE_GRAPH_BAR_MOST, SITE_GRAPH_BAR_LEAST)
	strings.write_string(b, "</ul>\n")
}

// The identity card of a module: who it is, what it holds, what it uses.
Site_Module_Card :: struct {
	name:           string,
	kind:           Site_Graph_Kind,
	page:           string, // The page of the module.
	hash:           [32]u8,
	hash_known:     bool,
	size:           u64,
	export_count:   int,
	import_count:   int,
	importer_count: int,
	about:          string, // The first sentence of its documentation, with no reference.
	licenses:       []Site_Module_License,
}

// A license of a module: the license of the system, and each row of the
// licenses whose place is in the source folder of the module.
Site_Module_License :: struct {
	license: string,
	what:    string,
	anchor:  string, // The id of the row on the page of the licenses.
}

site_module_card_id :: proc(name: string) -> string {
	return strings.concatenate({"module-card-", site_slug(name)}, context.temp_allocator)
}

// site_module_card_of gathers the identity card of one module from the
// same facts as its page: its build, its source, the boot image, the
// graph, and the licenses.
site_module_card_of :: proc(site: ^Site, item: Site_Module, inputs: []Site_Graph_Input, layout: Site_Graph_Layout) -> Site_Module_Card {
	card := Site_Module_Card{name = item.build.name, page = item.page, export_count = len(item.description.exports), import_count = len(item.build.imports)}
	for export in item.description.exports {
		if export.name == ENTRY_NAME {
			card.export_count -= 1 // The entry is not a function that a caller calls.
		}
	}
	for input, index in inputs {
		if input.name == item.build.name {
			card.kind, card.size, card.hash, card.hash_known = input.kind, input.size, input.hash, input.hash_known
			card.importer_count = site_graph_importer_count(layout, index)
		}
	}
	if item.description.about != "" {
		card.about = site_source_comment_plain(site, item.description.about)
	}
	licenses := make([dynamic]Site_Module_License, context.temp_allocator)
	system_ids, _ := site_license_row_ids(site.licenses)
	for row, index in site.licenses.system_rows {
		if index == 0 || (row.place != "" && strings.has_prefix(row.place, strings.concatenate({item.build.source, "/"}, context.temp_allocator))) {
			append(&licenses, Site_Module_License{license = row.license, what = row.what, anchor = index < len(system_ids) ? system_ids[index] : ""})
		}
	}
	card.licenses = licenses[:]
	return card
}

// site_module_card_write writes the identity card of a module. The page of
// the graph holds the card of each module, hidden until the script shows
// the card of the node under the pointer or the focus; the page of a
// module shows its own card. One markup for both.
site_module_card_write :: proc(site: ^Site, b: ^strings.Builder, page: string, card: Site_Module_Card, hidden: bool) {
	fmt.sbprintf(b, "<div class=\"module-card %s\" id=\"%s\"%s>\n", site_graph_kind_classes[card.kind], site_module_card_id(card.name), hidden ? " hidden" : "")
	strings.write_string(b, "<p class=\"module-card-title\">")
	if card.page != "" && card.page != page {
		fmt.sbprintf(b, "<a href=\"%s\">", site_page_link(site, page, card.page))
		site_escape(b, card.name)
		strings.write_string(b, "</a>")
	} else {
		site_escape(b, card.name)
	}
	fmt.sbprintf(b, " <span class=\"module-card-kind\">%s</span></p>\n<dl class=\"module-card-facts\">\n", site_graph_kind_names[card.kind])
	strings.write_string(b, "<dt>Hash</dt><dd>")
	site_value(b, .Version, card.hash_known ? site_graph_hash_text(card.hash) : "not known: the module is not built", false)
	strings.write_string(b, "</dd>\n<dt>Size</dt><dd>")
	site_value(b, .Size, site_graph_size_text(card.size), false)
	strings.write_string(b, "</dd>\n<dt>Exports</dt><dd>")
	site_value(b, .Number, fmt.tprintf("%d", card.export_count), false)
	strings.write_string(b, "</dd>\n<dt>Imports</dt><dd>")
	site_value(b, .Number, fmt.tprintf("%d", card.import_count), false)
	strings.write_string(b, "</dd>\n<dt>Imported by</dt><dd>")
	site_value(b, .Number, fmt.tprintf("%d", card.importer_count), false)
	strings.write_string(b, "</dd>\n<dt>License</dt><dd>")
	licenses_page := site_page_file(SITE_LICENSES_FOLDER)
	for license, index in card.licenses {
		if index > 0 {
			strings.write_string(b, "; ")
		}
		anchor: string = license.anchor != "" ? strings.concatenate({"#", license.anchor}, context.temp_allocator) : ""
		fmt.sbprintf(b, "<a href=\"%s\">", site_page_link(site, page, strings.concatenate({licenses_page, anchor}, context.temp_allocator)))
		site_escape(b, license.license)
		strings.write_string(b, "</a>")
		if index > 0 {
			strings.write_string(b, " (")
			site_escape(b, license.what)
			strings.write_string(b, ")")
		}
	}
	if len(card.licenses) == 0 {
		strings.write_string(b, "not recorded")
	}
	strings.write_string(b, "</dd>\n</dl>\n")
	if card.about != "" {
		strings.write_string(b, "<p class=\"module-card-about\">")
		site_escape(b, card.about)
		strings.write_string(b, "</p>\n")
	}
	strings.write_string(b, "</div>\n")
}

// site_graph_table writes the table of the edges under the picture: each
// module, what it imports and what imports it. A reader with no picture
// and a screen reader get the whole graph from it.
site_graph_table :: proc(site: ^Site, b: ^strings.Builder, page: string, inputs: []Site_Graph_Input, layout: Site_Graph_Layout) {
	// What a module imports and what imports it are lists of names.
	table := site_table_start(b, "The edges of the module graph", {{"Module", .Name}, {"Kind", .Short}, {"Imports", .List}, {"Imported by", .List}}, {.Module, .None, .Module, .Module})
	for input, index in inputs {
		fmt.sbprintf(b, "<tr id=\"graph-%s\"><td class=\"code name\">", site_slug(input.name))
		site_module_link(site, b, page, input.name)
		fmt.sbprintf(b, "</td><td>%s</td><td>", site_graph_kind_names[input.kind])
		imported := make([dynamic]string, context.temp_allocator)
		importers := make([dynamic]string, context.temp_allocator)
		for edge in layout.edges {
			if edge.from == index {
				append(&imported, inputs[edge.to].name)
			}
			if edge.to == index {
				append(&importers, inputs[edge.from].name)
			}
		}
		site_module_list(site, b, page, imported[:])
		strings.write_string(b, "</td><td>")
		site_module_list(site, b, page, importers[:])
		strings.write_string(b, "</td></tr>\n")
	}
	site_table_end(b, table)
}

// site_module_graph_inputs gives the node of each module of the build: its
// kind, and its size and hash from the boot image of the last build, or
// from its module file for a module that is not in the image. A module
// that is not built has no size and no hash.
site_module_graph_inputs :: proc(site: ^Site) -> []Site_Graph_Input {
	inputs := make([]Site_Graph_Input, len(site.reference.modules), context.temp_allocator)
	for item, index in site.reference.modules {
		input := Site_Graph_Input{name = item.build.name, kind = .No_Entry, imports = item.build.imports}
		if item.build.kernel {
			input.kind = .Kernel
		} else {
			for export in item.description.exports {
				if export.name == ENTRY_NAME {
					input.kind = .Program
				}
			}
		}
		if entry, found := site_boot_image_entry(site, item.build.name); found {
			input.size, input.hash, input.hash_known = entry.size, entry.hash, true
		} else if data, err := os.read_entire_file(module_path(item.build.name), context.temp_allocator); err == nil {
			input.size, input.hash, input.hash_known = u64(len(data)), blake3.hash(data), true
		}
		inputs[index] = input
	}
	return inputs
}

// site_module_neighbours_inputs gives the subgraph of one module: the
// module, each module that it imports and each module that imports it,
// with the edges of the module only.
site_module_neighbours_inputs :: proc(inputs: []Site_Graph_Input, name: string) -> (neighbours: []Site_Graph_Input, current: int) {
	list := make([dynamic]Site_Graph_Input, context.temp_allocator)
	current = -1
	for input in inputs {
		if input.name == name {
			current = len(list)
			append(&list, input)
		}
	}
	if current < 0 {
		return nil, -1
	}
	// The list grows in the loop: the imports are read from a copy.
	own_imports := list[current].imports
	for imported in own_imports {
		for input in inputs {
			if input.name == imported {
				kept := input
				kept.imports = nil
				append(&list, kept)
			}
		}
	}
	for input in inputs {
		for imported in input.imports {
			if imported == name {
				kept := input
				only := make([]string, 1, context.temp_allocator)
				only[0] = name
				kept.imports = only
				append(&list, kept)
			}
		}
	}
	return list[:], current
}

// site_module_neighbours_write writes the figure of the neighbours of a
// module on its page: the same layout procedure on its subgraph, with no
// band. A module with no edge has a sentence.
site_module_neighbours_write :: proc(site: ^Site, b: ^strings.Builder, page: string, inputs: []Site_Graph_Input, name: string) {
	graph_page := site_page_file(SITE_MODULE_GRAPH_FOLDER)
	strings.write_string(b, "<h2 id=\"neighbours\">Neighbours</h2>\n")
	neighbours, current := site_module_neighbours_inputs(inputs, name)
	if current < 0 || len(neighbours) == 1 {
		fmt.sbprintf(b, "<p>It imports no module, and no module imports it. The <a href=\"%s#graph-%s\">module graph</a> shows it with the other modules that have no edge.</p>\n", site_page_link(site, page, graph_page), site_slug(name))
		return
	}
	layout, problem := site_graph_layout(neighbours, 1)
	if problem != "" {
		// The layout of the whole graph was checked before any page.
		fmt.sbprintf(b, "<p class=\"missing\">The figure is not drawn: %s.</p>\n", problem)
		return
	}
	fmt.sbprintf(b, "<p>What it imports, at its left, and what imports it, at its right: the part of the <a href=\"%s\">module graph</a> that touches it.</p>\n", site_page_link(site, page, graph_page))
	site_graph_svg(site, b, page, neighbours, layout, fmt.tprintf("The neighbours of %s", name), current, false)
}

// site_module_graph_page_add writes the page of the module graph, and
// prints its counts: the nodes, the edges, the depth, and the modules
// with no entry that no module imports.
site_module_graph_page_add :: proc(site: ^Site, entries: ^[dynamic]Site_Reference_Entry, inputs: []Site_Graph_Input, layout: Site_Graph_Layout) {
	path := site_page_file(SITE_MODULE_GRAPH_FOLDER)
	modules_page := site_page_file(SITE_MODULES_FOLDER)
	unimported := make([dynamic]string, context.temp_allocator)
	for input, index in inputs {
		if input.kind == .No_Entry && site_graph_importer_count(layout, index) == 0 {
			append(&unimported, input.name)
		}
	}
	depth := max(layout.layer_count - 1, 0)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<h1>The module graph</h1>\n")
	fmt.sbprintf(&b, "<p>Each module and program of the build is a node: %d nodes. Each import is an edge: %d edges, a depth of %d. An edge is an import of the module file: the module names the hash of another module, and a loader puts that module in the same program. ", len(inputs), len(layout.edges), depth)
	strings.write_string(&b, "An edge is not a library of <code>contract</code> or <code>support</code>, which the build compiles into each module; not a module that a program loads by its name, as the console does; not a connection to a service; and not a replacement of an import, which the machine decides when a program starts.</p>\n")
	fmt.sbprintf(&b, "<p>The nodes are read from <code>module_builds</code>; see the <a href=\"%s\">modules</a> for the page of each. A pointer on a node, or the focus, marks its edges and its neighbours and shows its identity card; a click opens its page. The table under the picture gives every edge.</p>\n", site_page_link(site, path, modules_page))
	strings.write_string(&b, "<figure class=\"graph-figure\" id=\"module-graph\">\n")
	site_graph_svg(site, &b, path, inputs, layout, "The module graph", -1, true)
	strings.write_string(&b, "<figcaption>\n")
	site_graph_legend(&b)
	strings.write_string(&b, "</figcaption>\n</figure>\n")
	// The cards: hidden until the script shows one. With no script the
	// page is the picture, its legend and the table.
	strings.write_string(&b, "<div class=\"graph-cards\" id=\"graph-cards\" aria-live=\"polite\" hidden>\n")
	for item in site.reference.modules {
		site_module_card_write(site, &b, path, site_module_card_of(site, item, inputs, layout), true)
	}
	strings.write_string(&b, "</div>\n")
	strings.write_string(&b, "<h2 id=\"edges\">The edges</h2>\n")
	site_graph_table(site, &b, path, inputs, layout)
	strings.write_string(&b, "<h2 id=\"no-importer\">Modules with no entry that no module imports</h2>\n")
	if len(unimported) == 0 {
		strings.write_string(&b, "<p>None.</p>\n")
	} else {
		fmt.sbprintf(&b, "<p>%d modules have no entry and no importer in the build. A program can still load one by its name, or a replacement can put one in place of an import: the graph shows the build, not what runs.</p>\n<p>", len(unimported))
		for name, index in unimported {
			strings.write_string(&b, index > 0 ? ", " : "")
			site_module_link(site, &b, path, name)
		}
		strings.write_string(&b, ".</p>\n")
	}
	fmt.sbprintf(&b, "<p class=\"source\">Read from <code>module_builds</code> in <a href=\"%s\"><code>%s</code></a>, the boot image of the last build and the module files of <code>%s</code>.</p>\n", site_repository_file(site, SITE_MODULES_FILE), SITE_MODULES_FILE, MODULE_BUILD_FOLDER)
	site_page_add(site, Site_Page{path = path, title = "The module graph", description = site_description_cut(fmt.tprintf("The %d modules and programs of %s as a graph: %d imports, in layers by depth, with the identity card of each module.", len(inputs), SITE_SYSTEM_NAME, len(layout.edges))), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources(SITE_MODULES_FILE), layout = .Documentation, script = SITE_MODULE_GRAPH_SCRIPT})
	append(entries, Site_Reference_Entry{path = path, title = "The module graph", what = "Each module and program as a node, each import as an edge, in layers by depth; the identity card of each module.", source = SITE_MODULES_FILE, count = len(layout.edges), kind = .Module})
	fmt.printfln("kerneltool: site: the module graph: %d nodes, %d edges, depth %d, %d nodes with no edge; modules with no entry that no module imports: %s", len(inputs), len(layout.edges), depth, layout.band_count, len(unimported) == 0 ? "none" : strings.join(unimported[:], ", ", context.temp_allocator))
}

// The rules of the style sheet for the graph and the identity cards. The
// colors are variables of each form (site_module_graph_variables).
SITE_MODULE_GRAPH_RULES :: `/* The module graph (docs/SITE.md, "The module graph"): a picture that
   keeps its pixels in a box that scrolls sideways, as a table. */
.graph-figure { margin: 0 0 24px; }
.graph-box { overflow-x: auto; background: var(--card-bottom); border: 1px solid var(--track); }
.graph { display: block; }
.graph text { font-family: var(--mono); font-size: 12px; fill: var(--text); }
.graph .graph-heading { fill: var(--dim); }
.graph-kernel { --graph-color: var(--graph-kernel); }
.graph-program { --graph-color: var(--graph-program); }
.graph-no-entry { --graph-color: var(--graph-no-entry); }
.graph-bar { fill: var(--graph-color); }
.graph-size-unknown .graph-bar { fill: none; stroke: var(--graph-color); stroke-width: 1px; }
.graph-edge { fill: none; stroke: var(--dim); stroke-width: 1px; }
.graph-current .graph-name { font-weight: bold; }
.graph-node:focus-visible .graph-bar { stroke: var(--line); stroke-width: 2px; }
.graph-focused .graph-node, .graph-focused .graph-edge { opacity: 0.25; }
.graph-focused .graph-node.graph-marked, .graph-focused .graph-edge.graph-marked { opacity: 1; }
.graph-focused .graph-edge.graph-marked { stroke: var(--line); stroke-width: 2px; }
.graph-legend { list-style: none; margin: 8px 0 0; padding: 0; font-size: 14px; color: var(--dim); }
.graph-legend li { margin: 0; }
.graph-swatch { display: inline-block; vertical-align: middle; margin-right: 8px; }
.graph-cards { position: fixed; right: 16px; bottom: 16px; z-index: 20; width: 384px; max-width: calc(100vw - 32px); }
.module-card { background: var(--card-top); border: 1px solid var(--track); border-left: 4px solid var(--graph-color); padding: 8px 12px; margin: 0 0 16px; max-width: 640px; }
.graph-cards .module-card { margin: 0; }
.module-card-title { margin: 0; font-family: var(--mono); font-weight: bold; }
.module-card-kind { font-weight: normal; color: var(--dim); font-size: 13px; }
.module-card-facts { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 0 12px; margin: 4px 0; font-size: 14px; }
.module-card-facts dt { color: var(--dim); }
.module-card-facts dd { margin: 0; overflow-wrap: anywhere; }
.module-card-about { margin: 4px 0 0; font-size: 14px; }
@media print {
  .graph-cards { display: none; }
}
`

// site_module_graph_variables writes the colors of the kinds in one form.
site_module_graph_variables :: proc(builder: ^strings.Builder, light: bool) {
	strings.write_string(builder, ":root {\n")
	site_variable(builder, "graph-kernel", site_graph_kind_color(.Kernel, light))
	site_variable(builder, "graph-program", site_graph_kind_color(.Program, light))
	site_variable(builder, "graph-no-entry", site_graph_kind_color(.No_Entry, light))
	strings.write_string(builder, "}\n")
}

site_module_graph_script :: proc() -> string {
	return SITE_MODULE_GRAPH_SCRIPT_SOURCE
}

// The script of the page of the graph: plain JavaScript, no library. It
// reads the markup only: a node names its card and its neighbours, an edge
// its two ends. With ?selftest=1 it checks that the neighbours that the
// tool wrote on each node are the other ends of its edges.
SITE_MODULE_GRAPH_SCRIPT_SOURCE :: `// The module graph, written by kerneltool site (tools/kerneltool/site_module_graph.odin).
// A pointer or the focus on a node marks its edges and its neighbours and
// shows its identity card. The page is whole with no script.
(function () {
  "use strict";
  var figure = document.getElementById("module-graph");
  if (!figure) {
    return;
  }
  var picture = figure.querySelector("svg.graph");
  var cards = document.getElementById("graph-cards");
  var nodes = Array.prototype.slice.call(picture.querySelectorAll(".graph-node"));
  var edges = Array.prototype.slice.call(picture.querySelectorAll(".graph-edge"));
  var shown = null;
  var marked = "";

  function words(text) {
    return (text || "").split(" ").filter(function (word) { return word !== ""; });
  }

  function cardOf(node) {
    var id = node.getAttribute("data-card");
    return id ? document.getElementById(id) : null;
  }

  function mark(node) {
    var name = node.getAttribute("data-module");
    var neighbours = words(node.getAttribute("data-neighbours"));
    marked = name;
    picture.classList.add("graph-focused");
    nodes.forEach(function (other) {
      var near = other === node || neighbours.indexOf(other.getAttribute("data-module")) >= 0;
      other.classList.toggle("graph-marked", near);
    });
    edges.forEach(function (edge) {
      var touches = edge.getAttribute("data-from") === name || edge.getAttribute("data-to") === name;
      edge.classList.toggle("graph-marked", touches);
    });
    var card = cardOf(node);
    if (shown && shown !== card) {
      shown.hidden = true;
    }
    if (card) {
      card.hidden = false;
    }
    shown = card;
  }

  function clear(node) {
    if (marked !== node.getAttribute("data-module")) {
      return;
    }
    marked = "";
    picture.classList.remove("graph-focused");
    nodes.forEach(function (other) { other.classList.remove("graph-marked"); });
    edges.forEach(function (edge) { edge.classList.remove("graph-marked"); });
    if (shown) {
      shown.hidden = true;
      shown = null;
    }
  }

  if (cards) {
    Array.prototype.forEach.call(cards.querySelectorAll(".module-card"), function (card) { card.hidden = true; });
    cards.hidden = false;
  }
  nodes.forEach(function (node) {
    node.addEventListener("mouseenter", function () { mark(node); });
    node.addEventListener("mouseleave", function () {
      if (document.activeElement !== node) {
        clear(node);
      }
    });
    node.addEventListener("focus", function () { mark(node); });
    node.addEventListener("blur", function () { clear(node); });
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && marked !== "") {
      nodes.forEach(function (node) {
        if (node.getAttribute("data-module") === marked) {
          clear(node);
        }
      });
    }
  });

  if (/[?&]selftest=1(&|$)/.test(window.location.search)) {
    var pass = 0;
    var first = "";
    nodes.forEach(function (node) {
      var name = node.getAttribute("data-module");
      var found = [];
      edges.forEach(function (edge) {
        var from = edge.getAttribute("data-from");
        var to = edge.getAttribute("data-to");
        var other = from === name ? to : (to === name ? from : "");
        if (other !== "" && found.indexOf(other) < 0) {
          found.push(other);
        }
      });
      var expected = words(node.getAttribute("data-neighbours")).sort().join(" ");
      if (found.sort().join(" ") === expected && (cardOf(node) !== null || node.getAttribute("data-card") === null)) {
        pass += 1;
      } else if (first === "") {
        first = name;
      }
    });
    var line = "module graph self test: " + pass + " of " + nodes.length + " nodes agree" + (first !== "" ? "; the first that does not: " + first : "");
    console.log(line);
    document.documentElement.setAttribute("data-module-graph-self-test", line);
  }
})();
`
