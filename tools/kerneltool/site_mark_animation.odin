// The animations of the mark on the site (docs/DESIGN.md, "The mark", "The
// animations"): the large heron of the home and the icon of the tab move;
// the small mark of the bar does not. This file is a caller of the
// generator of the pictures of the mark (mark_pictures.odin,
// mark_tile_map.odin): it asks for the three tile maps of the site, which
// the table of the uses of the mark names, and writes the script of the
// page with the table of the generator in it. It draws no picture of the
// site. Which animation plays is in site_mark_schedule.odin
// (docs/SITE.md, "The rhythm of the animations").
//
// What the site gets:
//   pictures/mark_animation_home.png and mark_animation_home_light.png: the
//     tile map of the home for each color scheme, in the smooth variant,
//     with the pixels of the still picture of the home: a tile for each
//     distinct frame, the still heron first, and under them a tile for
//     each drawn form of the moves. The script copies a tile onto a
//     canvas; the browser computes no pixel of the heron.
//   pictures/mark_animation_icon.png: the tile map of the icon of the tab:
//     the frames in the cells variant, one pixel for a cell, in the colors
//     of the light scheme, as the icon of 32 pixels of favicon.ico.
//   mark_animation.js: the script, with the table of the tiles, of the
//     frames, of the moves and of the rule of the choice written into it: no
//     other request.
// The home loads the script; no other page does.
package kerneltool

import "core:fmt"
import "core:image/png"
import "core:strings"
import "support:mark"

SITE_MARK_ANIMATION_SCRIPT :: "mark_animation.js"
// The icon of the tab that the script draws during an animation: the size
// of the icon of favicon.ico whose cells are one pixel, and the empty
// pixels around the heron in it, at each side.
SITE_MARK_ANIMATION_ICON_SIZE :: 32
SITE_MARK_ANIMATION_ICON_MARGIN :: (SITE_MARK_ANIMATION_ICON_SIZE - mark.HERON_GRID_SIZE) / 2

// The classes of the page that the script and the style sheet share. The
// stage takes the place of the still picture while the script plays; it
// holds the water, which stays, and the heron above the water, which a
// move takes with it.
SITE_MARK_STAGE_CLASS :: "mark-stage"
SITE_MARK_HERON_CLASS :: "mark-heron"
SITE_MARK_WATER_CLASS :: "mark-water"
SITE_MARK_REPLACED_CLASS :: "mark-replaced"
SITE_MARK_TRAVEL_CLASS :: "mark-travel"

// The three tile maps of the site, as the table of the uses of the mark
// gives them (mark_pictures.odin): the two of the home, one for each color
// scheme, with the drawn forms of the moves; and the one of the icon of
// the tab, the frames only.
Site_Mark_Tile_Maps :: struct {
	dark:  Mark_Tile_Map,
	light: Mark_Tile_Map,
	icon:  Mark_Tile_Map,
}

site_mark_tile_maps :: proc() -> (tile_maps: Site_Mark_Tile_Maps, ok: bool) {
	dark, has_dark := mark_use_picture(SITE_MARK_ANIMATION_HOME)
	light, has_light := mark_use_picture(SITE_MARK_ANIMATION_HOME_LIGHT)
	icon, has_icon := mark_use_picture(SITE_MARK_ANIMATION_ICON)
	home, has_home := mark_use_picture(SITE_MARK_HOME)
	// A tile of the home is the still picture of the home, so that the
	// heron does not change when the script starts; the two tile maps of
	// the home differ by their colors only.
	if !has_dark || !has_light || !has_icon || !has_home || dark.variant != home.variant || dark.heron_cell != home.heron_cell || light.variant != dark.variant || light.heron_cell != dark.heron_cell {
		fmt.eprintln("kerneltool: site: the tile maps of the home and of the icon of the tab are not in the table of the uses of the mark, or a tile of the home is not drawn as the still picture of the home")
		return {}, false
	}
	tile_maps.dark = mark_tile_map_build(dark, false, .Blink, true, 0) or_return
	tile_maps.light = mark_tile_map_build(light, false, .Blink, true, 0) or_return
	tile_maps.icon = mark_tile_map_build(icon, false, .Blink, false, 0) or_return
	return tile_maps, true
}

// site_mark_tab_icon_picture gives the picture of the icon of favicon.ico
// that the script draws again from the tile map of the icon during an
// animation: the icon of SITE_MARK_ANIMATION_ICON_SIZE pixels.
site_mark_tab_icon_picture :: proc() -> (icon: Mark_Picture, ok: bool) {
	for candidate in site_icons {
		if candidate.in_favicon && candidate.size == SITE_MARK_ANIMATION_ICON_SIZE {
			return site_icon_picture(candidate), true
		}
	}
	return {}, false
}

