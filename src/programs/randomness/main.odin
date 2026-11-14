// The randomness of the system, shown (docs/RANDOMNESS.md).
//
// The root service gathers the seed of the system at its start, from the
// sources of the processor, and gives this program the facts of that
// gathering (the values 0 to 7 of its context): which sources were there,
// how many values each one gave, how many it refused, and the strength
// that the seed can claim. Like each program, this one has its own
// generator, seeded by its starter (the values 9 to 12). The window shows
// both, a live draw of the stream, the counts of each byte value in 1 MiB,
// and the speed of the generator.
//
// **What it is for.** It shows where the random bytes of a program come
// from, and what the system claims of them: the strength of the seed is a
// fact that the root service measured, not a promise. A program that makes
// a key (`remote`, `quic_echo`, `unlock`) refuses a seed under the strength
// that it needs; this program shows that strength.
//
// **Start**: `start("randomness")` in the console, or the bar of the
// desktop. It has no grant of `grants_of`: the root service writes the
// facts of the seed into its context because of its name, and these are
// facts, not the seed.
//
// **What a reader sees**: the sources of the seed (rdseed, rdrand, the
// jitter of the cycle counter) with their counts, the strength, a live draw
// of the stream every 500 ms, the 16 bars of 1 MiB counted by the high 4
// bits of each byte, and the speed. The log has:
//
// - "randomness: the seed of the system: strength ...; the first bytes of
//   the stream of this program: ...";
// - "randomness: 1 MiB by the high 4 bits of each byte: from A to B in each
//   of 16 (the mean is 65536)";
// - "randomness: the generator: 4 MiB in T us, R MB/s".
//
// **What it does not prove**: even bars are no test of quality; a weak
// generator gives them too. The quality of the seed rests on the sources of
// the processor (docs/RANDOMNESS.md, section 3).
package randomness

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/random"
import "modus:support/system"

LINE :: interface.TABLE_LINE
WIDTH :: 896
HEIGHT :: 560
MEASURE_SIZE :: 4 << 20 // The bytes of the measure of the speed.
HISTOGRAM_SIZE :: 1 << 20 // The bytes whose values the window counts.

program_generator: random.Generator
report: random.Entropy_Report
first_bytes: [16]u8 // The first bytes of the stream of this program: the log has them, so a test compares two programs and two boots.
live_bytes: [32]u8 // A draw of each picture.
byte_counts: [16]u64 // The bytes of HISTOGRAM_SIZE by their high 4 bits.
megabytes_per_second_tenths: u64
measure_microseconds: u64
measured: bool

records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

hex_text :: proc "contextless" (builder: ^interface.Text_Builder, bytes: []u8) -> string {
	digits := "0123456789abcdef"
	builder.count = 0
	for byte, index in bytes {
		if index > 0 && index % 4 == 0 {
			interface.text_put(builder, " ")
		}
		pair := [2]u8{digits[byte >> 4], digits[byte & 15]}
		interface.text_put(builder, string(pair[:]))
	}
	return interface.text_of(builder)
}

strength_color :: proc "contextless" (strength: random.Seed_Strength) -> graphics.Color {
	#partial switch strength {
	case .Entropy:
		return graphics.COLOR_PROGRAM
	case .Processor:
		return graphics.COLOR_TEXT
	}
	return graphics.COLOR_FAILED
}

