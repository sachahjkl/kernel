package mark

// The play of the animations of the heron: which animation plays next, how
// long the heron is still before it, and which frame an animation shows at
// a time (docs/DESIGN.md, "The animations"; docs/SITE.md, "The rhythm of
// the animations").
//
// The rule of the choice is here once, for each place that plays the
// animations: the kernel tool runs it as the model of the script of the
// site, and the program `heron` runs it in the system. Pure procedures: a
// caller gives the memory and the numbers of chance.

// The part of the time that the heron is still, over a long play, in
// percent.
STILL_SHARE_PERCENT :: 40

ANIMATION_COUNT :: len(Animation)
// The played animations are one bit each in a whole number that a script
// of a browser keeps exact; and an animation never follows itself only
// when there is another one.
#assert(ANIMATION_COUNT >= 2 && ANIMATION_COUNT <= 30)

// The memory of the choice: the animations that were played since the
// memory was last empty, one bit for each, and the animation played last
// (-1: none yet).
Order_Memory :: struct {
	played: u32, // One bit for each animation that was played in this round.
	last:   int, // The animation played last, or -1.
}

ORDER_MEMORY_EMPTY :: Order_Memory{played = 0, last = -1}

// A source of whole numbers with a seed, for a model and a test of the
// rule: the same seed gives the same numbers in the script of the site. A
// place that plays for a reader takes its numbers of chance elsewhere: the
// page from the browser, a program from its random generator.
Number_Generator :: struct {
	state: u32, // The seed, then the state after each number.
}

GENERATOR_MULTIPLIER :: 1664525
GENERATOR_INCREMENT :: 1013904223

// generator_next gives the next number of the generator: the upper 16 bits
// of its state. The product wraps at 32 bits, as Math.imul in the script.
generator_next :: proc "contextless" (generator: ^Number_Generator) -> u32 {
	generator.state = generator.state * GENERATOR_MULTIPLIER + GENERATOR_INCREMENT
	return generator.state >> 16
}

// next_animation chooses the animation to play: one of those that the
// memory does not hold, each with the same chance. When the memory holds
// every animation, it is emptied first; the animation played last is then
// left out of the choice, so no animation follows itself. chance is a whole
// number of chance: its remainder by the count of the open animations
// chooses one.
next_animation :: proc "contextless" (memory: ^Order_Memory, chance: u32) -> int {
	every := (u32(1) << ANIMATION_COUNT) - 1
	if (memory.played & every) == every {
		memory.played = 0
	}
	open: [ANIMATION_COUNT]int
	open_count := 0
	for index in 0 ..< ANIMATION_COUNT {
		if (memory.played & (u32(1) << uint(index))) == 0 && index != memory.last {
			open[open_count] = index
			open_count += 1
		}
	}
	pick := 0
	if open_count > 0 {
		pick = open[chance % u32(open_count)]
	}
	memory.played |= u32(1) << uint(pick)
	memory.last = pick
	return pick
}

// animations_duration gives the time of all the animations, each played
// once: the moving time of one round of the memory.
animations_duration :: proc "contextless" () -> int {
	total := 0
	for animation in Animation {
		total += animation_duration(animation)
	}
	return total
}

// still_bounds gives the shortest and the longest still time. The mean
// still time is the mean time of an animation times the still share over
// the moving share, so that the heron is still for the still share of a
// long play. A still time is a whole number of milliseconds from half the
// mean to one and a half times the mean, each with the same chance: the
// mean of the still times is the mean still time.
still_bounds :: proc "contextless" () -> (least, most: int) {
	mean := animations_duration() * STILL_SHARE_PERCENT / ((100 - STILL_SHARE_PERCENT) * ANIMATION_COUNT)
	return mean - mean / 2, mean + mean / 2
}

// still_time chooses the still time before an animation, from a whole
// number of chance.
still_time :: proc "contextless" (chance: u32) -> int {
	least, most := still_bounds()
	return least + int(chance % u32(most - least + 1))
}

// One step of the play: the heron is still, then one animation plays.
Play_Step :: struct {
	still_milliseconds: int, // How long the heron is still first.
	animation:          int, // The animation that plays then.
}

// play_step gives the next step of a play that takes its numbers from a
// generator: the still time is chosen first, then the animation, as the
// page of the site does.
play_step :: proc "contextless" (memory: ^Order_Memory, generator: ^Number_Generator) -> Play_Step {
	still := still_time(generator_next(generator))
	return Play_Step{still_milliseconds = still, animation = next_animation(memory, generator_next(generator))}
}

// animation_of_name gives the animation with a name of animation_names.
animation_of_name :: proc "contextless" (name: string) -> (animation: Animation, found: bool) {
	for candidate in Animation {
		if animation_names[candidate] == name {
			return candidate, true
		}
	}
	return .Blink, false
}

// animation_frame_start gives the time from the start of an animation at
// which its frame number `frame` (1, 2, ...) starts, in milliseconds. A
// frame past the last one gives the time of the whole animation.
animation_frame_start :: proc "contextless" (animation: Animation, frame: int) -> int {
	start := 0
	for row in animation_frames {
		if row.animation == animation && int(row.frame) < frame {
			start += int(row.duration_milliseconds)
		}
	}
	return start
}

// animation_frame_at gives the frame that an animation shows at a time
// from its start, in milliseconds: 1, 2, ... A time before the start gives
// the frame 0, the still heron. A time at or after the end of the last
// frame gives the frame 0 and ended: the heron is still again.
animation_frame_at :: proc "contextless" (animation: Animation, at_milliseconds: int) -> (frame: int, ended: bool) {
	if at_milliseconds < 0 {
		return 0, false
	}
	end := 0
	for row in animation_frames {
		if row.animation != animation {
			continue
		}
		end += int(row.duration_milliseconds)
		if at_milliseconds < end {
			return int(row.frame), false
		}
	}
	return 0, true
}
