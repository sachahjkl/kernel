// Which animation of the mark plays next on the home of the site, how long
// the heron is still before it (docs/SITE.md, "The rhythm of the
// animations"), and how the heron moves on the page during an animation
// (docs/SITE.md, "The moves of the heron").
//
// The rule of the choice is written two times: here, as a model that the
// host tests run, and in mark_animation.js, which the page runs. The two
// stay in agreement by one list: the tool runs the model with a generator
// of a fixed seed and writes the steps into the table of the script, and
// the self test of the script (?selftest=1) runs its own rule with the same
// generator and compares each step.
package kerneltool

import "core:fmt"
import "support:mark"

// The part of the time that the heron is still, over a long play, in
// percent.
SITE_MARK_STILL_SHARE_PERCENT :: 40

SITE_MARK_ANIMATION_COUNT :: len(mark.Animation)
// The played animations are one bit each in a whole number that a script
// of a browser keeps exact; and an animation never follows itself only
// when there is another one.
#assert(SITE_MARK_ANIMATION_COUNT >= 2 && SITE_MARK_ANIMATION_COUNT <= 30)

// The memory of the choice: the animations that were played since the
// memory was last empty, one bit for each, and the animation played last
// (-1: none yet).
Site_Mark_Memory :: struct {
	played: u32,
	last:   int,
}

SITE_MARK_MEMORY_EMPTY :: Site_Mark_Memory{played = 0, last = -1}

// A source of whole numbers with a seed, for the model and for the self
// test of the script: the same seed gives the same numbers in both. The
// page itself takes its numbers from the browser.
Site_Mark_Generator :: struct {
	state: u32,
}

SITE_MARK_GENERATOR_MULTIPLIER :: 1664525
SITE_MARK_GENERATOR_INCREMENT :: 1013904223

// site_mark_generator_below gives the next number of the generator, from 0
// to bound - 1. The product wraps at 32 bits, as Math.imul in the script.
site_mark_generator_below :: proc(generator: ^Site_Mark_Generator, bound: int) -> int {
	generator.state = generator.state * SITE_MARK_GENERATOR_MULTIPLIER + SITE_MARK_GENERATOR_INCREMENT
	return int((generator.state >> 16) % u32(bound))
}

// site_mark_next_animation chooses the animation to play: one of those
// that the memory does not hold, each with the same chance. When the memory
// holds every animation, it is emptied first; the animation played last is
// then left out of the choice, so no animation follows itself.
site_mark_next_animation :: proc(memory: ^Site_Mark_Memory, generator: ^Site_Mark_Generator) -> int {
	every := (u32(1) << SITE_MARK_ANIMATION_COUNT) - 1
	if (memory.played & every) == every {
		memory.played = 0
	}
	open: [SITE_MARK_ANIMATION_COUNT]int
	open_count := 0
	for index in 0 ..< SITE_MARK_ANIMATION_COUNT {
		if (memory.played & (u32(1) << uint(index))) == 0 && index != memory.last {
			open[open_count] = index
			open_count += 1
		}
	}
	pick := 0
	if open_count > 0 {
		pick = open[site_mark_generator_below(generator, open_count)]
	}
	memory.played |= u32(1) << uint(pick)
	memory.last = pick
	return pick
}

// site_mark_animations_duration gives the time of all the animations, each
// played once: the moving time of one round of the memory.
site_mark_animations_duration :: proc() -> int {
	total := 0
	for animation in mark.Animation {
		total += mark.animation_duration(animation)
	}
	return total
}

// site_mark_still_bounds gives the shortest and the longest still time.
// The mean still time is the mean time of an animation times the still
// share over the moving share, so that the heron is still for the still
// share of a long play. A still time is a whole number of milliseconds
// from half the mean to one and a half times the mean, each with the same
// chance: the mean of the still times is the mean still time.
site_mark_still_bounds :: proc() -> (least, most: int) {
	mean := site_mark_animations_duration() * SITE_MARK_STILL_SHARE_PERCENT / ((100 - SITE_MARK_STILL_SHARE_PERCENT) * SITE_MARK_ANIMATION_COUNT)
	return mean - mean / 2, mean + mean / 2
}

