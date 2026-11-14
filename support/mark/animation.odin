package mark

import "support:graphics"

// The animations of the heron (docs/DESIGN.md, "The mark", "The
// animations"): small idle movements of a few cells. The bird itself is the
// still heron of heron_rows; an animation does not draw it again, it moves a
// few cells of it. Pure data and pure procedures, as the still heron.
//
// The form of the data: tables of fixed rows, as the table of the parts.
//   animation_frames: one row for each frame, with its duration. The frames
//     of an animation are numbered 1, 2, ... in the order of play. The frame
//     0 of every animation is the still heron, and after its last frame an
//     animation goes back to the still heron.
//   animation_changes: one row for each cell that a frame changes: the cell
//     takes the letter of another part, or "." (empty).
//   A frame starts from the still heron, or from an earlier frame of the
//   same animation (base_frame), then applies its own changes. So a frame
//   that repeats a pose names it, and the changes are not written twice.
//
// The data says what the heron does, not when: which animation plays next,
// and how long the heron is still between two of them, is the rule of the
// place that plays them (docs/SITE.md, "The rhythm of the animations").
//
// A cell that a frame changes takes the color of its new part at that pixel:
// the gradient over the box of the part in the still heron. A cell outside
// that box takes the color of the nearer end of the gradient.

// One idle movement of the heron.
Animation :: enum u8 {
	Blink, // The eye closes.
	Look, // The head and the beak move forward one cell, then back one cell.
	Leg, // The knee of the raised leg comes in, and out again.
	Ripple, // Two waves leave the legs on the line of the water.
	Dip, // The head dips one cell, the eye closes, then a swallow goes down the neck.
	Preen, // The neck bends down and back, the beak scratches the back two times, the neck comes up.
	Scratch, // The raised leg goes down and scratches the ground three times.
	Dash, // The heron winds up, runs with lines of speed behind it, then stops with a splash.
	Hop, // The heron bends its knee, leaves the water with its foot tucked, and lands in two waves.
	Fish, // A fish of two cells jumps out of the water in front of the heron, which looks at it.
	Doze, // The eye stays closed and a letter z of cells rises behind the head.
	Stretch, // The eye closes for a long stretch, then the crest stands out.
	Ruffle, // The wind blows the crest back and lifts a feather of the tail.
	Wade, // The heron changes the leg it stands on, two times.
	Flap, // The wing beats above and below the body, and the foot leaves the water.
}

// The name of each animation, for a test and a line of the log.
@(rodata)
animation_names := [Animation]string {
	.Blink   = "blink",
	.Look    = "look",
	.Leg     = "leg",
	.Ripple  = "ripple",
	.Dip     = "dip",
	.Preen   = "preen",
	.Scratch = "scratch",
	.Dash    = "dash",
	.Hop     = "hop",
	.Fish    = "fish",
	.Doze    = "doze",
	.Stretch = "stretch",
	.Ruffle  = "ruffle",
	.Wade    = "wade",
	.Flap    = "flap",
}

// The bounds that the host tests hold the tables to. A frame that differs
// from the still heron, or from the frame before it, by more cells than the
// limit of its animation is a new drawing, not an idle movement. Most
// animations move a few cells and keep FRAME_CHANGE_LIMIT. The preen moves
// the whole head and the upper neck onto the back, and the dash moves both
// legs and draws the lines of speed, so each has a limit of its own; a new
// animation that needs more is a decision, not a change of the common
// limit.
FRAME_CHANGE_LIMIT :: 24
PREEN_FRAME_CHANGE_LIMIT :: 48
DASH_FRAME_CHANGE_LIMIT :: 40

// The limit of the changed cells of a frame, for each animation.
@(rodata)
animation_change_limits := [Animation]int {
	.Blink   = FRAME_CHANGE_LIMIT,
	.Look    = FRAME_CHANGE_LIMIT,
	.Leg     = FRAME_CHANGE_LIMIT,
	.Ripple  = FRAME_CHANGE_LIMIT,
	.Dip     = FRAME_CHANGE_LIMIT,
	.Preen   = PREEN_FRAME_CHANGE_LIMIT,
	.Scratch = FRAME_CHANGE_LIMIT,
	.Dash    = DASH_FRAME_CHANGE_LIMIT,
	.Hop     = FRAME_CHANGE_LIMIT,
	.Fish    = FRAME_CHANGE_LIMIT,
	.Doze    = FRAME_CHANGE_LIMIT,
	.Stretch = FRAME_CHANGE_LIMIT,
	.Ruffle  = FRAME_CHANGE_LIMIT,
	.Wade    = FRAME_CHANGE_LIMIT,
	.Flap    = FRAME_CHANGE_LIMIT,
}

// The shortest frame keeps the changes of an idle movement to at most about
// 6 each second. The legs of the dash run: their frames are shorter, and
// only the dash has them.
FRAME_DURATION_LEAST :: 150 // Milliseconds.
DASH_FRAME_DURATION_LEAST :: 70 // Milliseconds: a step of the run.
FRAME_DURATION_MOST :: 1000 // Milliseconds.
ANIMATION_DURATION_MOST :: 3000 // All the frames of one animation.