source_line :: proc "contextless" (frame: ^interface.Frame, column: ^interface.Column, name: string, present: bool, good, refused: u32, wanted: u32) {
	builder: interface.Text_Builder
	if !present {
		interface.label_value_line(frame, interface.column_take(column, LINE), name, "absent: the processor does not have it", graphics.COLOR_DIM, 168)
		return
	}
	interface.text_put(&builder, "present, ")
	interface.text_put_number(&builder, u64(good))
	interface.text_put(&builder, " good values of ")
	interface.text_put_number(&builder, u64(wanted))
	interface.text_put(&builder, ", ")
	interface.text_put_number(&builder, u64(refused))
	interface.text_put(&builder, " refused")
	interface.label_value_line(frame, interface.column_take(column, LINE), name, interface.text_of(&builder), good == wanted ? graphics.COLOR_TEXT : graphics.COLOR_FAILED, 168)
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	builder: interface.Text_Builder

	// The seed of the system: the facts of the root service.
	content := interface.card(&frame, {8, 8, WIDTH - 16, 196}, "THE SEED OF THE SYSTEM", "Entropy_Report of the root service, at its start", graphics.COLOR_KERNEL)
	column := interface.column_of(content)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "strength", random.seed_strength_names[report.strength], strength_color(report.strength), 168)
	source_line(&frame, &column, "rdseed", report.rdseed_present, report.rdseed_good, report.rdseed_refused, random.PROCESSOR_VALUES)
	source_line(&frame, &column, "rdrand", report.rdrand_present, report.rdrand_good, report.rdrand_refused, random.PROCESSOR_VALUES)
	builder.count = 0
	interface.text_put_number(&builder, u64(report.jitter_samples))
	interface.text_put(&builder, " samples, ")
	interface.text_put_number(&builder, u64(report.jitter_distinct))
	interface.text_put(&builder, " distinct low bytes; counted as 0 bits")
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "cycle counter", interface.text_of(&builder), graphics.COLOR_TEXT, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "entropy device", "none yet: virtio-rng is not driven", graphics.COLOR_DIM, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "mixed by", "BLAKE3 of each value, with its length", graphics.COLOR_TEXT, 168)

	// The generator of this program.
	content = interface.card(&frame, {8, 212, WIDTH - 16, HEIGHT - 220}, "THE GENERATOR OF THIS PROGRAM", "random.Generator: ChaCha20, fast key erasure", graphics.COLOR_PROGRAM)
	column = interface.column_of(content)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "seed", "32 bytes from its starter (the context values 9 to 12), erased after", graphics.COLOR_TEXT, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "first bytes", hex_text(&builder, first_bytes[:]), graphics.COLOR_TEXT, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "now", hex_text(&builder, live_bytes[:]), graphics.COLOR_PROGRAM, 168)
	builder.count = 0
	interface.text_put_number(&builder, program_generator.served)
	interface.text_put(&builder, " bytes served, ")
	interface.text_put_number(&builder, program_generator.refills)
	interface.text_put(&builder, " refills of 832 bytes")
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "drawn", interface.text_of(&builder), graphics.COLOR_TEXT, 168)
	if measured {
		builder.count = 0
		interface.text_put_number(&builder, megabytes_per_second_tenths / 10)
		interface.text_put(&builder, ".")
		interface.text_put_number(&builder, megabytes_per_second_tenths % 10)
		interface.text_put(&builder, " MB/s, 4 MiB in ")
		interface.text_put_number(&builder, measure_microseconds)
		interface.text_put(&builder, " us, no kernel entry")
		interface.label_value_line(&frame, interface.column_take(&column, LINE), "speed", interface.text_of(&builder), graphics.COLOR_MACHINE, 168)
	}
	interface.column_take(&column, 8)
	interface.cell_text(&frame, interface.column_take(&column, LINE), "1 MiB of the stream, by the high 4 bits of each byte: each bar is near 1/16", graphics.COLOR_DIM)
	most: u64 = 1
	for count in byte_counts {
		most = max(most, count)
	}
	bars := interface.column_take(&column, 120)
	bar_width := (bars.width - 15 * 6) / 16
	for count, index in byte_counts {
		x := bars.x + index * (bar_width + 6)
		height := int(count * u64(bars.height - LINE) / most)
		interface.draw_rectangle(frame.table, x, bars.y + bars.height - LINE - height, bar_width, height, graphics.COLOR_MEMORY)
		digits := "0123456789abcdef"
		digit := [1]u8{digits[index]}
		interface.draw_text(frame.table, x + bar_width / 2 - 4, bars.y + bars.height - LINE + 4, string(digit[:]), graphics.COLOR_DIM)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

// The entry of randomness: it shows the seed, counts 1 MiB, measures 4 MiB,
// then draws a live stream every 500 ms for ever.
//
// With no seed in its context, it writes "randomness: no random seed in the
// context" and stops with the code 1; with no window, it stops with the
// code 1. The counts and the measure run once, in the main thread, after
// the first picture.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("randomness: no random seed in the context")
		system.stop(1)
	}
	report = random.report_values_read(&ctx.values)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "randomness")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	random.fill(&program_generator, first_bytes[:])
	hex: interface.Text_Builder
	system.log("randomness: the seed of the system: strength ", random.seed_strength_names[report.strength], "; the first bytes of the stream of this program: ", hex_text(&hex, first_bytes[:]))
	draw(&window)

	// The counts of the byte values of 1 MiB, then the speed on 4 MiB.
	chunk: [4096]u8
	for _ in 0 ..< HISTOGRAM_SIZE / len(chunk) {
		random.fill(&program_generator, chunk[:])
		for byte in chunk {
			byte_counts[byte >> 4] += 1
		}
	}
	least, most: u64 = max(u64), 0
	for count in byte_counts {
		least, most = min(least, count), max(most, count)
	}
	system.log("randomness: 1 MiB by the high 4 bits of each byte: from ", least, " to ", most, " in each of 16 (the mean is 65536)")
	start := system.nanoseconds()
	for _ in 0 ..< MEASURE_SIZE / len(chunk) {
		random.fill(&program_generator, chunk[:])
	}
	took := max(system.nanoseconds() - start, 1)
	measure_microseconds = took / 1000
	megabytes_per_second_tenths = u64(MEASURE_SIZE) * 10_000 / took
	measured = true
	system.log("randomness: the generator: 4 MiB in ", measure_microseconds, " us, ", megabytes_per_second_tenths / 10, ".", megabytes_per_second_tenths % 10, " MB/s")
	deadline := system.time()
	for {
		random.fill(&program_generator, live_bytes[:])
		draw(&window)
		deadline += 500
		display.wait(&window, deadline)
		interface.window_events(&drawing, &window)
	}
}