// site_mark_still_time chooses the still time before an animation.
site_mark_still_time :: proc(generator: ^Site_Mark_Generator) -> int {
	least, most := site_mark_still_bounds()
	return least + site_mark_generator_below(generator, most - least + 1)
}

// One step of the play: the heron is still, then one animation plays.
Site_Mark_Step :: struct {
	still_milliseconds: int,
	animation:          int,
}

// site_mark_step gives the next step: the still time is chosen first, then
// the animation, as the page does.
site_mark_step :: proc(memory: ^Site_Mark_Memory, generator: ^Site_Mark_Generator) -> Site_Mark_Step {
	still := site_mark_still_time(generator)
	return Site_Mark_Step{still_milliseconds = still, animation = site_mark_next_animation(memory, generator)}
}

// The list that keeps the script in agreement with the model: the first
// steps of a play that starts with an empty memory, with this seed. Two
// rounds of the memory and three steps of the third: the list crosses the
// place where the memory is emptied two times.
SITE_MARK_CHECK_SEED :: 20261114
SITE_MARK_CHECK_STEP_COUNT :: 2 * SITE_MARK_ANIMATION_COUNT + 3

site_mark_check_steps :: proc() -> []Site_Mark_Step {
	steps := make([]Site_Mark_Step, SITE_MARK_CHECK_STEP_COUNT, context.temp_allocator)
	memory := SITE_MARK_MEMORY_EMPTY
	generator := Site_Mark_Generator{SITE_MARK_CHECK_SEED}
	for &step in steps {
		step = site_mark_step(&memory, &generator)
	}
	return steps
}

// The moves of the heron. An animation of support/mark changes cells; on
// the home some animations also move and scale the picture of the heron:
// the dash crosses the window, the hop and the flap lift, and a landing
// squashes. The two rows of the water never move: the page cuts the
// picture at the line of the water, and only the part above it follows a
// move.

// Where a move puts the heron across the window of the browser.
Site_Mark_Edge :: enum {
	None, // In its place, plus the cells of the key.
	Past_Right, // Wholly outside the window, past its right edge.
	Past_Left, // Wholly outside the window, past its left edge.
}

// How the heron goes from a key to the next one. The order is the order of
// the table of the script.
Site_Mark_Ease :: enum {
	Even, // At one speed.
	Slow_At_End, // Fast first, then slower.
	Slow_At_Start, // Slow first, then faster.
	Hold, // It stays as the key says, then is at the next key at once.
}

// The count of the rows of the water, at the bottom of the grid, which no
// move takes with it.
SITE_MARK_WATER_ROWS :: 2

// One key of a move: at a time from the start of the animation, the place
// and the size of the part of the heron above the water. The size is in
// percent of its own, from the middle of its bottom edge: the heron
// squashes onto the line of the water.
Site_Mark_Motion_Key :: struct {
	animation:       mark.Animation,
	at_milliseconds: int,
	cells_right:     int, // Cells of the picture toward the right; negative: toward the left.
	cells_up:        int, // Cells of the picture upward.
	edge:            Site_Mark_Edge,
	width_percent:   int,
	height_percent:  int,
	ease:            Site_Mark_Ease, // From this key to the next one.
}