// The shortest frame of each animation.
@(rodata)
animation_frame_duration_least := [Animation]int {
	.Blink   = FRAME_DURATION_LEAST,
	.Look    = FRAME_DURATION_LEAST,
	.Leg     = FRAME_DURATION_LEAST,
	.Ripple  = FRAME_DURATION_LEAST,
	.Dip     = FRAME_DURATION_LEAST,
	.Preen   = FRAME_DURATION_LEAST,
	.Scratch = FRAME_DURATION_LEAST,
	.Dash    = DASH_FRAME_DURATION_LEAST,
	.Hop     = FRAME_DURATION_LEAST,
	.Fish    = FRAME_DURATION_LEAST,
	.Doze    = FRAME_DURATION_LEAST,
	.Stretch = FRAME_DURATION_LEAST,
	.Ruffle  = FRAME_DURATION_LEAST,
	.Wade    = FRAME_DURATION_LEAST,
	.Flap    = FRAME_DURATION_LEAST,
}

// One frame of an animation: a row of animation_frames.
Animation_Frame :: struct {
	animation:             Animation, // The animation of the frame.
	frame:                 u8, // 1, 2, ...: the order of play.
	base_frame:            u8, // 0: the still heron. Else an earlier frame of the same animation.
	duration_milliseconds: u16, // How long the frame stays.
}

// One cell that a frame changes: a row of animation_changes.
Cell_Change :: struct {
	animation: Animation, // The animation of the frame.
	frame:     u8, // The frame, from 1.
	column:    u8, // The column of the cell, from 0.
	row:       u8, // The row of the cell, from 0.
	letter:    u8, // The letter of a part, or '.' for an empty cell.
}

// The frames of all the animations, by animation, in the order of play.
@(rodata)
animation_frames := [?]Animation_Frame {
	{.Blink, 1, 0, 150},
	{.Look, 1, 0, 800}, // Forward.
	{.Look, 2, 0, 250}, // Still: no change.
	{.Look, 3, 0, 800}, // Back.
	{.Leg, 1, 0, 200}, // The knee half in.
	{.Leg, 2, 0, 500}, // The knee in.
	{.Leg, 3, 1, 200}, // The knee half in again.
	{.Ripple, 1, 0, 180},
	{.Ripple, 2, 0, 180},
	{.Ripple, 3, 0, 180},
	{.Ripple, 4, 0, 180},
	{.Dip, 1, 0, 300}, // The head one cell lower.
	{.Dip, 2, 1, 250}, // Lower, the eye closed.
	{.Dip, 3, 1, 350}, // Lower, the eye open.
	{.Dip, 4, 0, 220}, // The head back; a swallow at the top of the neck.
	{.Dip, 5, 0, 220}, // The swallow in the middle of the neck.
	{.Dip, 6, 0, 220}, // The swallow at the bottom of the neck.
	// The neck goes down through two poses, so the head does not jump onto
	// the back, and comes up through the same poses.
	{.Preen, 1, 0, 250}, // The head three rows lower, the neck curved.
	{.Preen, 2, 1, 250}, // The head turned back, the beak above the body.
	{.Preen, 3, 2, 300}, // The head on the back, the beak in the feathers.
	{.Preen, 4, 3, 180}, // A stroke: the tip of the beak up, a feather lifts.
	{.Preen, 5, 3, 180}, // The beak in the feathers.
	{.Preen, 6, 4, 180}, // A stroke.
	{.Preen, 7, 3, 250}, // The beak in the feathers.
	{.Preen, 8, 2, 250}, // The head turned back.
	{.Preen, 9, 1, 250}, // The head three rows lower.
	{.Scratch, 1, 0, 200}, // The knee in: the pose of the leg animation.
	{.Scratch, 2, 0, 220}, // The foot forward on the ground.
	{.Scratch, 3, 0, 220}, // The foot pulled back; water lifts behind it.
	{.Scratch, 4, 2, 200}, // Forward.
	{.Scratch, 5, 3, 220}, // Back; the water lifts one cell farther.
	{.Scratch, 6, 2, 200}, // Forward.
	{.Scratch, 7, 3, 220}, // Back.
	{.Scratch, 8, 1, 200}, // The knee in, then the raised leg again.
	// The dash: the wind-up, fourteen steps of the run in two poses, the
	// stop and the last wave. The place that plays it moves the heron during
	// the run and the stop; the frames are the same with no move.
	{.Dash, 1, 0, 380}, // The wind-up: the knee in, the pose of the leg animation.
	{.Dash, 2, 0, 70}, // The run, the legs apart; lines of speed behind.
	{.Dash, 3, 0, 70}, // The run, the legs together; the lines two cells back.
	{.Dash, 4, 2, 70},
	{.Dash, 5, 3, 70},
	{.Dash, 6, 2, 70},
	{.Dash, 7, 3, 70},
	{.Dash, 8, 2, 70},
	{.Dash, 9, 3, 70},
	{.Dash, 10, 2, 70},
	{.Dash, 11, 3, 70},
	{.Dash, 12, 2, 70},
	{.Dash, 13, 3, 70},
	{.Dash, 14, 2, 70},
	{.Dash, 15, 3, 70},
	{.Dash, 16, 0, 220}, // The stop: the legs together, water lifts in front of them.
	{.Dash, 17, 0, 200}, // The heron stands again; one wave at each side.
	{.Hop, 1, 0, 180}, // The knee half in: the heron gathers.
	{.Hop, 2, 0, 320}, // In the air: the foot tucked, the water closed under it.
	{.Hop, 3, 0, 200}, // The landing: a wave at each side of the legs.
	{.Hop, 4, 0, 180}, // The waves two columns farther.
	{.Fish, 1, 0, 220}, // The fish comes out of the water.
	{.Fish, 2, 0, 200}, // The fish higher; the head looks forward.
	{.Fish, 3, 2, 250}, // The fish at the top of its jump.
	{.Fish, 4, 3, 200}, // The fish on its way down.
	{.Fish, 5, 0, 200}, // The fish enters the water; a splash at each side.
	{.Fish, 6, 0, 180}, // The splash, farther out.
	{.Doze, 1, 0, 500}, // The eye closes.
	{.Doze, 2, 1, 400}, // One cell behind the head.
	{.Doze, 3, 2, 600}, // A letter z above it.
	{.Doze, 4, 1, 600}, // The letter higher, a cell under it.
	{.Doze, 5, 1, 300}, // The eye still closed.
	{.Stretch, 1, 0, 700}, // The eye closed.
	{.Stretch, 2, 0, 400}, // The eye open, the crest out.
	{.Ruffle, 1, 0, 180}, // The crest blown back one cell.
	{.Ruffle, 2, 1, 180}, // The crest longer; a feather of the tail lifts.
	{.Ruffle, 3, 1, 180},
	{.Ruffle, 4, 2, 180},
	{.Ruffle, 5, 1, 180},
	{.Wade, 1, 0, 350}, // The other leg stands, the first one is raised behind.
	{.Wade, 2, 0, 350}, // Still: no change.
	{.Wade, 3, 1, 350}, // The other leg again.
	{.Flap, 1, 0, 200}, // The wing above the back.
	{.Flap, 2, 0, 150}, // The wing under the body; the foot out of the water.
	{.Flap, 3, 1, 150}, // The wing above the back; the foot out of the water.
	{.Flap, 4, 2, 150},
	{.Flap, 5, 3, 150},
	{.Flap, 6, 1, 200}, // The wing above the back; the foot in the water.
}