// The count of the tile maps of the site: the dark and the light one of
// the home, and the one of the icon of the tab, in this order.
SITE_MARK_SHEET_COUNT :: 3

site_mark_sheet_path :: proc(file_name: string) -> string {
	return strings.concatenate({SITE_PICTURE_FOLDER, "/", file_name}, context.temp_allocator)
}

// site_mark_animation_files gives the files of the animations, by their
// path in the site: the three tile maps and the script. The generator of
// the pictures of the mark draws and encodes each tile map; this procedure
// only asks for them. The script names each tile map with the version of
// its bytes: a tile map changes when a frame of an animation changes, and
// a script must never cut the tile map of another build that a cache kept.
site_mark_animation_files :: proc() -> (files: map[string][]u8, ok: bool) {
	tile_maps := site_mark_tile_maps() or_return
	files = make(map[string][]u8, context.temp_allocator)
	addresses: [SITE_MARK_SHEET_COUNT]string
	for tile_map, index in ([SITE_MARK_SHEET_COUNT]^Mark_Tile_Map{&tile_maps.dark, &tile_maps.light, &tile_maps.icon}) {
		data := mark_tile_map_png(tile_map) or_return
		path := site_mark_sheet_path(tile_map.picture.file_name)
		files[path] = data
		addresses[index] = strings.concatenate({path, "?v=", site_bytes_version(data)}, context.temp_allocator)
	}
	files[SITE_MARK_ANIMATION_SCRIPT] = transmute([]u8)site_mark_animation_script(&tile_maps, addresses)
	return files, true
}

// site_mark_animation_write writes the files of the animations into the
// site, after the check that each sheet reads back as the frames of
// support/mark and that the moves agree with the frames.
site_mark_animation_write :: proc(site: ^Site) -> bool {
	files := site_mark_animation_files() or_return
	problems := site_mark_animation_problems(files)
	if len(problems) > 0 {
		for problem in problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		return false
	}
	for path, data in files {
		site_write_file(site, path, data) or_return
	}
	sprites, _ := site_mark_sprites()
	still_least, still_most := site_mark_still_bounds()
	fmt.printfln(
		"kerneltool: site: the animations of the mark: %d animations, %d ms in all, %d sprites; a still time of %d to %d ms; %s %d bytes, %s %d bytes, %s %d bytes, %s %d bytes",
		len(mark.Animation),
		site_mark_animations_duration(),
		len(sprites.cells),
		still_least,
		still_most,
		SITE_MARK_ANIMATION_HOME,
		len(files[site_mark_sheet_path(SITE_MARK_ANIMATION_HOME)]),
		SITE_MARK_ANIMATION_HOME_LIGHT,
		len(files[site_mark_sheet_path(SITE_MARK_ANIMATION_HOME_LIGHT)]),
		SITE_MARK_ANIMATION_ICON,
		len(files[site_mark_sheet_path(SITE_MARK_ANIMATION_ICON)]),
		SITE_MARK_ANIMATION_SCRIPT,
		len(files[SITE_MARK_ANIMATION_SCRIPT]),
	)
	return true
}

// site_mark_animation_problems checks the files of the animations: each
// sheet decodes, has the size of its sprites, no side longer than a
// browser decodes, and each sprite has the pixels of its frame in
// support/mark; the script has its table; the moves agree with the frames.
site_mark_animation_problems :: proc(files: map[string][]u8) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	tile_maps, tile_maps_ok := site_mark_tile_maps()
	if !tile_maps_ok {
		append(&problems, "the tile maps of the animations of the mark cannot be built")
		return problems[:]
	}
	for tile_map in ([SITE_MARK_SHEET_COUNT]^Mark_Tile_Map{&tile_maps.dark, &tile_maps.light, &tile_maps.icon}) {
		path := site_mark_sheet_path(tile_map.picture.file_name)
		data, found := files[path]
		if !found {
			append(&problems, fmt.tprintf("%s is not written", path))
			continue
		}
		image, load_error := png.load_from_bytes(data, allocator = context.temp_allocator)
		if load_error != nil || image == nil {
			append(&problems, fmt.tprintf("%s does not decode", path))
			continue
		}
		expected, width, height, channels := mark_tile_map_pixels(tile_map)
		same := image.width == width && image.height == height && image.channels == channels && image.depth == 8 && len(image.pixels) == len(expected)
		for index := 0; same && index < len(expected); index += 1 {
			same = image.pixels[index] == expected[index]
		}
		if !same {
			append(&problems, fmt.tprintf("%s is not the frames of the animations of support/mark", path))
		}
		if width > MARK_PICTURE_SIDE_MOST || height > MARK_PICTURE_SIDE_MOST {
			append(&problems, fmt.tprintf("%s is %d by %d pixels: a browser decodes at most %d", path, width, height, MARK_PICTURE_SIDE_MOST))
		}
	}
	script, has_script := files[SITE_MARK_ANIMATION_SCRIPT]
	if !has_script || strings.contains(string(script), "/*TABLE*/") {
		append(&problems, SITE_MARK_ANIMATION_SCRIPT + " has no table of the frames")
	}
	if fault := site_mark_move_fault_text(mark.move_keys[:]); fault != "" {
		append(&problems, fault)
	}
	return problems[:]
}

