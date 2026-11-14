// Which animation of the mark plays next on the home of the site, and how
// long the heron is still before it (docs/SITE.md, "The rhythm of the
// animations"). How the heron moves on the page during an animation is in
// mark_tile_map.odin.
//
// The rule of the choice and the still times are in src/library/support/mark
// (play.odin): the program `heron` of the system plays by the same rule.
// The rule is written a second time in mark_animation.js, which the page
// runs. The two stay in agreement by one list: the tool runs the rule of
// src/library/support/mark with a generator of a fixed seed and writes the steps into
// the table of the script, and the self test of the script (?selftest=1)
// runs its own rule with the same generator and compares each step.
package kerneltool

import "support:mark"

// The list that keeps the script in agreement with the rule: the first
// steps of a play that starts with an empty memory, with this seed. Two
// rounds of the memory and three steps of the third: the list crosses the
// place where the memory is emptied two times.
SITE_MARK_CHECK_SEED :: 20261114
SITE_MARK_CHECK_STEP_COUNT :: 2 * mark.ANIMATION_COUNT + 3

site_mark_check_steps :: proc() -> []mark.Play_Step {
	steps := make([]mark.Play_Step, SITE_MARK_CHECK_STEP_COUNT, context.temp_allocator)
	memory := mark.ORDER_MEMORY_EMPTY
	generator := mark.Number_Generator{SITE_MARK_CHECK_SEED}
	for &step in steps {
		step = mark.play_step(&memory, &generator)
	}
	return steps
}