// The columns count from the left and the rows from the top, as in
// heron_rows: the eye is at column 17, row 2.
@(rodata)
animation_changes := [?]Cell_Change {
	// Blink: the eye takes the color of the head.
	{.Blink, 1, 17, 2, 'h'},

	// Look, forward: the crest and the rows 1 to 3 of the head one cell to
	// the right; the tip of the beak leaves the grid.
	{.Look, 1, 14, 0, '.'},
	{.Look, 1, 16, 0, 'v'},
	{.Look, 1, 15, 1, '.'},
	{.Look, 1, 19, 1, 'h'},
	{.Look, 1, 14, 2, '.'},
	{.Look, 1, 17, 2, 'h'},
	{.Look, 1, 18, 2, 'k'},
	{.Look, 1, 19, 2, 'h'},
	{.Look, 1, 15, 3, '.'},
	{.Look, 1, 19, 3, 'h'},
	{.Look, 1, 22, 3, 'y'},
	// Look, back: the same rows one cell to the left of the still heron.
	{.Look, 3, 13, 0, 'v'},
	{.Look, 3, 15, 0, '.'},
	{.Look, 3, 14, 1, 'h'},
	{.Look, 3, 18, 1, '.'},
	{.Look, 3, 13, 2, 'h'},
	{.Look, 3, 16, 2, 'k'},
	{.Look, 3, 17, 2, 'h'},
	{.Look, 3, 18, 2, 'y'},
	{.Look, 3, 23, 2, '.'},
	{.Look, 3, 14, 3, 'h'},
	{.Look, 3, 18, 3, 'y'},
	{.Look, 3, 21, 3, '.'},

	// Leg: the knee of the raised leg is at column 14 of row 19. Half in: it
	// moves to column 13. In: the rows 18 to 20 of that leg one column to
	// the left, so the leg is almost straight.
	{.Leg, 1, 14, 19, '.'},
	{.Leg, 1, 13, 19, 'o'},
	{.Leg, 2, 13, 18, '.'},
	{.Leg, 2, 12, 18, 'o'},
	{.Leg, 2, 14, 19, '.'},
	{.Leg, 2, 13, 19, 'o'},
	{.Leg, 2, 13, 20, '.'},
	{.Leg, 2, 12, 20, 'o'},

	// Ripple: one cell of water above the line, at each side of the legs,
	// two columns farther at each frame.
	{.Ripple, 1, 8, 21, 't'},
	{.Ripple, 1, 13, 21, 't'},
	{.Ripple, 2, 6, 21, 't'},
	{.Ripple, 2, 15, 21, 't'},
	{.Ripple, 3, 4, 21, 't'},
	{.Ripple, 3, 17, 21, 't'},
	{.Ripple, 4, 2, 21, 't'},
	{.Ripple, 4, 18, 21, 't'},

	// Dip: the crest and the rows 1 to 3 of the head one row lower; the head
	// covers the top row of the neck.
	{.Dip, 1, 14, 0, '.'},
	{.Dip, 1, 15, 0, '.'},
	{.Dip, 1, 14, 1, 'v'},
	{.Dip, 1, 15, 1, 'v'},
	{.Dip, 1, 16, 1, '.'},
	{.Dip, 1, 17, 1, '.'},
	{.Dip, 1, 18, 1, '.'},
	{.Dip, 1, 14, 2, '.'},
	{.Dip, 1, 17, 2, 'h'},
	{.Dip, 1, 19, 2, '.'},
	{.Dip, 1, 20, 2, '.'},
	{.Dip, 1, 21, 2, '.'},
	{.Dip, 1, 22, 2, '.'},
	{.Dip, 1, 23, 2, '.'},
	{.Dip, 1, 14, 3, 'h'},
	{.Dip, 1, 17, 3, 'k'},
	{.Dip, 1, 22, 3, 'y'},
	{.Dip, 1, 23, 3, 'y'},
	{.Dip, 1, 17, 4, 'h'},
	{.Dip, 1, 18, 4, 'h'},
	{.Dip, 1, 19, 4, 'y'},
	{.Dip, 1, 20, 4, 'y'},
	{.Dip, 1, 21, 4, 'y'},
	// The eye of the lower head closes.
	{.Dip, 2, 17, 3, 'h'},
	// The swallow: one cell on the front of the neck, lower at each frame.
	{.Dip, 4, 17, 5, 'h'},
	{.Dip, 5, 15, 7, 'h'},
	{.Dip, 6, 16, 9, 'h'},

	// Preen, frame 1, from the still heron: the crest and the head three rows
	// lower, the upper neck shorter, with the curve of the still neck.
	// Frame 2, from frame 1: the head turned to face back, the beak to the
	// left above the body. Frame 3, from frame 2: the head folded onto the
	// shoulder, the eye at column 11, row 9, the beak down to the left with
	// its tip at column 7, row 10, on the body. Frame 4, from frame 3: the
	// tip of the beak leaves the body, and a feather at its left lifts.
	{.Preen, 1, 14, 0, '.'},
	{.Preen, 1, 15, 0, '.'},
	{.Preen, 1, 15, 1, '.'},
	{.Preen, 1, 16, 1, '.'},
	{.Preen, 1, 17, 1, '.'},
	{.Preen, 1, 18, 1, '.'},
	{.Preen, 1, 14, 2, '.'},
	{.Preen, 1, 15, 2, '.'},
	{.Preen, 1, 16, 2, '.'},
	{.Preen, 1, 17, 2, '.'},
	{.Preen, 1, 18, 2, '.'},
	{.Preen, 1, 19, 2, '.'},
	{.Preen, 1, 20, 2, '.'},
	{.Preen, 1, 21, 2, '.'},
	{.Preen, 1, 22, 2, '.'},
	{.Preen, 1, 23, 2, '.'},
	{.Preen, 1, 13, 3, 'v'},
	{.Preen, 1, 14, 3, 'v'},
	{.Preen, 1, 15, 3, '.'},
	{.Preen, 1, 16, 3, '.'},
	{.Preen, 1, 17, 3, '.'},
	{.Preen, 1, 18, 3, '.'},
	{.Preen, 1, 19, 3, '.'},
	{.Preen, 1, 20, 3, '.'},
	{.Preen, 1, 21, 3, '.'},
	{.Preen, 1, 14, 4, 'h'},
	{.Preen, 1, 17, 4, 'h'},
	{.Preen, 1, 13, 5, 'h'},
	{.Preen, 1, 14, 5, 'h'},
	{.Preen, 1, 16, 5, 'k'},
	{.Preen, 1, 17, 5, 'h'},
	{.Preen, 1, 18, 5, 'y'},
	{.Preen, 1, 19, 5, 'y'},
	{.Preen, 1, 20, 5, 'y'},
	{.Preen, 1, 21, 5, 'y'},
	{.Preen, 1, 22, 5, 'y'},
	{.Preen, 1, 16, 6, 'h'},
	{.Preen, 1, 17, 6, 'h'},
	{.Preen, 1, 18, 6, 'y'},
	{.Preen, 1, 19, 6, 'y'},
	{.Preen, 1, 20, 6, 'y'},
	{.Preen, 1, 13, 7, '.'},
	{.Preen, 1, 15, 7, 'h'},
	{.Preen, 2, 13, 3, '.'},
	{.Preen, 2, 14, 3, '.'},
	{.Preen, 2, 14, 4, '.'},
	{.Preen, 2, 15, 4, 'v'},
	{.Preen, 2, 16, 4, 'v'},
	{.Preen, 2, 17, 4, '.'},
	{.Preen, 2, 12, 5, 'h'},
	{.Preen, 2, 16, 5, '.'},
	{.Preen, 2, 17, 5, '.'},
	{.Preen, 2, 18, 5, '.'},
	{.Preen, 2, 19, 5, '.'},
	{.Preen, 2, 20, 5, '.'},
	{.Preen, 2, 21, 5, '.'},
	{.Preen, 2, 22, 5, '.'},
	{.Preen, 2, 7, 6, 'y'},
	{.Preen, 2, 8, 6, 'y'},
	{.Preen, 2, 9, 6, 'y'},
	{.Preen, 2, 10, 6, 'y'},
	{.Preen, 2, 11, 6, 'h'},
	{.Preen, 2, 12, 6, 'k'},
	{.Preen, 2, 13, 6, 'h'},
	{.Preen, 2, 16, 6, '.'},
	{.Preen, 2, 17, 6, '.'},
	{.Preen, 2, 18, 6, '.'},
	{.Preen, 2, 19, 6, '.'},
	{.Preen, 2, 20, 6, '.'},
	{.Preen, 2, 9, 7, 'y'},
	{.Preen, 2, 10, 7, 'y'},
	{.Preen, 2, 11, 7, 'y'},
	{.Preen, 2, 12, 7, 'h'},
	{.Preen, 2, 13, 7, 'h'},
	{.Preen, 2, 13, 8, '.'},
	{.Preen, 2, 15, 8, 'h'},
	{.Preen, 3, 15, 4, '.'},
	{.Preen, 3, 16, 4, '.'},
	{.Preen, 3, 12, 5, '.'},
	{.Preen, 3, 13, 5, '.'},
	{.Preen, 3, 14, 5, '.'},
	{.Preen, 3, 15, 5, '.'},
	{.Preen, 3, 7, 6, '.'},
	{.Preen, 3, 8, 6, '.'},
	{.Preen, 3, 9, 6, '.'},
	{.Preen, 3, 10, 6, '.'},
	{.Preen, 3, 11, 6, '.'},
	{.Preen, 3, 12, 6, '.'},
	{.Preen, 3, 13, 6, '.'},
	{.Preen, 3, 14, 6, '.'},
	{.Preen, 3, 15, 6, '.'},
	{.Preen, 3, 9, 7, '.'},
	{.Preen, 3, 10, 7, '.'},
	{.Preen, 3, 11, 7, '.'},
	{.Preen, 3, 12, 7, '.'},
	{.Preen, 3, 13, 7, '.'},
	{.Preen, 3, 14, 7, 'v'},
	{.Preen, 3, 15, 7, 'v'},
	{.Preen, 3, 11, 8, 'h'},
	{.Preen, 3, 12, 8, 'h'},
	{.Preen, 3, 13, 8, 'h'},
	{.Preen, 3, 9, 9, 'y'},
	{.Preen, 3, 10, 9, 'h'},
	{.Preen, 3, 11, 9, 'k'},
	{.Preen, 3, 12, 9, 'h'},
	{.Preen, 3, 13, 9, 'h'},
	{.Preen, 3, 7, 10, 'y'},
	{.Preen, 3, 8, 10, 'y'},
	{.Preen, 3, 9, 10, 'h'},
	{.Preen, 3, 10, 10, 'h'},
	{.Preen, 3, 11, 10, 'h'},
	{.Preen, 3, 12, 10, 'h'},
	{.Preen, 3, 13, 10, 'h'},
	{.Preen, 4, 6, 10, 'b'},
	{.Preen, 4, 7, 10, '.'},

	// Scratch: the raised leg is the leg with the knee at column 14, row 19,
	// and its foot at column 12, row 21. Frame 1: the knee in, as the frame
	// 2 of the leg animation. Frame 2: the leg reaches forward, its foot on
	// the row of the ground at the columns 14 and 15 (in the place of
	// water). Frame 3: the foot pulled back to the columns 13 and 14, and one
	// cell of water lifts behind it, at column 16. Frame 5, from frame 3:
	// the water lifts at column 17.
	{.Scratch, 1, 12, 18, 'o'},
	{.Scratch, 1, 13, 18, '.'},
	{.Scratch, 1, 13, 19, 'o'},
	{.Scratch, 1, 14, 19, '.'},
	{.Scratch, 1, 12, 20, 'o'},
	{.Scratch, 1, 13, 20, '.'},
	{.Scratch, 2, 13, 19, 'o'},
	{.Scratch, 2, 14, 19, '.'},
	{.Scratch, 2, 13, 20, '.'},
	{.Scratch, 2, 14, 20, 'o'},
	{.Scratch, 2, 12, 21, '.'},
	{.Scratch, 2, 14, 21, 'o'},
	{.Scratch, 2, 14, 22, 'o'},
	{.Scratch, 2, 15, 22, 'o'},
	{.Scratch, 3, 12, 18, 'o'},
	{.Scratch, 3, 13, 18, '.'},
	{.Scratch, 3, 13, 19, 'o'},
	{.Scratch, 3, 14, 19, '.'},
	{.Scratch, 3, 12, 21, '.'},
	{.Scratch, 3, 13, 21, 'o'},
	{.Scratch, 3, 16, 21, 't'},
	{.Scratch, 3, 13, 22, 'o'},
	{.Scratch, 3, 14, 22, 'o'},
	{.Scratch, 5, 16, 21, '.'},
	{.Scratch, 5, 17, 21, 't'},

	// Dash, frame 1, the wind-up: the knee in, as the frame 2 of the leg
	// animation.
	{.Dash, 1, 12, 18, 'o'},
	{.Dash, 1, 13, 18, '.'},
	{.Dash, 1, 13, 19, 'o'},
	{.Dash, 1, 14, 19, '.'},
	{.Dash, 1, 12, 20, 'o'},
	{.Dash, 1, 13, 20, '.'},
	// Frame 2, the legs apart: the standing leg goes back and up from its
	// hip (column 9, row 16) to a foot at the columns 5 and 6 of row 19; the
	// other leg goes forward from its hip (column 12, row 16) to a foot at
	// the columns 15 and 16 of row 19. No foot is in the water, so the water
	// closes. The lines of speed are in the color of the neck, behind the
	// head (row 3) and behind the neck (row 9).
	{.Dash, 2, 9, 17, '.'},
	{.Dash, 2, 9, 18, '.'},
	{.Dash, 2, 9, 19, '.'},
	{.Dash, 2, 9, 20, '.'},
	{.Dash, 2, 9, 21, '.'},
	{.Dash, 2, 8, 17, 'o'},
	{.Dash, 2, 7, 18, 'o'},
	{.Dash, 2, 6, 19, 'o'},
	{.Dash, 2, 5, 19, 'o'},
	{.Dash, 2, 12, 17, '.'},
	{.Dash, 2, 13, 18, '.'},
	{.Dash, 2, 14, 19, '.'},
	{.Dash, 2, 13, 20, '.'},
	{.Dash, 2, 12, 21, '.'},
	{.Dash, 2, 13, 17, 'o'},
	{.Dash, 2, 14, 18, 'o'},
	{.Dash, 2, 15, 19, 'o'},
	{.Dash, 2, 16, 19, 'o'},
	{.Dash, 2, 9, 22, 't'},
	{.Dash, 2, 10, 22, 't'},
	{.Dash, 2, 11, 22, 't'},
	{.Dash, 2, 5, 3, 'h'},
	{.Dash, 2, 6, 3, 'h'},
	{.Dash, 2, 7, 3, 'h'},
	{.Dash, 2, 8, 3, 'h'},
	{.Dash, 2, 9, 3, 'h'},
	{.Dash, 2, 10, 3, 'h'},
	{.Dash, 2, 2, 9, 'h'},
	{.Dash, 2, 3, 9, 'h'},
	{.Dash, 2, 4, 9, 'h'},
	{.Dash, 2, 5, 9, 'h'},
	{.Dash, 2, 6, 9, 'h'},
	// Frame 3, the legs together: each leg keeps its two upper cells and
	// has a short lower part toward the other leg. The lines of speed are
	// two cells from their place in the frame 2.
	{.Dash, 3, 9, 18, '.'},
	{.Dash, 3, 9, 19, '.'},
	{.Dash, 3, 9, 20, '.'},
	{.Dash, 3, 9, 21, '.'},
	{.Dash, 3, 10, 18, 'o'},
	{.Dash, 3, 13, 18, '.'},
	{.Dash, 3, 14, 19, '.'},
	{.Dash, 3, 13, 20, '.'},
	{.Dash, 3, 12, 21, '.'},
	{.Dash, 3, 11, 18, 'o'},
	{.Dash, 3, 9, 22, 't'},
	{.Dash, 3, 10, 22, 't'},
	{.Dash, 3, 11, 22, 't'},
	{.Dash, 3, 3, 3, 'h'},
	{.Dash, 3, 4, 3, 'h'},
	{.Dash, 3, 5, 3, 'h'},
	{.Dash, 3, 6, 3, 'h'},
	{.Dash, 3, 7, 3, 'h'},
	{.Dash, 3, 8, 3, 'h'},
	{.Dash, 3, 4, 9, 'h'},
	{.Dash, 3, 5, 9, 'h'},
	{.Dash, 3, 6, 9, 'h'},
	{.Dash, 3, 7, 9, 'h'},
	{.Dash, 3, 8, 9, 'h'},
	// Frame 16, the stop: the legs together as in the frame 3, with no line
	// of speed, and water lifts in front of the legs. No foot is in the
	// water yet: the place that plays the dash still moves the heron.
	// Frame 17: the heron stands, with one wave at each side.
	{.Dash, 16, 9, 18, '.'},
	{.Dash, 16, 9, 19, '.'},
	{.Dash, 16, 9, 20, '.'},
	{.Dash, 16, 9, 21, '.'},
	{.Dash, 16, 10, 18, 'o'},
	{.Dash, 16, 13, 18, '.'},
	{.Dash, 16, 14, 19, '.'},
	{.Dash, 16, 13, 20, '.'},
	{.Dash, 16, 12, 21, '.'},
	{.Dash, 16, 11, 18, 'o'},
	{.Dash, 16, 9, 22, 't'},
	{.Dash, 16, 10, 22, 't'},
	{.Dash, 16, 11, 22, 't'},
	{.Dash, 16, 13, 21, 't'},
	{.Dash, 16, 15, 21, 't'},
	{.Dash, 17, 6, 21, 't'},
	{.Dash, 17, 17, 21, 't'},

	// Hop, frame 1: the knee half in, as the frame 1 of the leg animation.
	// Frame 2: the standing foot leaves the water and is one row higher, at
	// the columns 10 and 11 of row 21; the water closes under it. Frames 3
	// and 4: the waves of the ripple.
	{.Hop, 1, 14, 19, '.'},
	{.Hop, 1, 13, 19, 'o'},
	{.Hop, 2, 9, 22, 't'},
	{.Hop, 2, 10, 22, 't'},
	{.Hop, 2, 11, 22, 't'},
	{.Hop, 2, 10, 21, 'o'},
	{.Hop, 2, 11, 21, 'o'},
	{.Hop, 3, 8, 21, 't'},
	{.Hop, 3, 13, 21, 't'},
	{.Hop, 4, 6, 21, 't'},
	{.Hop, 4, 15, 21, 't'},

	// Fish: a fish of two cells, in the color of the crest, jumps in front
	// of the legs, above the water: out at column 15, up to row 17 at the
	// columns 17 and 18, down at column 18. In the frames 2 to 4 the head
	// looks forward, as in the frame 1 of the look.
	{.Fish, 1, 15, 21, 'v'},
	{.Fish, 2, 14, 0, '.'},
	{.Fish, 2, 16, 0, 'v'},
	{.Fish, 2, 15, 1, '.'},
	{.Fish, 2, 19, 1, 'h'},
	{.Fish, 2, 14, 2, '.'},
	{.Fish, 2, 17, 2, 'h'},
	{.Fish, 2, 18, 2, 'k'},
	{.Fish, 2, 19, 2, 'h'},
	{.Fish, 2, 15, 3, '.'},
	{.Fish, 2, 19, 3, 'h'},
	{.Fish, 2, 22, 3, 'y'},
	{.Fish, 2, 16, 19, 'v'},
	{.Fish, 2, 17, 19, 'v'},
	{.Fish, 3, 16, 19, '.'},
	{.Fish, 3, 17, 19, '.'},
	{.Fish, 3, 17, 17, 'v'},
	{.Fish, 3, 18, 17, 'v'},
	{.Fish, 4, 17, 17, '.'},
	{.Fish, 4, 18, 17, '.'},
	{.Fish, 4, 18, 19, 'v'},
	{.Fish, 4, 19, 19, 'v'},
	{.Fish, 5, 18, 21, 'v'},
	{.Fish, 5, 17, 21, 't'},
	{.Fish, 5, 19, 21, 't'},
	{.Fish, 6, 16, 21, 't'},
	{.Fish, 6, 20, 21, 't'},

	// Doze: the eye closed in every frame. One cell in the color of the neck
	// behind the head, then a letter z of three by three cells above it,
	// then the letter three rows higher and three columns back, with one
	// cell where the first letter ended.
	{.Doze, 1, 17, 2, 'h'},
	{.Doze, 2, 11, 7, 'h'},
	{.Doze, 3, 8, 3, 'h'},
	{.Doze, 3, 9, 3, 'h'},
	{.Doze, 3, 10, 3, 'h'},
	{.Doze, 3, 9, 4, 'h'},
	{.Doze, 3, 8, 5, 'h'},
	{.Doze, 3, 9, 5, 'h'},
	{.Doze, 3, 10, 5, 'h'},
	{.Doze, 4, 5, 0, 'h'},
	{.Doze, 4, 6, 0, 'h'},
	{.Doze, 4, 7, 0, 'h'},
	{.Doze, 4, 6, 1, 'h'},
	{.Doze, 4, 5, 2, 'h'},
	{.Doze, 4, 6, 2, 'h'},
	{.Doze, 4, 7, 2, 'h'},
	{.Doze, 4, 10, 5, 'h'},

	// Stretch: the eye closed, then the crest one cell longer at the back.
	{.Stretch, 1, 17, 2, 'h'},
	{.Stretch, 2, 13, 0, 'v'},

	// Ruffle: the wind comes from the front. The crest moves one cell back;
	// then it is one cell longer, and one cell of the tail lifts.
	{.Ruffle, 1, 15, 0, '.'},
	{.Ruffle, 1, 13, 0, 'v'},
	{.Ruffle, 2, 12, 0, 'v'},
	{.Ruffle, 2, 0, 14, 'v'},

	// Wade: the raised leg goes straight down at column 12, with its foot in
	// the water at the columns 12 to 14; the standing leg is raised, its
	// knee behind it at column 7, row 19, and the water closes where its
	// foot was.
	{.Wade, 1, 13, 18, '.'},
	{.Wade, 1, 12, 18, 'o'},
	{.Wade, 1, 14, 19, '.'},
	{.Wade, 1, 12, 19, 'o'},
	{.Wade, 1, 13, 20, '.'},
	{.Wade, 1, 12, 20, 'o'},
	{.Wade, 1, 12, 22, 'o'},
	{.Wade, 1, 13, 22, 'o'},
	{.Wade, 1, 14, 22, 'o'},
	{.Wade, 1, 9, 18, '.'},
	{.Wade, 1, 8, 18, 'o'},
	{.Wade, 1, 9, 19, '.'},
	{.Wade, 1, 7, 19, 'o'},
	{.Wade, 1, 9, 20, '.'},
	{.Wade, 1, 8, 20, 'o'},
	{.Wade, 1, 9, 22, 't'},
	{.Wade, 1, 10, 22, 't'},
	{.Wade, 1, 11, 22, 't'},

	// Flap, frame 1: the cells of the wing on the body take the color of
	// the body, and the wing is above the back: four cells on row 10, three
	// on row 9. Frame 2: the wing is under the body instead, four cells on
	// row 16 and two on row 17, and the foot is out of the water, as in the
	// hop. Frame 3, from frame 1: the foot out of the water.
	{.Flap, 1, 7, 13, 'b'},
	{.Flap, 1, 8, 13, 'b'},
	{.Flap, 1, 9, 13, 'b'},
	{.Flap, 1, 10, 13, 'b'},
	{.Flap, 1, 11, 13, 'b'},
	{.Flap, 1, 12, 13, 'b'},
	{.Flap, 1, 8, 14, 'b'},
	{.Flap, 1, 9, 14, 'b'},
	{.Flap, 1, 10, 14, 'b'},
	{.Flap, 1, 11, 14, 'b'},
	{.Flap, 1, 7, 10, 'd'},
	{.Flap, 1, 8, 10, 'd'},
	{.Flap, 1, 9, 10, 'd'},
	{.Flap, 1, 10, 10, 'd'},
	{.Flap, 1, 6, 9, 'd'},
	{.Flap, 1, 7, 9, 'd'},
	{.Flap, 1, 8, 9, 'd'},
	{.Flap, 2, 7, 13, 'b'},
	{.Flap, 2, 8, 13, 'b'},
	{.Flap, 2, 9, 13, 'b'},
	{.Flap, 2, 10, 13, 'b'},
	{.Flap, 2, 11, 13, 'b'},
	{.Flap, 2, 12, 13, 'b'},
	{.Flap, 2, 8, 14, 'b'},
	{.Flap, 2, 9, 14, 'b'},
	{.Flap, 2, 10, 14, 'b'},
	{.Flap, 2, 11, 14, 'b'},
	{.Flap, 2, 5, 16, 'd'},
	{.Flap, 2, 6, 16, 'd'},
	{.Flap, 2, 7, 16, 'd'},
	{.Flap, 2, 8, 16, 'd'},
	{.Flap, 2, 6, 17, 'd'},
	{.Flap, 2, 7, 17, 'd'},
	{.Flap, 2, 9, 22, 't'},
	{.Flap, 2, 10, 22, 't'},
	{.Flap, 2, 11, 22, 't'},
	{.Flap, 2, 10, 21, 'o'},
	{.Flap, 2, 11, 21, 'o'},
	{.Flap, 3, 9, 22, 't'},
	{.Flap, 3, 10, 22, 't'},
	{.Flap, 3, 11, 22, 't'},
	{.Flap, 3, 10, 21, 'o'},
	{.Flap, 3, 11, 21, 'o'},
}

