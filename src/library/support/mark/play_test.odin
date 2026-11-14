#+build !freestanding
package mark

import "core:testing"

// The rule of the choice: in each round of the memory each animation plays
// once; no animation follows itself, also from the end of a round to the
// start of the next one; the order is not the same in each round.
@(test)
choice_plays_each_animation_once_in_a_round :: proc(t: ^testing.T) {
	seeds := [?]u32{1, 2, 3, 20261114, 0xFFFFFFFF}
	for seed in seeds {
		memory := ORDER_MEMORY_EMPTY
		generator := Number_Generator{seed}
		previous := -1
		first_round: [ANIMATION_COUNT]int
		rounds_as_the_first := 0
		ROUNDS :: 400
		for round in 0 ..< ROUNDS {
			seen: u32
			as_the_first := true
			for place in 0 ..< ANIMATION_COUNT {
				animation := next_animation(&memory, generator_next(&generator))
				testing.expectf(t, animation >= 0 && animation < ANIMATION_COUNT, "the seed %d: the animation %d does not exist", seed, animation)
				testing.expectf(t, animation != previous, "the seed %d, round %d: the animation %d follows itself", seed, round, animation)
				testing.expectf(t, seen & (u32(1) << uint(animation)) == 0, "the seed %d, round %d: the animation %d plays two times", seed, round, animation)
				seen |= u32(1) << uint(animation)
				previous = animation
				testing.expect_value(t, memory.last, animation)
				if round == 0 {
					first_round[place] = animation
				} else if first_round[place] != animation {
					as_the_first = false
				}
			}
			testing.expect_value(t, seen, (u32(1) << ANIMATION_COUNT) - 1)
			testing.expect_value(t, memory.played, seen)
			if round > 0 && as_the_first {
				rounds_as_the_first += 1
			}
		}
		testing.expectf(t, rounds_as_the_first < ROUNDS / 100, "the seed %d: %d rounds have the order of the first round", seed, rounds_as_the_first)
	}
}

// The rule holds for each number of chance, not only for the numbers of
// the generator: a program gives numbers of 32 bits from its own random
// generator. The largest and the smallest numbers choose an animation that
// exists and that the memory did not hold.
@(test)
choice_takes_any_number_of_chance :: proc(t: ^testing.T) {
	chances := [?]u32{0, 1, 14, 15, 16, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF}
	for first_chance in chances {
		memory := ORDER_MEMORY_EMPTY
		previous := -1
		for step in 0 ..< 3 * ANIMATION_COUNT {
			held := memory.played
			full := held == (u32(1) << ANIMATION_COUNT) - 1
			animation := next_animation(&memory, first_chance + u32(step) * 2654435761)
			testing.expect(t, animation >= 0 && animation < ANIMATION_COUNT)
			testing.expect(t, animation != previous)
			testing.expect(t, full || held & (u32(1) << uint(animation)) == 0)
			previous = animation
		}
	}
}

// A memory that a place kept: the play goes on from it. The animations
// that it holds do not play before the others did.
@(test)
choice_goes_on_from_a_kept_memory :: proc(t: ^testing.T) {
	kept := Order_Memory{played = 0b0000_0000_0010_1101, last = 5}
	held := kept.played
	generator := Number_Generator{7}
	left := 0
	for index in 0 ..< ANIMATION_COUNT {
		if held & (u32(1) << uint(index)) == 0 {
			left += 1
		}
	}
	for _ in 0 ..< left {
		animation := next_animation(&kept, generator_next(&generator))
		testing.expectf(t, held & (u32(1) << uint(animation)) == 0, "the animation %d was in the memory", animation)
	}
	testing.expect_value(t, kept.played, (u32(1) << ANIMATION_COUNT) - 1)
	// The memory is full: the next choice empties it, and is not the
	// animation played last.
	last := kept.last
	animation := next_animation(&kept, generator_next(&generator))
	testing.expect(t, animation != last)
	testing.expect_value(t, kept.played, u32(1) << uint(animation))
}

