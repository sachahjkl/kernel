package kerneltool

import "core:strings"
import "core:testing"
import "core:time"

// The name of a picture of a film is the time when the tool asked for it,
// and the time is read back from the name: the encoder gets the real time
// of each picture.
@(test)
the_name_of_a_film_picture_is_its_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, film_picture_name(0), "0000000000.ppm")
	testing.expect_value(t, film_picture_name(1500 * time.Millisecond), "0001500000.ppm")
	// A part of a microsecond is rounded up: the name never puts a picture
	// in the slot before its own.
	testing.expect_value(t, film_picture_name(33_333_334 * time.Nanosecond), "0000033334.ppm")
	// The order of the names is the order of the times.
	testing.expect(t, film_picture_name(9 * time.Second) < film_picture_name(10 * time.Second), "a later picture has a later name")

	since_start, timed := film_picture_time("build/films/palette/0001500000.ppm")
	testing.expect(t, timed, "a path that ends with the name of a picture has a time")
	testing.expect_value(t, since_start, 1500 * time.Millisecond)
	for other in ([]string{"build/films/palette/pictures.ffconcat", ".ppm", "12a4.ppm", "-0000001500.ppm", "0001500000.png"}) {
		_, other_timed := film_picture_time(other)
		testing.expectf(t, !other_timed, "%s is not a picture of a film", other)
	}

	// The first time of a slot is in that slot, and so is the time of its name.
	for slot in 0 ..< 2000 {
		start := film_slot_start(slot)
		testing.expect_value(t, film_slot_of(start), slot)
		named, named_timed := film_picture_time(film_picture_name(start))
		testing.expect(t, named_timed, "the name of a picture has a time")
		testing.expect_value(t, film_slot_of(named), slot)
	}
}

// Each slot of a film shows the newest picture of its time. A picture
// that came late, and a picture that is missing, leave slots that show the
// picture before: the pictures after them keep their own times.
@(test)
the_frame_list_of_a_film_keeps_the_time_of_each_picture :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	millisecond :: time.Millisecond

	// Each picture on time: one slot each.
	on_time := film_runs([]time.Duration{0, 34 * millisecond, 67 * millisecond, 101 * millisecond})
	testing.expect_value(t, len(on_time), 4)
	for film_run, place in on_time {
		testing.expect_value(t, film_run, Film_Run{picture = place, first_slot = place, slot_count = 1})
	}
	testing.expect_value(t, film_slot_count(on_time), 4)

	// The third picture came 73 ms late: the slots 2 and 3 have no picture
	// of their own and show the second one, and the two last pictures are
	// in the slots of their times.
	late := film_runs([]time.Duration{0, 34 * millisecond, 140 * millisecond, 170 * millisecond})
	testing.expect_value(t, len(late), 4)
	if len(late) == 4 {
		testing.expect_value(t, late[0], Film_Run{picture = 0, first_slot = 0, slot_count = 1})
		testing.expect_value(t, late[1], Film_Run{picture = 1, first_slot = 1, slot_count = 3})
		testing.expect_value(t, late[2], Film_Run{picture = 2, first_slot = 4, slot_count = 1})
		testing.expect_value(t, late[3], Film_Run{picture = 3, first_slot = 5, slot_count = 1})
	}
	testing.expect_value(t, film_slot_count(late), 6)

	// The first slots have no picture: the film starts with its first one.
	no_first := film_runs([]time.Duration{70 * millisecond, 101 * millisecond})
	testing.expect_value(t, len(no_first), 2)
	if len(no_first) == 2 {
		testing.expect_value(t, no_first[0], Film_Run{picture = 0, first_slot = 0, slot_count = 3})
		testing.expect_value(t, no_first[1], Film_Run{picture = 1, first_slot = 3, slot_count = 1})
	}

	// Two pictures in one slot: the newer one is shown.
	same_slot := film_runs([]time.Duration{0, 10 * millisecond, 40 * millisecond})
	testing.expect_value(t, len(same_slot), 2)
	if len(same_slot) == 2 {
		testing.expect_value(t, same_slot[0], Film_Run{picture = 1, first_slot = 0, slot_count = 1})
		testing.expect_value(t, same_slot[1], Film_Run{picture = 2, first_slot = 1, slot_count = 1})
	}

	// No picture: no run, no slot.
	none := film_runs(nil)
	testing.expect_value(t, len(none), 0)
	testing.expect_value(t, film_slot_count(none), 0)

	// The list of the encoder: the time of each run, to the microsecond,
	// with no rounding that adds from run to run.
	text := film_list_text([]string{"a.ppm", "b.ppm", "c.ppm", "d.ppm"}, late)
	testing.expect_value(t, text, "ffconcat version 1.0\nfile 'a.ppm'\nduration 0.033333\nfile 'b.ppm'\nduration 0.100000\nfile 'c.ppm'\nduration 0.033334\nfile 'd.ppm'\nduration 0.033333\n")
}