// The letter of each cell of the heron, by row, then by column.
Heron_Cells :: [HERON_GRID_SIZE][HERON_GRID_SIZE]u8

// still_cells gives the letters of the still heron.
still_cells :: proc "contextless" () -> (cells: Heron_Cells) {
	for row in 0 ..< HERON_GRID_SIZE {
		for column in 0 ..< HERON_GRID_SIZE {
			cells[row][column] = heron_rows[row][column]
		}
	}
	return
}

// animation_frame_count gives the count of the frames of an animation, the
// still heron not counted.
animation_frame_count :: proc "contextless" (animation: Animation) -> int {
	count := 0
	for row in animation_frames {
		if row.animation == animation {
			count += 1
		}
	}
	return count
}

// animation_frame gives the row of the frame number `frame` (1, 2, ...) of
// an animation.
animation_frame :: proc "contextless" (animation: Animation, frame: int) -> (row: Animation_Frame, found: bool) {
	for candidate in animation_frames {
		if candidate.animation == animation && int(candidate.frame) == frame {
			return candidate, true
		}
	}
	return {}, false
}

// animation_duration gives the time of all the frames of an animation, the
// still heron not counted.
animation_duration :: proc "contextless" (animation: Animation) -> int {
	total := 0
	for row in animation_frames {
		if row.animation == animation {
			total += int(row.duration_milliseconds)
		}
	}
	return total
}