// The still share: the bounds of a still time follow from the times of the
// animations, and over a long play the heron is still for the still share
// of the time, within one point.
@(test)
heron_is_still_for_its_share :: proc(t: ^testing.T) {
	least, most := still_bounds()
	total := animations_duration()
	testing.expect_value(t, total, 19310)
	testing.expect_value(t, least, 429)
	testing.expect_value(t, most, 1287)
	// The mean still time times the moving share is the mean time of an
	// animation times the still share, within the rounding of one
	// millisecond for each animation.
	mean_still := (least + most) / 2
	difference := mean_still * (100 - STILL_SHARE_PERCENT) * ANIMATION_COUNT - total * STILL_SHARE_PERCENT
	testing.expectf(t, abs(difference) <= (100 - STILL_SHARE_PERCENT) * ANIMATION_COUNT, "the mean still time %d ms is not the share of %d ms", mean_still, total)
	// Two animations never read as one: the shortest still time is several
	// of the shortest common frames.
	testing.expect(t, least >= 2 * FRAME_DURATION_LEAST)
	// Each number of chance gives a still time inside the bounds.
	for chance in ([]u32{0, 1, 858, 859, 0xFFFFFFFF}) {
		still := still_time(chance)
		testing.expectf(t, still >= least && still <= most, "the number %d gives a still time of %d ms", chance, still)
	}
	seeds := [?]u32{1, 2, 3, 20261114}
	for seed in seeds {
		memory := ORDER_MEMORY_EMPTY
		generator := Number_Generator{seed}
		still_total, moving_total := 0, 0
		for _ in 0 ..< 400 * ANIMATION_COUNT {
			step := play_step(&memory, &generator)
			testing.expectf(t, step.still_milliseconds >= least && step.still_milliseconds <= most, "a still time of %d ms", step.still_milliseconds)
			still_total += step.still_milliseconds
			moving_total += animation_duration(Animation(step.animation))
		}
		// In thousandths, so that the test has no fraction.
		share := 1000 * still_total / (still_total + moving_total)
		testing.expectf(t, share >= 10 * (STILL_SHARE_PERCENT - 1) && share <= 10 * (STILL_SHARE_PERCENT + 1), "the seed %d: the heron is still for %d thousandths of the time", seed, share)
	}
}

// The generator gives the numbers that the script of the site computes
// with Math.imul: the product wraps at 32 bits, and a number has 16 bits.
@(test)
generator_wraps_at_32_bits :: proc(t: ^testing.T) {
	generator := Number_Generator{0}
	first := generator_next(&generator)
	// 1013904223 is 0x3C6EF35F: its upper 16 bits are 0x3C6E.
	testing.expect_value(t, generator.state, u32(1013904223))
	testing.expect_value(t, first, u32(0x3C6E))
	testing.expect_value(t, GENERATOR_MULTIPLIER, 1664525)
	testing.expect_value(t, GENERATOR_INCREMENT, 1013904223)
	for _ in 0 ..< 1000 {
		testing.expect(t, generator_next(&generator) < 1 << 16)
	}
}

// The frame at a time of an animation: the frame 0 before the start, each
// frame from its start to the start of the next one, and the still heron
// with the end from the time of the whole animation.
@(test)
frame_at_a_time_follows_the_durations :: proc(t: ^testing.T) {
	for animation in Animation {
		frame, ended := animation_frame_at(animation, -1)
		testing.expect(t, frame == 0 && !ended)
		start := 0
		count := animation_frame_count(animation)
		for number in 1 ..= count {
			row, found := animation_frame(animation, number)
			testing.expect(t, found)
			testing.expect_value(t, animation_frame_start(animation, number), start)
			frame, ended = animation_frame_at(animation, start)
			testing.expectf(t, frame == number && !ended, "%v: the frame at %d ms is %d, not %d", animation, start, frame, number)
			last := start + int(row.duration_milliseconds) - 1
			frame, ended = animation_frame_at(animation, last)
			testing.expectf(t, frame == number && !ended, "%v: the frame at %d ms is %d, not %d", animation, last, frame, number)
			start += int(row.duration_milliseconds)
		}
		testing.expect_value(t, start, animation_duration(animation))
		testing.expect_value(t, animation_frame_start(animation, count + 1), start)
		frame, ended = animation_frame_at(animation, start)
		testing.expect(t, frame == 0 && ended)
		frame, ended = animation_frame_at(animation, start + 100_000)
		testing.expect(t, frame == 0 && ended)
	}
	// The dash: the wind-up of 380 ms, then steps of 70 ms.
	frame, _ := animation_frame_at(.Dash, 379)
	testing.expect_value(t, frame, 1)
	frame, _ = animation_frame_at(.Dash, 380)
	testing.expect_value(t, frame, 2)
	frame, _ = animation_frame_at(.Dash, 520)
	testing.expect_value(t, frame, 4)
	testing.expect_value(t, animation_frame_start(.Dash, 4), 520)
}

// A name of the table names its animation; another text names none.
@(test)
name_gives_its_animation :: proc(t: ^testing.T) {
	for animation in Animation {
		found_animation, found := animation_of_name(animation_names[animation])
		testing.expect(t, found && found_animation == animation)
	}
	_, found := animation_of_name("fly")
	testing.expect(t, !found)
	_, found = animation_of_name("")
	testing.expect(t, !found)
}
