// The animations of the mark on the site (docs/DESIGN.md, "The mark", "The
// animations"): the large heron of the home and the icon of the tab move a
// few cells from time to time; the small mark of the bar does not. The
// frames are the animations of support/mark, drawn by the same code as the
// still pictures of the mark (site_pictures.odin, site_icons.odin).
//
// What the site gets:
//   pictures/mark_animation_home.png and mark_animation_home_light.png: one
//     sprite sheet for each color scheme. Each sprite is the whole picture of
//     the head of the home (the heron and the name) for one distinct frame,
//     side by side; the first sprite is the still heron, the same pixels as
//     mark_home.png.
//   pictures/mark_animation_icon.png: the same sprites at the size of the
//     icon of the tab (32 pixels, the drawing of the 32 of favicon.ico).
//     One sheet is one request; the script cuts it on a canvas.
//   mark_animation.js: the script, with the table of the sprites, of the
//     frames and of the order of play written into it: no other request.
// The home loads the script; no other page does.
package kerneltool

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:strings"
import "support:graphics"
import "support:mark"

SITE_MARK_ANIMATION_SCRIPT :: "mark_animation.js"
SITE_MARK_ANIMATION_HOME :: "mark_animation_home.png"
SITE_MARK_ANIMATION_HOME_LIGHT :: "mark_animation_home_light.png"
SITE_MARK_ANIMATION_ICON :: "mark_animation_icon.png"
SITE_MARK_ANIMATION_ICON_SIZE :: 32

// The distinct frames of all the animations. Two frames with the same cells
// (a frame of an animation that is the still heron again, a pose that an
// animation takes two times) are one sprite.
Site_Mark_Sprites :: struct {
	cells:    [dynamic]mark.Heron_Cells, // The first is the still heron.
	of_frame: [mark.Animation][]int, // For each animation, the sprite of its frames 1, 2, ...
}

site_mark_sprites :: proc() -> (sprites: Site_Mark_Sprites, ok: bool) {
	sprites.cells = make([dynamic]mark.Heron_Cells, context.temp_allocator)
	append(&sprites.cells, mark.still_cells())
	for animation in mark.Animation {
		count := mark.animation_frame_count(animation)
		places := make([]int, count, context.temp_allocator)
		for frame in 1 ..= count {
			cells, found := mark.animation_frame_cells(animation, frame)
			if !found {
				fmt.eprintfln("kerneltool: the animation %s of the mark has no frame %d", mark.animation_names[animation], frame)
				return {}, false
			}
			place := -1
			for &known, index in sprites.cells {
				if mark.cells_differ_count(&known, &cells) == 0 {
					place = index
					break
				}
			}
			if place < 0 {
				place = len(sprites.cells)
				append(&sprites.cells, cells)
			}
			places[frame - 1] = place
		}
		sprites.of_frame[animation] = places
	}
	return sprites, true
}

// The pictures of the mark that the sheets repeat: the head of the home in
// its two color schemes, and the 32 of favicon.ico.
site_mark_animation_pictures :: proc() -> (home_dark, home_light, icon: Site_Mark_Picture, ok: bool) {
	found_dark, found_light, found_icon := false, false, false
	for picture in site_mark_pictures {
		switch picture.file_name {
		case SITE_MARK_HOME:
			home_dark, found_dark = picture, true
		case SITE_MARK_HOME_LIGHT:
			home_light, found_light = picture, true
		}
	}
	for candidate in site_icons {
		if candidate.in_favicon && candidate.size == SITE_MARK_ANIMATION_ICON_SIZE {
			icon, found_icon = site_icon_picture(candidate), true
		}
	}
	if !found_dark || !found_light || !found_icon {
		fmt.eprintln("kerneltool: site: the pictures of the home or the icon of 32 pixels are not in the tables of the mark")
		return {}, {}, {}, false
	}
	return home_dark, home_light, icon, true
}

