// Which animation of the mark plays next on the home of the site, and how
// long the heron is still before it (docs/SITE.md, "The rhythm of the
// animations"). How the heron moves on the page during an animation is in
// mark_tile_map.odin.
//
// The rule of the choice is written two times: here, as a model that the
// host tests run, and in mark_animation.js, which the page runs. The two
// stay in agreement by one list: the tool runs the model with a generator
// of a fixed seed and writes the steps into the table of the script, and
// the self test of the script (?selftest=1) runs its own rule with the same
// generator and compares each step.
package kerneltool

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