// The deepest chain of base frames that animation_frame_cells follows. A
// base frame is an earlier frame, so a chain is shorter than the count of
// frames; the bound also ends a table that breaks that rule.
BASE_FRAME_DEPTH_LIMIT :: 8

// animation_frame_cells gives the cells of one frame of an animation: the
// frame 0 is the still heron. found is false for a frame that the animation
// does not have. A change outside the grid, or to a letter that is not a
// part, is not applied: the host tests refuse such a table.
animation_frame_cells :: proc "contextless" (animation: Animation, frame: int) -> (cells: Heron_Cells, found: bool) {
	// The chain of frames from this one down to the still heron.
	chain: [BASE_FRAME_DEPTH_LIMIT]int
	depth := 0
	number := frame
	for number != 0 {
		row, row_found := animation_frame(animation, number)
		if !row_found || depth == BASE_FRAME_DEPTH_LIMIT || int(row.base_frame) >= number {
			return {}, false
		}
		chain[depth] = number
		depth += 1
		number = int(row.base_frame)
	}
	cells = still_cells()
	// From the frame nearest the still heron up to the asked frame.
	for level := depth - 1; level >= 0; level -= 1 {
		for change in animation_changes {
			if change.animation != animation || int(change.frame) != chain[level] {
				continue
			}
			_, is_part := part_of_letter(change.letter)
			if int(change.column) >= HERON_GRID_SIZE || int(change.row) >= HERON_GRID_SIZE || (change.letter != '.' && !is_part) {
				continue
			}
			cells[change.row][change.column] = change.letter
		}
	}
	return cells, true
}