// site_mark_sheet_pixels gives the sprite sheet of a picture of the mark:
// each sprite drawn as that picture, side by side, from the left.
site_mark_sheet_pixels :: proc(picture: Site_Mark_Picture, sprites: ^Site_Mark_Sprites) -> (pixels: []u8, width, height, channels: int) {
	sprite_width, sprite_height := site_mark_size(picture)
	channels = site_mark_channels(picture)
	width = sprite_width * len(sprites.cells)
	height = sprite_height
	pixels = make([]u8, width * height * channels, context.temp_allocator)
	for &cells, index in sprites.cells {
		sprite := site_mark_pixels(picture, &cells)
		row_bytes := sprite_width * channels
		for row in 0 ..< sprite_height {
			copy(pixels[(row * width + index * sprite_width) * channels:][:row_bytes], sprite[row * row_bytes:][:row_bytes])
		}
	}
	return
}

// site_mark_animation_files gives the files of the animations, by their
// path in the site: the three sheets and the script.
site_mark_animation_files :: proc() -> (files: map[string][]u8, ok: bool) {
	sprites := site_mark_sprites() or_return
	home_dark, home_light, icon := site_mark_animation_pictures() or_return
	files = make(map[string][]u8, context.temp_allocator)
	sheets := [?]struct {
		file_name: string,
		picture:   Site_Mark_Picture,
	}{{SITE_MARK_ANIMATION_HOME, home_dark}, {SITE_MARK_ANIMATION_HOME_LIGHT, home_light}, {SITE_MARK_ANIMATION_ICON, icon}}
	for sheet in sheets {
		pixels, width, height, channels := site_mark_sheet_pixels(sheet.picture, &sprites)
		data := site_pixels_encode(sheet.file_name, width, height, channels, pixels) or_return
		files[strings.concatenate({SITE_PICTURE_FOLDER, "/", sheet.file_name}, context.temp_allocator)] = data
	}
	files[SITE_MARK_ANIMATION_SCRIPT] = transmute([]u8)site_mark_animation_script(&sprites, home_dark)
	return files, true
}

// site_mark_animation_write writes the files of the animations into the
// site, after the check that each sheet reads back as the frames of
// support/mark.
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
	fmt.printfln("kerneltool: site: the animations of the mark: %d animations, %d sprites, the order of play of %d steps; %s", len(mark.Animation), len(sprites.cells), len(mark.play_order), SITE_MARK_ANIMATION_SCRIPT)
	return true
}

// site_mark_animation_problems checks the files of the animations: each
// sheet decodes, has the size of its sprites, and each sprite has the
// pixels of its frame in support/mark; the script has its table.
site_mark_animation_problems :: proc(files: map[string][]u8) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	sprites, sprites_ok := site_mark_sprites()
	home_dark, home_light, icon, pictures_ok := site_mark_animation_pictures()
	if !sprites_ok || !pictures_ok {
		append(&problems, "the frames or the pictures of the animations of the mark are not readable")
		return problems[:]
	}
	sheets := [?]struct {
		file_name: string,
		picture:   Site_Mark_Picture,
	}{{SITE_MARK_ANIMATION_HOME, home_dark}, {SITE_MARK_ANIMATION_HOME_LIGHT, home_light}, {SITE_MARK_ANIMATION_ICON, icon}}
	for sheet in sheets {
		path := strings.concatenate({SITE_PICTURE_FOLDER, "/", sheet.file_name}, context.temp_allocator)
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
		expected, width, height, channels := site_mark_sheet_pixels(sheet.picture, &sprites)
		same := image.width == width && image.height == height && image.channels == channels && image.depth == 8 && len(image.pixels) == len(expected)
		for index := 0; same && index < len(expected); index += 1 {
			same = image.pixels[index] == expected[index]
		}
		if !same {
			append(&problems, fmt.tprintf("%s is not the frames of the animations of support/mark", path))
		}
	}
	script, has_script := files[SITE_MARK_ANIMATION_SCRIPT]
	if !has_script || strings.contains(string(script), "/*TABLE*/") {
		append(&problems, SITE_MARK_ANIMATION_SCRIPT + " has no table of the frames")
	}
	return problems[:]
}