// site_mark_animation_table_json gives the table that the script reads:
//   sprites, columns, cells, tile, forms, animations: the table of the
//     tile map of the home, as the generator writes it
//     (mark_tile_map_table_fields_write);
//   sheets: the addresses of the three tile maps;
//   icon: the size of the icon of the tab, the empty pixels around the
//     heron in it, and the size of a tile of its tile map and how many are
//     in one row;
//   schedule: the bounds of a still time and the still share, in percent;
//   check: the seed and the first steps of the model of the choice, each
//     [still milliseconds, animation], which the self test compares;
//   limits: the bounds of support/mark for a frame.
// The paths are relative to the folder of the script: the root of the site.
site_mark_animation_table_json :: proc(tile_maps: ^Site_Mark_Tile_Maps, sheet_addresses: [SITE_MARK_SHEET_COUNT]string) -> string {
	// The braces are written as text, never through a format of fmt.
	b := strings.builder_make(context.temp_allocator)
	write :: proc(b: ^strings.Builder, text: string) {
		strings.write_string(b, text)
	}
	number :: proc(b: ^strings.Builder, value: int) {
		strings.write_string(b, fmt.tprintf("%d", value))
	}
	// The table of the tile map of the home, as the generator writes it:
	// the sprites, the tiles, the drawn forms, the animations.
	write(&b, "{")
	mark_tile_map_table_fields_write(&b, &tile_maps.dark)
	// What the site adds: the addresses of the three tile maps, and where
	// a sprite is in the tile map of the icon of the tab and in that icon.
	write(&b, ",\"sheets\":{\"dark\":")
	site_json_string(&b, sheet_addresses[0])
	write(&b, ",\"light\":")
	site_json_string(&b, sheet_addresses[1])
	write(&b, ",\"icon\":")
	site_json_string(&b, sheet_addresses[2])
	icon_layout := tile_maps.icon.layout
	write(&b, "},\"icon\":{\"size\":")
	number(&b, SITE_MARK_ANIMATION_ICON_SIZE)
	write(&b, ",\"margin\":")
	number(&b, SITE_MARK_ANIMATION_ICON_MARGIN)
	write(&b, ",\"tile\":")
	number(&b, icon_layout.sprite_width)
	write(&b, ",\"columns\":")
	number(&b, icon_layout.sprite_columns)
	frame_least := mark.FRAME_DURATION_LEAST
	for animation in mark.Animation {
		frame_least = min(frame_least, mark.animation_frame_duration_least[animation])
	}
	still_least, still_most := site_mark_still_bounds()
	write(&b, "},\"schedule\":{\"stillLeast\":")
	number(&b, still_least)
	write(&b, ",\"stillMost\":")
	number(&b, still_most)
	write(&b, ",\"sharePercent\":")
	number(&b, SITE_MARK_STILL_SHARE_PERCENT)
	write(&b, "},\"check\":{\"seed\":")
	number(&b, SITE_MARK_CHECK_SEED)
	write(&b, ",\"steps\":[")
	for step, index in site_mark_check_steps() {
		write(&b, index > 0 ? ",[" : "[")
		number(&b, step.still_milliseconds)
		write(&b, ",")
		number(&b, step.animation)
		write(&b, "]")
	}
	write(&b, "]},\"limits\":{\"frameLeast\":")
	number(&b, frame_least)
	write(&b, ",\"frameMost\":")
	number(&b, mark.FRAME_DURATION_MOST)
	write(&b, "}}")
	return strings.to_string(b)
}

// site_mark_animation_script gives mark_animation.js: the source below with
// the table in its place.
site_mark_animation_script :: proc(tile_maps: ^Site_Mark_Tile_Maps, sheet_addresses: [SITE_MARK_SHEET_COUNT]string) -> string {
	script, _ := strings.replace_all(SITE_MARK_ANIMATION_SCRIPT_SOURCE, "/*TABLE*/null", site_mark_animation_table_json(tile_maps, sheet_addresses), context.temp_allocator)
	return script
}