// cells_differ_count gives the count of the cells that two frames do not
// share.
cells_differ_count :: proc "contextless" (first, second: ^Heron_Cells) -> int {
	count := 0
	for row in 0 ..< HERON_GRID_SIZE {
		for column in 0 ..< HERON_GRID_SIZE {
			if first[row][column] != second[row][column] {
				count += 1
			}
		}
	}
	return count
}

// cells_pixel gives the color of the pixel (x, y) of a frame of the heron,
// as mark_pixel does for the still heron: the same cell sizes, the same
// colors and gradients.
cells_pixel :: proc "contextless" (cells: ^Heron_Cells, cell_size, x, y: int, on_light: bool) -> (color: u32, covered: bool) {
	if !cell_size_is_accepted(cell_size) || x < 0 || y < 0 || x >= heron_size(cell_size) || y >= heron_size(cell_size) {
		return 0, false
	}
	index, found := part_of_letter(cells[y / cell_size][x / cell_size])
	if !found {
		return 0, false
	}
	return part_pixel(index, cell_size, x, y, on_light), true
}

// cells_draw draws a frame of the heron into a canvas, as mark_draw draws
// the still heron: the covered pixels only, nothing outside the canvas.
cells_draw :: proc "contextless" (canvas: graphics.Canvas, cells: ^Heron_Cells, x, y, cell_size: int, on_light: bool, order := Channel_Order.Red_In_High_Byte) {
	size := heron_size(cell_size)
	first_x, first_y, last_x, last_y, inside := place_in_canvas(canvas, x, y, size, size)
	if !inside {
		return
	}
	for canvas_y in first_y ..< last_y {
		for canvas_x in first_x ..< last_x {
			if color, covered := cells_pixel(cells, cell_size, canvas_x - x, canvas_y - y, on_light); covered {
				canvas.pixels[canvas_y * canvas.stride + canvas_x] = color_in_order(color, order)
			}
		}
	}
}