// site_mark_animation_table_json gives the table that the script reads:
//   sprites: the count of sprites in each sheet;
//   home: the two sheets of the head of the home and the size of a sprite;
//   icon: the sheet of the icon and the size of a sprite;
//   animations: for each animation its name and its frames, each frame
//     [sprite, milliseconds];
//   order: the order of play, each step [still milliseconds, animation];
//   limits: the bounds of support/mark, which the self test checks.
// The paths are relative to the folder of the script: the root of the site.
site_mark_animation_table_json :: proc(sprites: ^Site_Mark_Sprites, home: Site_Mark_Picture) -> string {
	// The braces are written as text, never through a format of fmt.
	b := strings.builder_make(context.temp_allocator)
	write :: proc(b: ^strings.Builder, text: string) {
		strings.write_string(b, text)
	}
	number :: proc(b: ^strings.Builder, value: int) {
		strings.write_string(b, fmt.tprintf("%d", value))
	}
	width, height := site_mark_size(home)
	write(&b, "{\"sprites\":")
	number(&b, len(sprites.cells))
	write(&b, ",\"home\":{\"dark\":")
	site_json_string(&b, SITE_PICTURE_FOLDER + "/" + SITE_MARK_ANIMATION_HOME)
	write(&b, ",\"light\":")
	site_json_string(&b, SITE_PICTURE_FOLDER + "/" + SITE_MARK_ANIMATION_HOME_LIGHT)
	write(&b, ",\"width\":")
	number(&b, width)
	write(&b, ",\"height\":")
	number(&b, height)
	write(&b, "},\"icon\":{\"sheet\":")
	site_json_string(&b, SITE_PICTURE_FOLDER + "/" + SITE_MARK_ANIMATION_ICON)
	write(&b, ",\"size\":")
	number(&b, SITE_MARK_ANIMATION_ICON_SIZE)
	write(&b, "},\"animations\":[")
	first_animation := true
	for animation in mark.Animation {
		write(&b, first_animation ? "{\"name\":" : ",{\"name\":")
		first_animation = false
		site_json_string(&b, mark.animation_names[animation])
		write(&b, ",\"frames\":[")
		for sprite, frame_index in sprites.of_frame[animation] {
			row, _ := mark.animation_frame(animation, frame_index + 1)
			write(&b, frame_index > 0 ? ",[" : "[")
			number(&b, sprite)
			write(&b, ",")
			number(&b, int(row.duration_milliseconds))
			write(&b, "]")
		}
		write(&b, "]}")
	}
	write(&b, "],\"order\":[")
	for step, index in mark.play_order {
		write(&b, index > 0 ? ",[" : "[")
		number(&b, int(step.still_milliseconds))
		write(&b, ",")
		number(&b, int(step.animation))
		write(&b, "]")
	}
	write(&b, "],\"limits\":{\"frameLeast\":")
	number(&b, mark.FRAME_DURATION_LEAST)
	write(&b, ",\"frameMost\":")
	number(&b, mark.FRAME_DURATION_MOST)
	write(&b, ",\"stillLeast\":")
	number(&b, mark.STILL_DURATION_LEAST)
	write(&b, ",\"stillMost\":")
	number(&b, mark.STILL_DURATION_MOST)
	write(&b, "}}")
	return strings.to_string(b)
}

// site_mark_animation_script gives mark_animation.js: the source below with
// the table in its place.
site_mark_animation_script :: proc(sprites: ^Site_Mark_Sprites, home: Site_Mark_Picture) -> string {
	script, _ := strings.replace_all(SITE_MARK_ANIMATION_SCRIPT_SOURCE, "/*TABLE*/null", site_mark_animation_table_json(sprites, home), context.temp_allocator)
	return script
}