// The keys of each animation that moves, in the order of time. The first
// key is at 0 and the last at the end of the animation, and both are the
// heron in its place at its size. While a foot is in the water, no key
// moves the heron: only its size changes.
//
// The dash: the heron squashes for the wind-up, leaves to the right faster
// and faster, stretched along its way, and is past the right edge when the
// fifth step of the run ends. It stays outside for four steps, then is past
// the left edge at once and comes in at one speed, goes three cells past
// its place, squashes there against its own speed, slides back, and stands.
site_mark_motion_keys := [?]Site_Mark_Motion_Key {
	{.Dash, 0, 0, 0, .None, 100, 100, .Slow_At_End},
	{.Dash, 260, 0, 0, .None, 116, 86, .Even},
	{.Dash, 380, 0, 0, .None, 116, 86, .Slow_At_Start},
	{.Dash, 730, 0, 0, .Past_Right, 135, 80, .Hold},
	{.Dash, 1010, 0, 0, .Past_Left, 135, 80, .Even},
	{.Dash, 1360, 3, 0, .None, 135, 80, .Slow_At_End},
	{.Dash, 1460, 3, 0, .None, 82, 114, .Slow_At_End},
	{.Dash, 1580, 0, 0, .None, 100, 100, .Slow_At_End},
	{.Dash, 1660, 0, 0, .None, 106, 96, .Slow_At_End},
	{.Dash, 1780, 0, 0, .None, 100, 100, .Even},
	// The hop: a squash, four cells up and thinner, down, a squash on the
	// water.
	{.Hop, 0, 0, 0, .None, 100, 100, .Slow_At_End},
	{.Hop, 180, 0, 0, .None, 112, 86, .Slow_At_End},
	{.Hop, 340, 0, 4, .None, 92, 110, .Slow_At_Start},
	{.Hop, 500, 0, 0, .None, 94, 106, .Slow_At_End},
	{.Hop, 600, 0, 0, .None, 114, 86, .Slow_At_End},
	{.Hop, 880, 0, 0, .None, 100, 100, .Even},
	// The stretch: taller and thinner, held, then a shake of its width.
	{.Stretch, 0, 0, 0, .None, 100, 100, .Slow_At_End},
	{.Stretch, 300, 0, 0, .None, 94, 112, .Even},
	{.Stretch, 620, 0, 0, .None, 94, 112, .Even},
	{.Stretch, 700, 0, 0, .None, 106, 98, .Even},
	{.Stretch, 780, 0, 0, .None, 96, 102, .Even},
	{.Stretch, 860, 0, 0, .None, 104, 98, .Even},
	{.Stretch, 940, 0, 0, .None, 98, 101, .Even},
	{.Stretch, 1100, 0, 0, .None, 100, 100, .Even},
	// The flap: three cells up while the wing beats, down, a small squash.
	{.Flap, 0, 0, 0, .None, 100, 100, .Even},
	{.Flap, 200, 0, 0, .None, 100, 100, .Slow_At_End},
	{.Flap, 420, 0, 3, .None, 100, 100, .Even},
	{.Flap, 650, 0, 3, .None, 100, 100, .Slow_At_Start},
	{.Flap, 800, 0, 0, .None, 100, 100, .Slow_At_End},
	{.Flap, 880, 0, 0, .None, 108, 92, .Slow_At_End},
	{.Flap, 1000, 0, 0, .None, 100, 100, .Even},
}

// The bounds of a size of a move, in percent: past them the cells of the
// heron no longer read as squares.
SITE_MARK_MOTION_SIZE_LEAST :: 75
SITE_MARK_MOTION_SIZE_MOST :: 140

// site_mark_motion_key_moves tells whether a key puts the heron out of its
// place.
site_mark_motion_key_moves :: proc(key: Site_Mark_Motion_Key) -> bool {
	return key.cells_right != 0 || key.cells_up != 0 || key.edge != .None
}

// site_mark_frame_has_foot_in_water tells whether a frame has a cell that
// is not water in the rows of the water: a foot, which stays with the water
// when the part above it moves.
site_mark_frame_has_foot_in_water :: proc(cells: ^mark.Heron_Cells) -> bool {
	for row in mark.HERON_GRID_SIZE - SITE_MARK_WATER_ROWS ..< mark.HERON_GRID_SIZE {
		for column in 0 ..< mark.HERON_GRID_SIZE {
			if cells[row][column] != '.' && cells[row][column] != 't' {
				return true
			}
		}
	}
	return false
}

