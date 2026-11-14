package kerneltool

// The film of the program heron, the command `kerneltool film heron`
// (docs/TOOLS.md, "The film"). What the program shows for each key is in
// the design rules (docs/DESIGN.md, "The animations" and "The moves").
//
// Before the film starts, the scenario makes the desktop: the console at
// the left, the window of heron in front of it, wholly on the screen, and
// the pointer in a corner. Then the worker films:
//
//  1. the heron stands, and plays animations in its own order;
//  2. the key 8: the dash at full speed, two times;
//  3. the key s, then 8: the dash four times slower;
//  4. the key l: the lines of the cells; then the hop, the stretch and the
//     flap;
//  5. Space, 8, and two times the dot: the dash frame by frame, with the
//     changed cells outlined;
//  6. the key g: the same held frame in the free way, then on the grid
//     again; two more frames; the lines go;
//  7. the key z: the cells of 8, of 4 and of 12 pixels; Space: the dash
//     goes on from its held frame; a last dash at full speed.
//
// The keys and the lines of the dash, of the held third frame and of its
// two ways are those of the main scenario of the machine test
// (machine.odin): the film shows what the test checks. A scene waits for
// its line before its hold, so the film never shows a state that the
// machine did not reach.
//
// The program writes no line for some of its keys. The scenario then
// sends the key, holds for the viewer, and waits for the next line that
// the program writes, which names the state after these keys:
//   - a dot writes no line: the line of the key g, or of the key l, after
//     the dots names the frame that they reached;
//   - Space and an animation key during a pause write no line: the same
//     line says "held" and names the animation;
//   - the key s writes no line: the line of the slow dash is the line of
//     a dash;
//   - the key z writes no line, and no line names the cell size;
//   - an animation of the own order of the heron writes no line: the
//     first scene is a hold that is longer than the longest still time
//     (1287 ms), so one animation starts in it.
@(rodata)
scenario_heron_film := [?]Step {
	// The boot. The programs write in an order that the system does not fix.
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped with code 0", any_order = true},
	// The desktop of the film. The console goes to the left first: a drag
	// brings its window to the front, and the window of heron must be the
	// one in front, with the keys. The window of heron is 644 by 514
	// pixels with its frame: at (368, 144) it ends 12 pixels before the
	// right edge of the screen and 110 above its bottom edge.
	{kind = .Move, text = "console", to_x = 8, to_y = 40},
	{kind = .Launch, text = "heron"},
	{kind = .Wait, text = "heron: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface heron"},
	{kind = .Move, text = "heron", to_x = 368, to_y = 144},
	// The pointer leaves the window: a press on the background, in the
	// corner of the screen, which no window covers. A press on the
	// background brings no window to the front: heron keeps the keys.
	{kind = .Click, x = 1018, y = 762},

	// Scene 1: the heron stands, then plays in its own order.
	{kind = .Film_Start, text = "heron"},
	{kind = .Film_Hold, milliseconds = 2 * FILM_HOLD_READ},

	// Scene 2: the dash at full speed. The heron leaves the window by the
	// right and comes back by the left. Then once more.
	{kind = .Keys, text = "8"},
	{kind = .Wait, text = "heron: dash played: 17 frames, the heron left the window and came back, on the grid"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Keys, text = "8"},
	{kind = .Wait, text = "heron: dash played: 17 frames, the heron left the window and came back, on the grid"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},

	// Scene 3: the same dash four times slower: the forms of the crouch,
	// of the run and of the brake read. The band shows "slow" in the color
	// of a state that is on.
	{kind = .Keys, text = "s"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Keys, text = "8"},
	{kind = .Wait, text = "heron: dash played: 17 frames, the heron left the window and came back, on the grid"},
	{kind = .Keys, text = "s"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 4: the lines of the cells, then three more moves on the grid.
	// The line of the key l names the still heron or the animation of the
	// own order that plays: both end with the lines shown.
	{kind = .Keys, text = "l"},
	{kind = .Wait, text = "; the lines of the cells shown"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Keys, text = "9"},
	{kind = .Wait, text = "heron: hop played: "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Keys, text = "c"},
	{kind = .Wait, text = "heron: stretch played: "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Keys, text = "f"},
	{kind = .Wait, text = "heron: flap played: "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 5: the dash frame by frame. Space pauses, the key 8 shows the
	// first frame, and each dot the next one: the third frame has the form
	// of the run, with the cells that it changed outlined in white.
	{kind = .Key, text = "spc"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Keys, text = "8"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Keys, text = "."},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Keys, text = "."},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},

	// Scene 6: the same held frame in the free way: the frame is stretched
	// and its cells are rectangles. Then on the grid again. Each line
	// names the third frame, held: the two dots took effect.
	{kind = .Keys, text = "g"},
	{kind = .Wait, text = "heron: shows dash at frame 3 of 17, held, free: the frame stretched to "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Keys, text = "g"},
	{kind = .Wait, text = "heron: shows dash at frame 3 of 17, held, on the grid: the form run, "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	// Two more frames: the heron goes to the right edge of the window.
	// The key l hides the lines, and its line names the fifth frame.
	{kind = .Keys, text = "."},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Keys, text = "."},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Keys, text = "l"},
	{kind = .Wait, text = "heron: shows dash at frame 5 of 17, held, on the grid: "},
	{kind = .Wait, text = "; the lines of the cells hidden"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},

	// Scene 7: the cell size, on the held frame: 8 pixels, 4, then 12
	// again. Space: the dash goes on from its fifth frame to its end. Then
	// a last dash at full speed, whose line says that the cells are those
	// of the grid and that the heron is back in its place.
	{kind = .Keys, text = "z"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Keys, text = "z"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Keys, text = "z"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "heron: dash played: "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Keys, text = "8"},
	{kind = .Wait, text = "heron: dash played: 17 frames, the heron left the window and came back, on the grid"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Film_Stop},
	{kind = .Quit},
}