// The picture of every frame for the owner, written by `kerneltool logo`
// into the build folder: one row for each animation, its frames from the
// still heron at cells of 8 pixels, each with its duration, and the order
// of play at the bottom. It is not a file of the site or of the repository.
MARK_ANIMATIONS_PICTURE :: BUILD_FOLDER + "/mark_animations.png"
MARK_ANIMATIONS_CELL_SIZE :: 8
MARK_ANIMATIONS_MARGIN :: 32
MARK_ANIMATIONS_GAP :: 16
MARK_ANIMATIONS_LINE :: 24 // A line of text of the font of 8 by 16.
MARK_ANIMATIONS_ORDER_STEPS_IN_A_LINE :: 5

mark_animations_picture_write :: proc() -> bool {
	heron := mark.heron_size(MARK_ANIMATIONS_CELL_SIZE)
	most_frames := 0
	for animation in mark.Animation {
		most_frames = max(most_frames, mark.animation_frame_count(animation))
	}
	// The still heron, then each frame.
	column_width := heron + MARK_ANIMATIONS_GAP
	row_height := MARK_ANIMATIONS_LINE + heron + MARK_ANIMATIONS_LINE + MARK_ANIMATIONS_GAP
	order_lines := (len(mark.play_order) + MARK_ANIMATIONS_ORDER_STEPS_IN_A_LINE - 1) / MARK_ANIMATIONS_ORDER_STEPS_IN_A_LINE
	width := 2 * MARK_ANIMATIONS_MARGIN + (most_frames + 1) * column_width
	height := 2 * MARK_ANIMATIONS_MARGIN + MARK_ANIMATIONS_LINE + len(mark.Animation) * row_height + (1 + order_lines) * MARK_ANIMATIONS_LINE
	colors := make([]graphics.Color, width * height, context.temp_allocator)
	canvas := graphics.Canvas{pixels = raw_data(colors), width = width, height = height, stride = width}
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	saved := graphics.text_state
	defer graphics.text_state = saved
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)

	y := MARK_ANIMATIONS_MARGIN
	graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, "The animations of the mark (support/mark): frame 0 is the still heron; cells of 8 pixels", graphics.COLOR_TEXT)
	y += MARK_ANIMATIONS_LINE
	for animation in mark.Animation {
		heading := fmt.tprintf("%s: %d frames, %d ms, weight %d of %d", mark.animation_names[animation], mark.animation_frame_count(animation), mark.animation_duration(animation), mark.animation_weight(animation), len(mark.play_order))
		graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, heading, graphics.COLOR_KERNEL)
		count := mark.animation_frame_count(animation)
		for frame in 0 ..= count {
			x := MARK_ANIMATIONS_MARGIN + frame * column_width
			cells, _ := mark.animation_frame_cells(animation, frame)
			graphics.fill(canvas, x, y + MARK_ANIMATIONS_LINE, heron, heron, graphics.COLOR_CARD_TOP)
			mark.cells_draw(canvas, &cells, x, y + MARK_ANIMATIONS_LINE, MARK_ANIMATIONS_CELL_SIZE, false)
			caption := "still"
			if frame > 0 {
				row, _ := mark.animation_frame(animation, frame)
				still := mark.still_cells()
				caption = fmt.tprintf("%d: %d ms, %d cells", frame, row.duration_milliseconds, mark.cells_differ_count(&cells, &still))
			}
			graphics.text(canvas, x, y + MARK_ANIMATIONS_LINE + heron + 4, caption, graphics.COLOR_DIM)
		}
		y += row_height
	}
	graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, "The order of play (the still time, then the animation); it repeats:", graphics.COLOR_TEXT)
	y += MARK_ANIMATIONS_LINE
	line := strings.builder_make(context.temp_allocator)
	for step, index in mark.play_order {
		fmt.sbprintf(&line, "%d ms %s", step.still_milliseconds, mark.animation_names[step.animation])
		last_of_line := (index + 1) % MARK_ANIMATIONS_ORDER_STEPS_IN_A_LINE == 0 || index == len(mark.play_order) - 1
		if !last_of_line {
			strings.write_string(&line, ", ")
			continue
		}
		graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, strings.to_string(line), graphics.COLOR_DIM)
		strings.builder_reset(&line)
		y += MARK_ANIMATIONS_LINE
	}

	rgb := make([]u8, 3 * len(colors), context.temp_allocator)
	for color, index in colors {
		rgb[3 * index] = u8(color >> 16)
		rgb[3 * index + 1] = u8(color >> 8)
		rgb[3 * index + 2] = u8(color)
	}
	data := site_pixels_encode(MARK_ANIMATIONS_PICTURE, width, height, 3, rgb) or_return
	if !make_folder(BUILD_FOLDER) {
		return false
	}
	if err := os.write_entire_file(MARK_ANIMATIONS_PICTURE, data); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", MARK_ANIMATIONS_PICTURE, err)
		return false
	}
	fmt.printfln("kerneltool: wrote %s (%d by %d pixels, %d bytes): every frame of the animations of the mark", MARK_ANIMATIONS_PICTURE, width, height, len(data))
	return true
}