// The typing of a film is drawn from a seed: the same seed gives the same
// times, and each period is near the middle period.
@(test)
the_typing_of_a_film_is_the_same_for_the_same_seed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	first := film_key_periods(32, FILM_TYPING_SEED)
	again := film_key_periods(32, FILM_TYPING_SEED)
	other := film_key_periods(32, FILM_TYPING_SEED + 1)
	testing.expect_value(t, len(first), 32)
	same_as_again, same_as_other, all_equal := true, true, true
	for period, place in first {
		same_as_again = same_as_again && period == again[place]
		same_as_other = same_as_other && period == other[place]
		all_equal = all_equal && period == first[0]
		testing.expectf(t, period >= (FILM_KEY_PERIOD_MILLISECONDS - FILM_KEY_VARIATION_MILLISECONDS) * time.Millisecond && period <= (FILM_KEY_PERIOD_MILLISECONDS + FILM_KEY_VARIATION_MILLISECONDS) * time.Millisecond, "the period %v after the key %d is within the variation", period, place)
	}
	testing.expect(t, same_as_again, "the same seed gives the same periods")
	testing.expect(t, !same_as_other, "another seed gives other periods")
	testing.expect(t, !all_equal, "the periods vary")
	testing.expect_value(t, len(film_key_periods(0, FILM_TYPING_SEED)), 0)
}

// The command of the encoder of the MP4 file: the rate of the film, each
// pixel doubled with no filter, H.264 with the pixel format that each
// player reads.
@(test)
the_encoder_of_a_film_doubles_each_pixel_with_no_filter :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	command := film_mp4_encode_command("build/films/palette/pictures.ffconcat", "build/films/palette.mp4")
	joined := strings.join(command, " ", context.temp_allocator)
	testing.expect_value(t, command[0], "ffmpeg")
	testing.expect_value(t, command[len(command) - 1], "build/films/palette.mp4")
	for part in ([]string{"-f concat", "-i build/films/palette/pictures.ffconcat", "fps=30,scale=iw*2:ih*2:flags=neighbor", "-c:v libx264", "-movflags +faststart", "-pix_fmt yuv420p"}) {
		testing.expectf(t, strings.contains(joined, part), "the command of the encoder has \"%s\": %s", part, joined)
	}
	testing.expect(t, !strings.contains(joined, "libsvtav1"), "the MP4 file is not AV1")
}

// The command of the encoder of the WebM file: the same list of timed
// pictures and the same doubled pixels as the MP4 file, AV1, no sound.
@(test)
the_encoder_of_the_film_of_a_document_is_av1_from_the_same_pictures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	command := film_webm_encode_command("build/films/palette/pictures.ffconcat", "build/films/palette.webm")
	joined := strings.join(command, " ", context.temp_allocator)
	testing.expect_value(t, command[0], "ffmpeg")
	testing.expect_value(t, command[len(command) - 1], "build/films/palette.webm")
	for part in ([]string{"-f concat", "-i build/films/palette/pictures.ffconcat", "fps=30,scale=iw*2:ih*2:flags=neighbor", "-c:v libsvtav1", "-preset 6", "-crf 45", "-an", "-pix_fmt yuv420p", "-colorspace bt709"}) {
		testing.expectf(t, strings.contains(joined, part), "the command of the encoder has \"%s\": %s", part, joined)
	}
	testing.expect(t, !strings.contains(joined, "libx264") && !strings.contains(joined, "faststart"), "the WebM file has no argument of the MP4 file")
	// The two commands differ by the arguments of their encoder and by
	// their output only: the head, up to the filter, is the same.
	other := film_mp4_encode_command("build/films/palette/pictures.ffconcat", "build/films/palette.mp4")
	for part, place in other[:12] {
		testing.expect_value(t, command[place], part)
	}
	testing.expect_value(t, film_document_path("palette"), "docs/films/palette.webm")
}

@(private = "file")
step_is_of_a_film :: proc(kind: Step_Kind) -> bool {
	#partial switch kind {
	case .Film_Start, .Film_Stop, .Film_Type, .Film_Hold:
		return true
	}
	return false
}

// The fixed times exist only in a film: no scenario of a test has a step
// of a film. Each film starts its worker under its own name, before its
// first fixed time, and stops it.
@(test)
only_the_scenario_of_a_film_has_fixed_times :: proc(t: ^testing.T) {
	for steps in ([][]Step{scenario[:], scenario_fails[:], scenario_network[:], scenario_measure[:], scenario_shortage[:], scenario_tcp[:], scenario_tcp_real[:], scenario_quic[:], scenario_quic_real[:], scenario_persist_first[:], scenario_persist_second[:]}) {
		for step, index in steps {
			testing.expectf(t, !step_is_of_a_film(step.kind), "the step %d of a scenario of a test is %v, a step of a film", index + 1, step.kind)
		}
	}
	for name in ([]string{"terminal", "palette"}) {
		film, found := film_of_name(name)
		testing.expectf(t, found, "the film %s is a film of the tool", name)
		started, stopped := false, false
		for step in film.steps {
			#partial switch step.kind {
			case .Film_Start:
				testing.expectf(t, !started, "the film %s starts one time", name)
				testing.expect_value(t, step.text, name)
				started = true
			case .Film_Stop:
				testing.expectf(t, started && !stopped, "the film %s stops after its start, one time", name)
				stopped = true
			case .Film_Type, .Film_Hold:
				testing.expectf(t, started && !stopped, "a fixed time of the film %s is between its start and its stop", name)
			}
			if step.kind == .Film_Hold {
				testing.expectf(t, step.milliseconds > 0, "a hold of the film %s has a time", name)
			}
		}
		testing.expectf(t, started && stopped, "the film %s has a start and a stop", name)
		testing.expect_value(t, remote_key_problem(film.steps), "")
	}
	_, found := film_of_name("a film that the tool does not make")
	testing.expect(t, !found, "a name with no film is refused")
}