// The two declarations that keep each pixel of a picture a sharp square
// when the page shows it larger. The second is the one of the standard;
// the first is for a browser that knows only the older word, and a
// browser that knows both takes the second.
SITE_MARK_NO_SMOOTHING :: "image-rendering: crisp-edges; image-rendering: pixelated; "

// site_mark_animation_rules gives the rules of the style sheet for the
// heron of the home: the still picture, and the stage while the script
// plays.
//
// The pictures of the heron of the home are the smooth variant: they have
// their real pixels, and the page shows each at its own size. Each size of
// these rules is written in pixels, as a count of cells times the pixels
// of a cell of the still picture of the home, which the table of the uses
// of the mark gives: no number of the mark is written here by hand, and no
// size is a part of the width of the page. No smoothing: on a screen with
// more than one pixel for a pixel of the page, a pixel of a picture stays a
// sharp square. No rule changes the size of a picture of the heron: a
// squashed heron is another drawing.
//
// The stage has the box of the still picture, so nothing beside it moves
// when it takes its place. The two canvases take no pointer: a heron that
// crosses the page never takes a click from a link under it. While the
// heron crosses the window, the page is cut at the sides of the window, so
// no scroll bar appears for a heron that is outside. For a reader who asks
// for reduced motion the stage is never shown, also when a script puts it
// in the page.
site_mark_animation_rules :: proc() -> string {
	home, _ := mark_use_picture(SITE_MARK_HOME)
	factor := home.heron_cell
	b := strings.builder_make(context.temp_allocator)
	// The braces are written as text, never through a format of fmt.
	strings.write_string(&b, "/* The heron of the home: its pictures have ")
	fmt.sbprintf(&b, "%d", factor)
	strings.write_string(&b, " pixels for a cell, and the page shows them at their own size. */\n")
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " { display: block; position: relative; ")
	fmt.sbprintf(&b, "width: %dpx; height: %dpx; ", mark.HERON_GRID_SIZE * factor, mark.HERON_GRID_SIZE * factor)
	strings.write_string(&b, "}\n")
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " canvas { display: block; position: absolute; left: 0; " + SITE_MARK_NO_SMOOTHING + "pointer-events: none; }\n")
	// The canvas of the heron is the box of a form: it passes the stage at
	// its left, at its right and above it by the room of the widest and
	// of the highest form, and its bottom is on the line of the water.
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " ." + SITE_MARK_HERON_CLASS + " { ")
	fmt.sbprintf(
		&b,
		"left: -%dpx; bottom: %dpx; width: %dpx; height: %dpx; ",
		mark.FORM_REACH_LEFT * factor,
		mark.WATER_ROWS * factor,
		MARK_FORM_BOX_COLUMNS * factor,
		MARK_FORM_BOX_ROWS * factor,
	)
	strings.write_string(&b, "}\n")
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " ." + SITE_MARK_WATER_CLASS + " { bottom: 0; ")
	fmt.sbprintf(&b, "width: %dpx; height: %dpx; ", mark.HERON_GRID_SIZE * factor, mark.WATER_ROWS * factor)
	strings.write_string(&b, "}\n")
	strings.write_string(&b, ".home-head picture." + SITE_MARK_REPLACED_CLASS + " { display: none; }\n")
	strings.write_string(&b, "html." + SITE_MARK_TRAVEL_CLASS + " { overflow-x: clip; }\n")
	strings.write_string(&b, "@media (prefers-reduced-motion: reduce) {\n  ." + SITE_MARK_STAGE_CLASS + " { display: none; }\n  .home-head picture." + SITE_MARK_REPLACED_CLASS + " { display: block; }\n}\n")
	return strings.to_string(b)
}