// The script. It changes nothing for a reader who asks for reduced motion,
// and nothing in a hidden tab. The still picture stays in the page: a
// browser with no script shows it, and the script puts a canvas of the same
// size in its place only while it plays.
SITE_MARK_ANIMATION_SCRIPT_SOURCE :: `// The animations of the mark on the home, written by kerneltool site
// (tools/kerneltool/site_mark_animation.odin) from support/mark/animation.odin.
// The large heron of the head and the icon of the tab move a few cells from
// time to time; between two animations the heron is still for seconds.
// Nothing moves when the person asks for reduced motion, and nothing runs
// in a hidden tab. ?selftest=1 in the address checks the table.
"use strict";
(function () {
  const TABLE = /*TABLE*/null;
  const script = document.currentScript;
  if (!script || !TABLE) return;
  const root = new URL(".", script.src);

  // The order of play as a pure step: the state is the step of the order and
  // the frame of its animation (-1: the still time before the animation).
  // advance gives the next state, the sprite to show and how long it shows.
  const START = { step: 0, frame: -1 };
  function advance(state) {
    const frames = TABLE.animations[TABLE.order[state.step][1]].frames;
    if (state.frame + 1 < frames.length) {
      const frame = state.frame + 1;
      return { state: { step: state.step, frame: frame }, sprite: frames[frame][0], delay: frames[frame][1] };
    }
    const step = (state.step + 1) % TABLE.order.length;
    return { state: { step: step, frame: -1 }, sprite: 0, delay: TABLE.order[step][0] };
  }

  function selfTest() {
    const cases = [];
    function check(name, passed) { cases.push({ name: name, passed: passed }); }
    const limits = TABLE.limits;
    check("a sheet has sprites", TABLE.sprites >= 1);
    check("a sprite of the home has a size", TABLE.home.width > 0 && TABLE.home.height > 0);
    check("a sprite of the icon has a size", TABLE.icon.size > 0);
    TABLE.animations.forEach((animation, index) => {
      check(animation.name + ": frames", animation.frames.length >= 1);
      check(animation.name + ": each sprite is in the sheet", animation.frames.every(f => Number.isInteger(f[0]) && f[0] >= 0 && f[0] < TABLE.sprites));
      check(animation.name + ": each duration is in its range", animation.frames.every(f => f[1] >= limits.frameLeast && f[1] <= limits.frameMost));
      check(animation.name + ": the first frame moves", animation.frames[0][0] !== 0);
      check(animation.name + ": in the order of play", TABLE.order.some(s => s[1] === index));
    });
    check("each step of the order names an animation", TABLE.order.every(s => Number.isInteger(s[1]) && s[1] >= 0 && s[1] < TABLE.animations.length));
    check("each still time is in its range", TABLE.order.every(s => s[0] >= limits.stillLeast && s[0] <= limits.stillMost));
    // One whole turn of the order through advance: it plays each step once,
    // in order, ends still at the start, and changes the picture at most
    // once in each frameLeast milliseconds.
    let state = START, played = 0, quick = 0, guard = 0;
    do {
      const next = advance(state);
      if (next.state.frame === 0) played++;
      if (next.delay < limits.frameLeast) quick++;
      state = next.state;
      guard++;
    } while ((state.step !== START.step || state.frame !== START.frame) && guard < 10000);
    check("one turn of the order plays each step once", played === TABLE.order.length);
    check("one turn ends still at the start", state.step === 0 && state.frame === -1);
    check("no change comes sooner than the shortest frame", quick === 0);
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

  let sheets = null, loading = null, canvas = null, context = null;
  let state = START, shown = -1, timer = 0;
  let iconLink = null, iconSprite = -1;
  const iconAddresses = [];

  function load() {
    if (!loading) {
      const paths = [TABLE.home.dark, TABLE.home.light, TABLE.icon.sheet];
      const images = paths.map(path => { const image = new Image(); image.src = new URL(path, root).href; return image; });
      loading = Promise.all(images.map(image => image.decode())).then(() => {
        sheets = { dark: images[0], light: images[1], icon: images[2] };
      }).catch(() => { sheets = null; });
    }
    return loading;
  }

  // The large heron: one sprite of the sheet of the color scheme of now,
  // at the size of the still picture, in the same box.
  function draw(sprite) {
    const sheet = light.matches ? sheets.light : sheets.dark;
    const width = TABLE.home.width, height = TABLE.home.height;
    context.clearRect(0, 0, width, height);
    context.drawImage(sheet, sprite * width, 0, width, height, 0, 0, width, height);
    shown = sprite;
  }

  // The icon of the tab: one sprite at 32 pixels, as a data address. Each
  // address is made once. The link is in the head only during an animation.
  function iconAddress(sprite) {
    if (!iconAddresses[sprite]) {
      const size = TABLE.icon.size;
      const icon = document.createElement("canvas");
      icon.width = size;
      icon.height = size;
      icon.getContext("2d").drawImage(sheets.icon, sprite * size, 0, size, size, 0, 0, size, size);
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

  function tick() {
    const next = advance(state);
    state = next.state;
    if (next.sprite !== shown) draw(next.sprite);
    if (state.frame >= 0) showIcon(next.sprite); else stillIcon();
    timer = window.setTimeout(tick, next.delay);
  }

  function canPlay() { return !reduce.matches && !document.hidden; }

  function start() {
    if (!canPlay() || timer) return;
    load().then(() => {
      if (!sheets || !canPlay() || timer) return;
      if (!canvas) {
        canvas = document.createElement("canvas");
        canvas.width = TABLE.home.width;
        canvas.height = TABLE.home.height;
        canvas.className = still.className;
        canvas.setAttribute("role", "img");
        canvas.setAttribute("aria-label", still.alt);
        context = canvas.getContext("2d");
        context.imageSmoothingEnabled = false;
      }
      // The still time of the step of now, then the play.
      state = { step: state.step, frame: -1 };
      draw(0);
      // The style sheet gives the picture display: block, which wins over
      // the attribute hidden: the script sets its display itself.
      picture.after(canvas);
      picture.style.display = "none";
      timer = window.setTimeout(tick, TABLE.order[state.step][0]);
    });
  }

  // Back to the still picture of the page and to the icons of the page.
  function stop() {
    if (timer) window.clearTimeout(timer);
    timer = 0;
    if (canvas && canvas.parentNode) canvas.remove();
    picture.style.display = "";
    shown = -1;
    if (sheets) stillIcon();
  }

  function fit() { if (canPlay()) start(); else stop(); }
  reduce.addEventListener("change", fit);
  document.addEventListener("visibilitychange", fit);
  light.addEventListener("change", () => { if (canvas && canvas.parentNode && shown >= 0) draw(shown); });
  fit();
})();
`