// site_mark_motion_problems checks keys of moves against the frames of
// support/mark; an empty list is a table with no fault. The site checks
// site_mark_motion_keys; a test also gives a table with a fault.
site_mark_motion_problems :: proc(table: []Site_Mark_Motion_Key) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	for animation in mark.Animation {
		keys := make([dynamic]Site_Mark_Motion_Key, context.temp_allocator)
		for key in table {
			if key.animation == animation {
				append(&keys, key)
			}
		}
		if len(keys) == 0 {
			continue
		}
		name := mark.animation_names[animation]
		duration := mark.animation_duration(animation)
		first, last := keys[0], keys[len(keys) - 1]
		if len(keys) < 2 || first.at_milliseconds != 0 || last.at_milliseconds != duration {
			append(&problems, fmt.tprintf("%s: the keys of its move do not go from 0 to %d ms", name, duration))
			continue
		}
		if site_mark_motion_key_moves(first) || first.width_percent != 100 || first.height_percent != 100 || site_mark_motion_key_moves(last) || last.width_percent != 100 || last.height_percent != 100 {
			append(&problems, fmt.tprintf("%s: its move does not start and end at the heron in its place", name))
		}
		for key, index in keys {
			if index > 0 && key.at_milliseconds <= keys[index - 1].at_milliseconds {
				append(&problems, fmt.tprintf("%s: the key at %d ms is not later than the key before it", name, key.at_milliseconds))
			}
			if key.width_percent < SITE_MARK_MOTION_SIZE_LEAST || key.width_percent > SITE_MARK_MOTION_SIZE_MOST || key.height_percent < SITE_MARK_MOTION_SIZE_LEAST || key.height_percent > SITE_MARK_MOTION_SIZE_MOST {
				append(&problems, fmt.tprintf("%s: the size of the key at %d ms is outside its bounds", name, key.at_milliseconds))
			}
			// The heron is outside the window only between a key past an
			// edge and the next key: a key past the right edge holds, and
			// the next one is past the left edge.
			if key.edge == .Past_Right && (key.ease != .Hold || index + 1 >= len(keys) || keys[index + 1].edge != .Past_Left) {
				append(&problems, fmt.tprintf("%s: the key at %d ms is past the right edge and the next one is not past the left edge at once", name, key.at_milliseconds))
			}
			if key.edge == .Past_Left && (index == 0 || keys[index - 1].edge != .Past_Right) {
				append(&problems, fmt.tprintf("%s: the key at %d ms is past the left edge with no key past the right edge before it", name, key.at_milliseconds))
			}
		}
		// A frame with a foot in the water: from the key at or before its
		// start to the key at or after its end, no key moves the heron.
		start := 0
		for frame in 1 ..= mark.animation_frame_count(animation) {
			row, _ := mark.animation_frame(animation, frame)
			cells, _ := mark.animation_frame_cells(animation, frame)
			end := start + int(row.duration_milliseconds)
			if site_mark_frame_has_foot_in_water(&cells) {
				from, to := 0, duration
				for key in keys {
					if key.at_milliseconds <= start {
						from = key.at_milliseconds
					}
				}
				for index := len(keys) - 1; index >= 0; index -= 1 {
					if keys[index].at_milliseconds >= end {
						to = keys[index].at_milliseconds
					}
				}
				for key in keys {
					if key.at_milliseconds >= from && key.at_milliseconds <= to && site_mark_motion_key_moves(key) {
						append(&problems, fmt.tprintf("%s: the key at %d ms moves the heron while a foot is in the water", name, key.at_milliseconds))
					}
				}
			}
			start = end
		}
	}
	return problems[:]
}

// site_mark_animation_moves tells whether an animation has keys of a move.
site_mark_animation_moves :: proc(animation: mark.Animation) -> bool {
	for key in site_mark_motion_keys {
		if key.animation == animation {
			return true
		}
	}
	return false
}