// The script. It changes nothing for a reader who asks for reduced motion,
// nothing in a hidden tab, and nothing while the reader types in a field.
// The still picture stays in the page: a browser with no script shows it,
// and the script puts the stage, of the same size, in its place only while
// it plays. The script sets no style: it sets classes, and it moves the
// heron through the animations of the browser, which a style rule of the
// host does not refuse. It changes the size of no picture: a squashed or a
// stretched heron is a drawing of the sheet, and a move puts the heron at
// a whole count of cells from its place.
SITE_MARK_ANIMATION_SCRIPT_SOURCE :: `// The animations of the mark on the home, written by kerneltool site
// (tools/kerneltool/site_mark_animation.odin and site_mark_schedule.odin)
// from support/mark/animation.odin.
// The large heron of the head and the icon of the tab move. Each animation
// plays once before one plays again, in an order of chance; between two
// animations the heron is still.
// Nothing moves when the reader asks for reduced motion, nothing runs in a
// hidden tab, and nothing plays while the reader types in a field.
// ?selftest=1 in the address checks the table and the rule of the choice.
// #heron=<name> in the address plays one animation again and again, for a
// developer who looks at it: #heron=dash.
"use strict";
(function () {
  const TABLE = /*TABLE*/null;
  const script = document.currentScript;
  if (!script || !TABLE) return;
  const root = new URL(".", script.src);
  const COUNT = TABLE.animations.length;
  const EVERY = Math.pow(2, COUNT) - 1;
  const STORE = "modus.mark.played";

  // The rule of the choice, as site_mark_next_animation of the tool. The
  // memory holds the animations that were played, one bit each, and the one
  // played last. The next one is chosen among those that the memory does
  // not hold. When the memory holds every animation, it is emptied first,
  // and the one played last is left out: no animation follows itself.
  // below(bound) gives a whole number from 0 to bound - 1.
  function nextAnimation(memory, below) {
    if ((memory.played & EVERY) === EVERY) memory.played = 0;
    const open = [];
    for (let index = 0; index < COUNT; index++) {
      if ((memory.played & (1 << index)) === 0 && index !== memory.last) open.push(index);
    }
    const pick = open.length > 0 ? open[below(open.length)] : 0;
    memory.played |= 1 << pick;
    memory.last = pick;
    return pick;
  }
  // The still time before an animation: each whole number of milliseconds
  // of the range has the same chance.
  function stillTime(below) {
    return TABLE.schedule.stillLeast + below(TABLE.schedule.stillMost - TABLE.schedule.stillLeast + 1);
  }
  // The generator of the model of the tool: the same seed gives the same
  // numbers there and here. Only the self test uses it.
  function seeded(seed) {
    let state = seed >>> 0;
    return function (bound) {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
      return (state >>> 16) % bound;
    };
  }
  function chance(bound) { return Math.floor(Math.random() * bound); }

  function selfTest() {
    const cases = [];
    function check(name, passed) { cases.push({ name: name, passed: passed }); }
    const limits = TABLE.limits, schedule = TABLE.schedule;
    check("a sheet has sprites in rows", TABLE.sprites >= 1 && TABLE.columns >= 1);
    check("a sprite of the home has a size and its water", TABLE.tile.width > 0 && TABLE.tile.height > TABLE.tile.water && TABLE.tile.water > 0);
    check("the icon of the tab holds a tile of its tile map and its margins", TABLE.icon.size === TABLE.icon.tile + 2 * TABLE.icon.margin && TABLE.icon.margin >= 0 && TABLE.icon.columns >= 1);
    const forms = TABLE.forms, whole = Number.isInteger;
    check("the box of a drawn form holds the heron above the water", forms.count >= 1 && forms.columns >= 1 && forms.top > 0 &&
      forms.width >= forms.left + TABLE.tile.width && forms.height === forms.up + TABLE.tile.height - TABLE.tile.water);
    check("a cell is a whole count of pixels", whole(TABLE.tile.width / TABLE.cells) && whole(forms.left * TABLE.cells / TABLE.tile.width) && whole(forms.up * TABLE.cells / TABLE.tile.width));
    check("the memory holds each animation in one bit", COUNT >= 2 && COUNT <= 30);
    TABLE.animations.forEach(animation => {
      const name = animation.name;
      check(name + ": frames", animation.frames.length >= 1);
      check(name + ": each sprite is in the sheet", animation.frames.every(f => Number.isInteger(f[0]) && f[0] >= 0 && f[0] < TABLE.sprites));
      check(name + ": each duration is in its range", animation.frames.every(f => f[1] >= limits.frameLeast && f[1] <= limits.frameMost));
      check(name + ": the first frame moves", animation.frames[0][0] !== 0);
      check(name + ": its time is the time of its frames", animation.frames.reduce((sum, f) => sum + f[1], 0) === animation.duration);
      check(name + ": the time of its steps is its time", animation.steps.reduce((sum, s) => sum + s[0], 0) === animation.duration);
      check(name + ": each step shows a sprite, and a drawn form or none", animation.steps.every(s => s.length === 3 && whole(s[0]) && s[0] > 0 &&
        whole(s[1]) && s[1] >= 0 && s[1] < TABLE.sprites && whole(s[2]) && s[2] >= -1 && s[2] < forms.count));
      check(name + ": the steps show its frames in their order", animation.steps.map(s => s[1]).filter((s, index, all) => index === 0 || s !== all[index - 1]).join() ===
        animation.frames.map(f => f[0]).filter((s, index, all) => index === 0 || s !== all[index - 1]).join());
      check(name + ": only a move draws a form", !!animation.motion || animation.steps.every(s => s[2] === -1));
      if (animation.motion) {
        const keys = animation.motion;
        check(name + ": its move goes from its start to its end", keys.length >= 2 && keys[0][0] === 0 && keys[keys.length - 1][0] === animation.duration);
        check(name + ": the keys of its move are in the order of time", keys.every((key, index) => index === 0 || key[0] > keys[index - 1][0]));
        check(name + ": each key is whole cells, an edge and a pace", keys.every(key => key.length === 5 && key.every(whole) && key[3] >= 0 && key[3] <= 2 && key[4] >= 0 && key[4] <= 1));
        check(name + ": its move starts and ends in its place", [keys[0], keys[keys.length - 1]].every(key => key[1] === 0 && key[2] === 0 && key[3] === 0));
        check(name + ": no way goes to the right and upward at once", keys.every((key, index) => index === 0 || key[2] === keys[index - 1][2] || (key[1] === keys[index - 1][1] && key[3] === keys[index - 1][3])));
      }
    });
    check("the still times have a range", schedule.stillLeast >= limits.frameLeast && schedule.stillMost >= schedule.stillLeast);
    // The rule of this script against the model of the tool: the same
    // generator, the same steps.
    const memory = { played: 0, last: -1 }, below = seeded(TABLE.check.seed);
    let agree = 0;
    TABLE.check.steps.forEach(step => {
      const still = stillTime(below), animation = nextAnimation(memory, below);
      if (still === step[0] && animation === step[1]) agree++;
    });
    check("the choice agrees with the model of the tool on " + TABLE.check.steps.length + " steps", agree === TABLE.check.steps.length && agree > 2 * COUNT);
    // A long play: 200 rounds of the memory.
    const longMemory = { played: 0, last: -1 }, source = seeded(TABLE.check.seed + 1);
    let stillSum = 0, movingSum = 0, follows = 0, twice = 0, round = 0, before = -1;
    for (let step = 0; step < 200 * COUNT; step++) {
      stillSum += stillTime(source);
      const animation = nextAnimation(longMemory, source);
      if (animation === before) follows++;
      if (round & (1 << animation)) twice++;
      round |= 1 << animation;
      if (round === EVERY) round = 0;
      movingSum += TABLE.animations[animation].duration;
      before = animation;
    }
    check("no animation follows itself in a long play", follows === 0);
    check("no animation plays two times in one round of the memory", twice === 0);
    check("the heron is still for about its share of a long play", Math.abs(100 * stillSum / (stillSum + movingSum) - schedule.sharePercent) <= 1);
    const passed = cases.filter(c => c.passed).length;
    const first = cases.find(c => !c.passed);
    return first ? "mark animation self test: FAIL, " + passed + " of " + cases.length + " cases pass; the first that fails: " + first.name :
      "mark animation self test: " + passed + " of " + cases.length + " cases pass";
  }
  if (new URLSearchParams(location.search).get("selftest") === "1") {
    const line = selfTest();
    console.log(line);
    document.documentElement.setAttribute("data-mark-animation-self-test", line);
  }

  const picture = document.querySelector(".home-head picture");
  const still = picture && picture.querySelector("img.mark");
  if (!picture || !still) return;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  const light = window.matchMedia("(prefers-color-scheme: light)");

  // The memory of the visit: the storage of the tab keeps it from one page
  // to the next, and the browser drops it when the tab closes. A memory of
  // another count of animations is a memory of another build: it is not
  // used.
  function recall() {
    try {
      const kept = JSON.parse(window.sessionStorage.getItem(STORE));
      if (kept && kept.count === COUNT && Number.isInteger(kept.played) && kept.played >= 0 && kept.played <= EVERY &&
          Number.isInteger(kept.last) && kept.last >= -1 && kept.last < COUNT) {
        return { played: kept.played, last: kept.last };
      }
    } catch (error) { /* No storage, or a text that is not a memory. */ }
    return { played: 0, last: -1 };
  }
  function keep() {
    try {
      window.sessionStorage.setItem(STORE, JSON.stringify({ count: COUNT, played: memory.played, last: memory.last }));
    } catch (error) { /* No storage: the memory lasts as long as the page. */ }
  }
  const memory = recall();

  // The animation that the address asks for, or -1.
  function asked() {
    const match = /^#heron=([a-z]+)$/.exec(window.location.hash);
    return match ? TABLE.animations.findIndex(animation => animation.name === match[1]) : -1;
  }

  let sheets = null, loading = null;
  let stage = null, heron = null, heronContext = null, water = null, waterContext = null;
  let playing = false, shown = -1, shownForm = -1, timer = 0, current = -1, step = -1, due = 0, motion = null;
  let typing = isField(document.activeElement);
  let iconLink = null, iconSprite = -1;
  const iconAddresses = [];

  function isField(element) {
    return !!element && (element.tagName === "INPUT" || element.tagName === "TEXTAREA" || element.tagName === "SELECT" || element.isContentEditable === true);
  }

  function load() {
    if (!loading) {
      const paths = [TABLE.sheets.dark, TABLE.sheets.light, TABLE.sheets.icon];
      const images = paths.map(path => { const image = new Image(); image.src = new URL(path, root).href; return image; });
      loading = Promise.all(images.map(image => image.decode())).then(() => {
        sheets = { dark: images[0], light: images[1], icon: images[2] };
      }).catch(() => { sheets = null; });
    }
    return loading;
  }

  // The stage: the water at the bottom, which stays, and the heron above
  // it, which a move takes with it. The stage is the box of the still
  // picture. The canvas of the heron is the box of a drawn form: it passes
  // the stage by the room of the widest and of the highest form. A canvas
  // has the pixels of its tiles: each of its pixels is a pixel of the tile
  // map, which the tool drew. The script computes no color.
  function build() {
    const width = TABLE.tile.width;
    stage = document.createElement("span");
    stage.className = "mark-stage";
    stage.setAttribute("role", "img");
    stage.setAttribute("aria-label", still.alt);
    water = document.createElement("canvas");
    water.className = "mark-water";
    water.width = width;
    water.height = TABLE.tile.water;
    heron = document.createElement("canvas");
    heron.className = "mark-heron";
    heron.width = TABLE.forms.width;
    heron.height = TABLE.forms.height;
    stage.append(water, heron);
    waterContext = water.getContext("2d");
    heronContext = heron.getContext("2d");
  }

  // One picture, from the sheet of the color scheme of now: the water of
  // the sprite of a frame, and above it the heron of that sprite (form -1)
  // or a drawn form of it. Each picture is copied pixel for pixel: a cell
  // of the heron has one size.
  function draw(sprite, form) {
    const sheet = light.matches ? sheets.light : sheets.dark;
    const forms = TABLE.forms;
    const width = TABLE.tile.width, height = TABLE.tile.height, above = height - TABLE.tile.water;
    const left = (sprite % TABLE.columns) * width, top = Math.floor(sprite / TABLE.columns) * height;
    heronContext.clearRect(0, 0, forms.width, forms.height);
    if (form < 0) {
      heronContext.drawImage(sheet, left, top, width, above, forms.left, forms.up, width, above);
    } else {
      heronContext.drawImage(sheet, (form % forms.columns) * forms.width, forms.top + Math.floor(form / forms.columns) * forms.height,
        forms.width, forms.height, 0, 0, forms.width, forms.height);
    }
    waterContext.clearRect(0, 0, width, TABLE.tile.water);
    waterContext.drawImage(sheet, left, top + above, width, TABLE.tile.water, 0, 0, width, TABLE.tile.water);
    shown = sprite;
    shownForm = form;
  }

  // The icon of the tab: one tile of the tile map of the icon, as a data
  // address. A tile is the heron at one pixel for a cell, and the icon has
  // empty pixels around it: the tile is copied pixel for pixel. Each
  // address is made once. The link is in the head only during an animation.
  function iconAddress(sprite) {
    if (!iconAddresses[sprite]) {
      const size = TABLE.icon.size, margin = TABLE.icon.margin, tile = TABLE.icon.tile;
      const icon = document.createElement("canvas");
      icon.width = size;
      icon.height = size;
      icon.getContext("2d").drawImage(sheets.icon, (sprite % TABLE.icon.columns) * tile, Math.floor(sprite / TABLE.icon.columns) * tile, tile, tile, margin, margin, tile, tile);
      iconAddresses[sprite] = icon.toDataURL("image/png");
    }
    return iconAddresses[sprite];
  }
  function showIcon(sprite) {
    if (sprite === iconSprite) return;
    if (!iconLink) {
      iconLink = document.createElement("link");
      iconLink.rel = "icon";
      iconLink.type = "image/png";
      iconLink.setAttribute("sizes", TABLE.icon.size + "x" + TABLE.icon.size);
      document.head.append(iconLink);
    }
    iconLink.href = iconAddress(sprite);
    iconSprite = sprite;
  }
  // The end of an animation: the still icon, then the icons of the page
  // again.
  function stillIcon() {
    if (!iconLink) return;
    iconLink.href = iconAddress(0);
    iconLink.remove();
    iconLink = null;
    iconSprite = -1;
  }

  // The move of an animation: the places of its keys as one animation of
  // the browser on the heron above the water. A place is a whole count of
  // cells from the place of the heron. A key past an edge puts the heron,
  // in its widest form, wholly outside the window at that side, a whole
  // count of cells away. From a key to the next one the heron goes cell by
  // cell, in as many even steps as the way has cells (or in one step, at
  // the end, for a key that holds): it is never between two cells. While
  // the heron crosses the window, the page is cut at the sides of the
  // window.
  function startMove(animation) {
    if (!animation.motion || typeof heron.animate !== "function") return;
    const box = stage.getBoundingClientRect();
    const cell = box.width / TABLE.cells;
    const far = [0, Math.ceil((document.documentElement.clientWidth - box.left) / cell) + TABLE.forms.reachLeft,
      -(Math.ceil(box.right / cell) + TABLE.forms.reachRight)];
    const places = animation.motion.map(key => [key[1] + far[key[3]], key[2]]);
    let crosses = false;
    const keys = animation.motion.map((key, index) => {
      if (key[3] !== 0) crosses = true;
      const place = places[index], next = places[Math.min(index + 1, places.length - 1)];
      const cells = Math.abs(next[0] - place[0]) + Math.abs(next[1] - place[1]);
      return {
        offset: key[0] / animation.duration,
        easing: "steps(" + (key[4] === 1 ? 1 : Math.max(1, cells)) + ", end)",
        transform: "translate(" + place[0] * cell + "px, " + -place[1] * cell + "px)"
      };
    });
    if (crosses) document.documentElement.classList.add("mark-travel");
    motion = heron.animate(keys, { duration: animation.duration });
  }
  function endMove() {
    if (motion) motion.cancel();
    motion = null;
    document.documentElement.classList.remove("mark-travel");
  }

  // The play: the still heron for a still time, then one animation, step
  // by step. Each step ends at its time from the start of the animation,
  // so a timer that is late does not make the next ones late: the pictures
  // stay in step with the move.
  function rest() {
    current = -1;
    step = -1;
    endMove();
    if (shown !== 0 || shownForm !== -1) draw(0, -1);
    stillIcon();
    timer = window.setTimeout(play, asked() >= 0 ? TABLE.schedule.stillLeast : stillTime(chance));
  }
  function play() {
    const only = asked();
    if (only >= 0) {
      current = only;
    } else {
      current = nextAnimation(memory, chance);
      keep();
    }
    step = -1;
    due = window.performance.now();
    startMove(TABLE.animations[current]);
    next();
  }
  function next() {
    const steps = TABLE.animations[current].steps;
    step++;
    if (step >= steps.length) { rest(); return; }
    if (steps[step][1] !== shown || steps[step][2] !== shownForm) draw(steps[step][1], steps[step][2]);
    showIcon(steps[step][1]);
    due += steps[step][0];
    timer = window.setTimeout(next, Math.max(0, due - window.performance.now()));
  }

  function canPlay() { return !reduce.matches && !document.hidden && !typing; }

  function start() {
    if (!canPlay() || playing) return;
    load().then(() => {
      if (!sheets || !canPlay() || playing) return;
      if (!stage) build();
      playing = true;
      draw(0, -1);
      // The style sheet hides the still picture by this class, and shows
      // it again for a reader who asks for reduced motion.
      picture.after(stage);
      picture.classList.add("mark-replaced");
      rest();
    });
  }

  // Back to the still picture of the page and to the icons of the page.
  function stop() {
    if (timer) window.clearTimeout(timer);
    timer = 0;
    playing = false;
    endMove();
    if (stage && stage.parentNode) stage.remove();
    picture.classList.remove("mark-replaced");
    shown = -1;
    if (sheets) stillIcon();
  }

  function fit() { if (canPlay()) start(); else stop(); }
  reduce.addEventListener("change", fit);
  document.addEventListener("visibilitychange", fit);
  document.addEventListener("focusin", event => { typing = isField(event.target); fit(); });
  document.addEventListener("focusout", () => { typing = false; fit(); });
  light.addEventListener("change", () => { if (playing && shown >= 0) draw(shown, shownForm); });
  // Another animation asked for in the address: the play starts again.
  window.addEventListener("hashchange", () => { if (playing) { stop(); fit(); } });
  fit();
})();
`
