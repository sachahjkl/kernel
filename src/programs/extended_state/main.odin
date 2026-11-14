// The extended state of each thread, kept by the kernel (docs/ARCHITECTURE.md,
// "The extended state of the processor").
//
// The program starts as many threads as the machine has processors, plus
// two, so that threads share processors and move between them. Each thread
// fills every register of the widest level that it can use (zmm0 to zmm31
// and k0 to k7, or ymm0 to ymm15, or xmm0 to xmm15), the x87 stack, the x87
// control word and MXCSR with a pattern of its own, new at each pass; then
// it spins, enters the kernel, and gives its processor away, many times;
// then it compares each register with its pattern. A wrong bit is a failed
// check that names the thread, the register and the pass.
//
// Each thread also checks the start state that the kernel gave it: the high
// halves of its ymm and zmm registers and its opmask registers are zero, the
// x87 control word is 0x037F and MXCSR is 0x1F80. A kernel that did not save
// the high halves would give a new thread the registers of another thread.
//
// Then the main thread measures one empty kernel entry with each level of
// registers in use.
//
// **What it is for.** The kernel keeps the [extended state](term:extended-state)
// of each thread (the vector registers, the x87 and MXCSR) and saves it
// only at a [switch of threads](term:switch-of-threads). A fault there
// leaks the registers of one program into another, or changes the result
// of a computation in silence. This program puts that work under load,
// with a pattern in each register, and checks every bit.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("extended_state")` in the console. The window shows the level of
// registers that the threads use, the threads, the passes and the checks.
// The log gets `extended_state: ok, <count> threads on <count> processors,
// <count> passes, <count> kernel entries ...`, or `extended_state: failed:
// <count> wrong registers after a pass, <count> parts of a start state
// wrong`, then the cost of one empty kernel entry with each level.
//
// **Its grants**: none. Its budget holds 32 threads: the main thread and
// up to 31 threads that hold their registers.
//
// **What it does not prove.** The widest level that it uses is the level
// of the processor of the run: under QEMU with no AVX-512, the zmm and k
// registers are not checked. The rules are in docs/SIMD.md.
package extended_state

import "base:intrinsics"
import "modus:support/display"
import "modus:support/graphics"
import sets "modus:support/instruction_sets"
import "modus:support/interface"
import "modus:support/system"

LINE :: interface.TABLE_LINE
WIDTH :: 1024
HEIGHT :: 720
WORKER_CAPACITY :: 31 // A program has 32 threads at most: the main thread and these. Its budget has 32.
RUN_MILLISECONDS :: 3000 // How long the threads hold their registers.
ROUNDS :: 16 // Kernel entries in one pass: above the round where the x87 control word changes alone (registers.asm).
SPINS :: 20_000 // Loops between two entries: the timer interrupts some of them.
MEASURE_ENTRIES :: 100_000
LOG_WRONG_LIMIT :: 16 // Lines of wrong registers on the log, for all threads.

// The registers of one pass: the layout of registers.asm.
Register_Image :: struct #align (64) {
	vectors:     [32][64]u8, // Register n at n * 64: xmm uses 16 bytes, ymm 32, zmm 64.
	opmasks:     [8]u64, // kmovw: the low 16 bits; kmovq: all 64.
	x87:         [8]i64, // In the order of the loads: the last is the top of the stack.
	// The x87 control word and MXCSR: the first values are loaded at the
	// start of a pass; in the middle of the pass each one changes alone to
	// its second value, which is the one expected at the end.
	x87_control:       u16,
	x87_control_first: u16,
	mxcsr:             u32,
	mxcsr_first:       u32,
}
#assert(offset_of(Register_Image, opmasks) == 2048)
#assert(offset_of(Register_Image, x87) == 2112)
#assert(offset_of(Register_Image, x87_control) == 2176)
#assert(offset_of(Register_Image, x87_control_first) == 2178)
#assert(offset_of(Register_Image, mxcsr) == 2180)
#assert(offset_of(Register_Image, mxcsr_first) == 2184)

Level :: enum u64 {
	Sse     = 0, // xmm0 to xmm15
	Avx     = 1, // ymm0 to ymm15
	Avx_512 = 2, // zmm0 to zmm31, k0 to k7 (16 bits of each: AVX-512 F)
	Avx_512_With_Wide_Opmasks = 3, // The same, 64 bits of each opmask (AVX-512 BW)
}

@(rodata)
level_names := [Level]string {
	.Sse     = "xmm0 to xmm15",
	.Avx     = "ymm0 to ymm15",
	.Avx_512 = "zmm0 to zmm31 and k0 to k7 (16 bits)",
	.Avx_512_With_Wide_Opmasks = "zmm0 to zmm31 and k0 to k7 (64 bits)",
}

foreign _ {
	registers_hold :: proc "c" (expected, seen: ^Register_Image, level: Level, rounds, spins: u64) ---
	registers_store :: proc "c" (seen: ^Register_Image, level: Level) ---
	registers_enter_repeatedly :: proc "c" (expected: ^Register_Image, level: Level, count: u64) ---
	// The parts of a save and a restore, each alone (registers.asm): the cycles of the
	// cycle counter for `count` loops on the area.
	registers_upper_halves_in_use :: proc "c" (expected: ^Register_Image) ---
	registers_upper_halves_clean :: proc "c" () ---
	measure_loop_alone :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_fxsave_and_fxrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt_and_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt_vzeroupper_and_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt_vzeroupper_and_xrstor_with_avx :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsave_and_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_vzeroupper :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_fxsave :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_fxrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xsaveopt :: proc "c" (area: rawptr, count: u64) -> u64 ---
	measure_xrstor :: proc "c" (area: rawptr, count: u64) -> u64 ---
}

// The parts of a save and a restore that the program measures alone, on its own
// area, with the mask of the kernel. Not privileged instructions: the kernel
// is not changed for the measure.
Part :: enum {
	Loop_Alone,
	Fxsave_And_Fxrstor,
	Xsaveopt_And_Xrstor,
	Xsaveopt_Vzeroupper_And_Xrstor,
	Xsaveopt_Vzeroupper_And_Xrstor_With_Avx,
	Xsave_And_Xrstor,
	Fxsave,
	Fxrstor,
	Xsaveopt,
	Xrstor,
	Vzeroupper,
}

@(rodata)
part_names := [Part]string {
	.Loop_Alone                              = "the loop",
	.Fxsave_And_Fxrstor                      = "fxsave64 + fxrstor64",
	.Xsaveopt_And_Xrstor                     = "xsaveopt64 + xrstor64",
	.Xsaveopt_Vzeroupper_And_Xrstor          = "xsaveopt64 + vzeroupper + xrstor64",
	.Xsaveopt_Vzeroupper_And_Xrstor_With_Avx = "the same with ymm in use",
	.Xsave_And_Xrstor                        = "xsave64 + xrstor64",
	.Fxsave                                  = "fxsave64",
	.Fxrstor                                 = "fxrstor64",
	.Xsaveopt                                = "xsaveopt64",
	.Xrstor                                  = "xrstor64",
	.Vzeroupper                              = "vzeroupper",
}

Part_Measure :: #type proc "c" (area: rawptr, count: u64) -> u64

// part_measure gives the routine of a part. A procedure, not a table: a
// global whose initializer is not a constant is not initialized.
part_measure :: proc "contextless" (part: Part) -> Part_Measure {
	switch part {
	case .Loop_Alone:
		return measure_loop_alone
	case .Fxsave_And_Fxrstor:
		return measure_fxsave_and_fxrstor
	case .Xsaveopt_And_Xrstor:
		return measure_xsaveopt_and_xrstor
	case .Xsaveopt_Vzeroupper_And_Xrstor:
		return measure_xsaveopt_vzeroupper_and_xrstor
	case .Xsaveopt_Vzeroupper_And_Xrstor_With_Avx:
		return measure_xsaveopt_vzeroupper_and_xrstor_with_avx
	case .Xsave_And_Xrstor:
		return measure_xsave_and_xrstor
	case .Fxsave:
		return measure_fxsave
	case .Fxrstor:
		return measure_fxrstor
	case .Xsaveopt:
		return measure_xsaveopt
	case .Xrstor:
		return measure_xrstor
	case .Vzeroupper:
		return measure_vzeroupper
	}
	return measure_loop_alone
}

PART_LOOPS :: 100_000
PART_RUNS :: 5 // The least of the runs: the others had an interrupt or a switch.

Part_Area :: struct #align (64) {
	bytes: [4096]u8,
}
part_area: Part_Area
// The cycles of the cycle counter for one loop of each part, in tenths. 0:
// the processor or the kernel does not give the instructions of that part.
part_tenths: [Part]u64

Register_Kind :: enum u8 {
	Vector, // xmm, ymm or zmm, by the level.
	Opmask,
	X87, // A register of the x87 stack, by its load.
	X87_Control,
	Mxcsr,
}

// One thread of the test. The thread writes its counts with atomic stores;
// the main thread reads them.
Worker :: struct {
	number:            u32,
	thread:            system.Thread,
	passes:            u64,
	entries:           u64,
	wrong_registers:   u64,
	start_state_wrong: u64, // Parts of the start state that were not the start state.
	start_state_done:  bool,
	done:              bool,
	// The registers of each vector register, for the window: 1 when that
	// register was wrong once.
	wrong_vectors:     u32,
	wrong_others:      u8, // Bit n: Register_Kind n other than Vector was wrong once.
	expected:          Register_Image,
	seen:              Register_Image,
}

workers: [WORKER_CAPACITY]Worker
worker_count: int
processor_count: u32
held_level: Level // The widest registers that the threads hold.
usable: sets.Instruction_Sets
facts: sets.Processor_Facts
start_time: u64
wrong_lines: u64 // The lines of wrong registers on the log, for all threads (atomic).
entry_nanoseconds: [Level]u64 // 0: not measured (the level is not usable).
finished: bool
passed: bool

records_now, records_before: [1024]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

// mix gives 64 bits from a number: the finalizer of splitmix64.
mix :: proc "contextless" (value: u64) -> u64 {
	z := value + 0x9E37_79B9_7F4A_7C15
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// pattern_fill writes the pattern of one thread for one pass. Each byte
// depends on the thread, the pass and the place: a register that came from
// another thread or from another pass differs.
pattern_fill :: proc "contextless" (image: ^Register_Image, thread: u32, pass: u64) {
	// The places use the low 24 bits: the thread and the pass are above them.
	seed := u64(thread) << 56 ~ pass << 24
	for &register, index in image.vectors {
		for part in 0 ..< 8 {
			value := mix(seed ~ u64(index) << 3 ~ u64(part))
			(^u64)(&register[part * 8])^ = value
		}
	}
	for &value, index in image.opmasks {
		value = mix(seed ~ 0x1_0000 ~ u64(index))
	}
	for &value, index in image.x87 {
		value = i64(mix(seed ~ 0x2_0000 ~ u64(index)))
		if value == min(i64) {
			value = 1 // min(i64) is the "integer indefinite" of fistp.
		}
	}
	turn := u64(thread) + pass
	// Only the rounding control changes: every exception stays masked.
	image.x87_control_first = 0x037F | u16(turn & 3) << 10
	image.mxcsr_first = 0x1F80 | u32(turn & 3) << 13 | u32(thread & 1) << 15 // Rounding control; flush to zero.
	// The second values: another rounding control, the rest the same.
	image.x87_control = image.x87_control_first ~ 1 << 10
	image.mxcsr = image.mxcsr_first ~ 1 << 13
}

vector_width :: proc "contextless" (level: Level) -> int {
	switch level {
	case .Sse:
		return 16
	case .Avx:
		return 32
	case .Avx_512, .Avx_512_With_Wide_Opmasks:
		return 64
	}
	return 16
}

vector_count :: proc "contextless" (level: Level) -> int {
	return level >= .Avx_512 ? 32 : 16
}

// opmask_mask gives the bits of each opmask register that the test moves:
// kmovw moves 16, kmovq 64.
opmask_mask :: proc "contextless" () -> u64 {
	return held_level == .Avx_512_With_Wide_Opmasks ? max(u64) : 0xFFFF
}

register_name :: proc "contextless" (builder: ^interface.Text_Builder, kind: Register_Kind, index: int) -> string {
	builder.count = 0
	switch kind {
	case .Vector:
		interface.text_put(builder, held_level >= .Avx_512 ? "zmm" : (held_level == .Avx ? "ymm" : "xmm"))
		interface.text_put_number(builder, u64(index))
	case .Opmask:
		interface.text_put(builder, "k")
		interface.text_put_number(builder, u64(index))
	case .X87:
		interface.text_put(builder, "x87 load ")
		interface.text_put_number(builder, u64(index))
	case .X87_Control:
		interface.text_put(builder, "the x87 control word")
	case .Mxcsr:
		interface.text_put(builder, "MXCSR")
	}
	return interface.text_of(builder)
}

// wrong_note counts one wrong register and logs the first ones.
wrong_note :: proc "contextless" (worker: ^Worker, kind: Register_Kind, index: int, pass: u64, expected, found: u64, what: string) {
	worker.wrong_registers += 1
	if kind == .Vector {
		worker.wrong_vectors |= 1 << u32(index)
	} else {
		worker.wrong_others |= 1 << u8(kind)
	}
	if intrinsics.atomic_add(&wrong_lines, 1) < LOG_WRONG_LIMIT {
		name: interface.Text_Builder
		system.log("extended_state: WRONG: thread ", u64(worker.number), ", ", register_name(&name, kind, index), ", ", what, " ", pass, ": expected ", system.Hex(expected), ", found ", system.Hex(found))
	}
}

// pass_compare compares what the registers held after a pass with what the
// thread loaded.
pass_compare :: proc "contextless" (worker: ^Worker, pass: u64) {
	expected := &worker.expected
	seen := &worker.seen
	width := vector_width(held_level)
	for index in 0 ..< vector_count(held_level) {
		for part in 0 ..< width / 8 {
			want := (^u64)(&expected.vectors[index][part * 8])^
			got := (^u64)(&seen.vectors[index][part * 8])^
			if want != got {
				wrong_note(worker, .Vector, index, pass, want, got, "pass")
				break
			}
		}
	}
	if held_level >= .Avx_512 {
		mask := opmask_mask()
		for index in 0 ..< 8 {
			if expected.opmasks[index] & mask != seen.opmasks[index] & mask {
				wrong_note(worker, .Opmask, index, pass, expected.opmasks[index] & mask, seen.opmasks[index] & mask, "pass")
			}
		}
	}
	for index in 0 ..< 8 {
		if expected.x87[index] != seen.x87[index] {
			wrong_note(worker, .X87, index, pass, u64(expected.x87[index]), u64(seen.x87[index]), "pass")
		}
	}
	if expected.x87_control != seen.x87_control {
		wrong_note(worker, .X87_Control, 0, pass, u64(expected.x87_control), u64(seen.x87_control), "pass")
	}
	if expected.mxcsr != seen.mxcsr {
		wrong_note(worker, .Mxcsr, 0, pass, u64(expected.mxcsr), u64(seen.mxcsr), "pass")
	}
}

// start_state_check compares the registers of a new thread with the start
// state of the kernel. The low 16 bytes of the vector registers are not
// checked: the compiled code of the thread used them before this point.
start_state_check :: proc "contextless" (worker: ^Worker) {
	seen := &worker.seen
	seen^ = {}
	// Not zero, so that a register that the store does not write is seen.
	for &register in seen.vectors {
		for &place in register {
			place = 0xA5
		}
	}
	for &value in seen.opmasks {
		value = 0xA5A5_A5A5_A5A5_A5A5
	}
	registers_store(seen, held_level)
	wrong: u64
	note :: proc "contextless" (worker: ^Worker, wrong: ^u64, kind: Register_Kind, index: int, expected, found: u64) {
		wrong^ += 1
		wrong_note(worker, kind, index, 0, expected, found, "start state, pass")
	}
	if held_level != .Sse {
		for index in 0 ..< vector_count(held_level) {
			first := index < 16 ? 16 : 0 // zmm16 to zmm31 have no part that SSE code uses.
			for part in first / 8 ..< vector_width(held_level) / 8 {
				if value := (^u64)(&seen.vectors[index][part * 8])^; value != 0 {
					note(worker, &wrong, .Vector, index, 0, value)
					break
				}
			}
		}
	}
	if held_level >= .Avx_512 {
		for index in 0 ..< 8 {
			if value := seen.opmasks[index] & opmask_mask(); value != 0 {
				note(worker, &wrong, .Opmask, index, 0, value)
			}
		}
	}
	if seen.x87_control != 0x037F {
		note(worker, &wrong, .X87_Control, 0, 0x037F, u64(seen.x87_control))
	}
	if seen.mxcsr != 0x1F80 {
		note(worker, &wrong, .Mxcsr, 0, 0x1F80, u64(seen.mxcsr))
	}
	intrinsics.atomic_store(&worker.start_state_wrong, wrong)
	intrinsics.atomic_store(&worker.start_state_done, true)
}

// worker_run is the entry of each thread of the test.
worker_run :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	start_state_check(worker)
	pass: u64 = 1
	for {
		pattern_fill(&worker.expected, worker.number, pass)
		worker.seen = {}
		registers_hold(&worker.expected, &worker.seen, held_level, ROUNDS, SPINS)
		pass_compare(worker, pass)
		intrinsics.atomic_store(&worker.passes, pass)
		intrinsics.atomic_add(&worker.entries, ROUNDS)
		if system.time() - start_time >= RUN_MILLISECONDS {
			break
		}
		pass += 1
	}
	intrinsics.atomic_store(&worker.done, true)
	system.thread_stop()
}

// part_usable says if this program can run the instructions of a part:
// xsave, xsaveopt and xrstor need CR4.OSXSAVE, which the kernel sets only
// when it saves with xsaveopt; vzeroupper and ymm need AVX.
part_usable :: proc "contextless" (part: Part) -> bool {
	with_xsave := facts.leaf_1_ecx & sets.LEAF_1_ECX_OSXSAVE != 0
	#partial switch part {
	case .Xsaveopt_And_Xrstor, .Xsave_And_Xrstor, .Xsaveopt, .Xrstor:
		return with_xsave
	case .Xsaveopt_Vzeroupper_And_Xrstor, .Xsaveopt_Vzeroupper_And_Xrstor_With_Avx, .Vzeroupper:
		return with_xsave && .Avx in usable
	}
	return true
}

// parts_measure measures each part that this processor and this kernel
// give, PART_RUNS times, and keeps the least.
parts_measure :: proc "contextless" () {
	for part in Part {
		if !part_usable(part) {
			continue
		}
		least := max(u64)
		for _ in 0 ..< PART_RUNS {
			least = min(least, part_measure(part)(&part_area, PART_LOOPS))
		}
		part_tenths[part] = max(least * 10 / PART_LOOPS, 1)
	}
}

// tenths_put writes a number of tenths as "12.3".
tenths_put :: proc "contextless" (builder: ^interface.Text_Builder, tenths: u64) {
	interface.text_put_number(builder, tenths / 10)
	interface.text_put(builder, ".")
	interface.text_put_number(builder, tenths % 10)
}

// part_text writes the parts from first to last as "name cycles (ns)".
part_text :: proc "contextless" (builder: ^interface.Text_Builder, first, last: Part) -> string {
	builder.count = 0
	frequency := max(system.cycle_frequency(), 1)
	for part in Part {
		if part < first || part > last {
			continue
		}
		if builder.count > 0 {
			interface.text_put(builder, "; ")
		}
		interface.text_put(builder, part_names[part])
		interface.text_put(builder, " ")
		if part_tenths[part] == 0 {
			interface.text_put(builder, "none")
			continue
		}
		tenths_put(builder, part_tenths[part])
		interface.text_put(builder, " (")
		tenths_put(builder, part_tenths[part] * 1_000_000_000 / frequency)
		interface.text_put(builder, " ns)")
	}
	return interface.text_of(builder)
}

// The hand-over between two threads: the main thread takes the even turns,
// the second thread the odd ones. Each hand-over is a wake and a wait: the
// thread that waits leaves its processor, so the kernel saves its extended
// state, and the thread that it wakes is restored where it runs. With the
// AVX component in use in both threads, each save and restore holds it.
HAND_OVER_MILLISECONDS :: 500
Hand_Over :: struct {
	turn:      u32,
	stop:      u32,
	with_avx:  bool,
	ready:     u32, // The second thread loaded its registers.
}
hand_over: Hand_Over
hand_over_image: Register_Image
// The nanoseconds of one hand-over: [0] with x87 and SSE in use, [1] with
// the AVX component in use too. 0: not measured.
hand_over_nanoseconds: [2]u64
hand_over_counts: [2]u64

// hand_over_registers puts the registers of a hand-over in use: only the
// x87 and SSE of compiled code, or the ymm high halves too.
hand_over_registers :: proc "contextless" (with_avx: bool) {
	if with_avx {
		registers_upper_halves_in_use(&hand_over_image)
	} else if .Avx in usable {
		registers_upper_halves_clean()
	}
}

hand_over_second :: proc "c" (_: rawptr) -> ! {
	hand_over_registers(hand_over.with_avx)
	intrinsics.atomic_store(&hand_over.ready, 1)
	for intrinsics.atomic_load(&hand_over.stop) == 0 {
		turn := intrinsics.atomic_load(&hand_over.turn)
		if turn % 2 == 0 {
			system.word_wait(&hand_over.turn, turn, system.time() + 100)
			continue
		}
		intrinsics.atomic_store(&hand_over.turn, turn + 1)
		system.word_wake(&hand_over.turn)
	}
	if hand_over.with_avx {
		registers_upper_halves_clean()
	}
	system.thread_stop()
}

// hand_over_measure measures one hand-over between two threads, with the
// x87 and SSE registers in use, then with the AVX component in use. It
// gives the count of hand-overs and the nanoseconds of one.
hand_over_measure :: proc "contextless" (with_avx: bool) -> (count: u64, nanoseconds: u64) {
	hand_over = {with_avx = with_avx}
	pattern_fill(&hand_over_image, 77, 1)
	thread, status := system.thread_start(hand_over_second, nil)
	if status != .Ok {
		return 0, 0
	}
	for intrinsics.atomic_load(&hand_over.ready) == 0 {
		intrinsics.cpu_relax()
	}
	hand_over_registers(with_avx)
	start := system.nanoseconds()
	end := system.time() + HAND_OVER_MILLISECONDS
	for system.time() < end {
		turn := intrinsics.atomic_load(&hand_over.turn)
		if turn % 2 == 1 {
			system.word_wait(&hand_over.turn, turn, system.time() + 100)
			continue
		}
		intrinsics.atomic_store(&hand_over.turn, turn + 1)
		system.word_wake(&hand_over.turn)
		count += 1
	}
	took := system.nanoseconds() - start
	if with_avx {
		registers_upper_halves_clean()
	}
	intrinsics.atomic_store(&hand_over.stop, 1)
	intrinsics.atomic_add(&hand_over.turn, 2)
	system.word_wake(&hand_over.turn, system.WAKE_ALL)
	system.thread_wait(thread)
	// Each count of this thread is two hand-overs: to the second thread and back.
	return count * 2, took / max(count * 2, 1)
}

// entry_measure measures one empty kernel entry with the registers of a
// level in use, after the threads of the test ended.
entry_measure :: proc "contextless" () {
	image: Register_Image
	pattern_fill(&image, 99, 1)
	for measured in Level {
		// The wide opmasks are the same state component: no other measure.
		if measured > held_level || measured == .Avx_512_With_Wide_Opmasks {
			break
		}
		before := system.nanoseconds()
		registers_enter_repeatedly(&image, measured, MEASURE_ENTRIES)
		entry_nanoseconds[measured] = max((system.nanoseconds() - before) / MEASURE_ENTRIES, 1)
	}
}

sets_text :: proc "contextless" (builder: ^interface.Text_Builder, chosen: sets.Instruction_Sets, from, to: sets.Instruction_Set) -> string {
	builder.count = 0
	for set in sets.Instruction_Set {
		if set >= from && set <= to && set in chosen {
			if builder.count > 0 {
				interface.text_put(builder, ", ")
			}
			interface.text_put(builder, sets.instruction_set_names[set])
		}
	}
	if builder.count == 0 {
		interface.text_put(builder, "none")
	}
	return interface.text_of(builder)
}

components_text :: proc "contextless" (builder: ^interface.Text_Builder, components: sets.State_Components) -> string {
	builder.count = 0
	interface.text_put(builder, "x87, SSE")
	if .Avx in components {
		interface.text_put(builder, ", AVX")
	}
	if sets.AVX_512_COMPONENTS <= components {
		interface.text_put(builder, ", AVX-512")
	}
	interface.text_put(builder, "; one save writes at most ")
	interface.text_put_number(builder, u64(facts.saved_area_size))
	interface.text_put(builder, " bytes")
	return interface.text_of(builder)
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	builder: interface.Text_Builder

	content := interface.card(&frame, {8, 8, WIDTH - 16, 152}, "WHAT THE KERNEL SAVES", "XCR0 and CPUID, read by this program with no kernel operation", graphics.COLOR_KERNEL)
	column := interface.column_of(content)
	saved := sets.saved_components(facts)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "components", components_text(&builder, saved), graphics.COLOR_TEXT, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "SSE family", sets_text(&builder, usable, .Sse, .Pclmulqdq), graphics.COLOR_TEXT, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "AVX family", sets_text(&builder, usable, .Avx, .Avx512_Vl), .Avx in usable ? graphics.COLOR_TEXT : graphics.COLOR_DIM, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "general registers", sets_text(&builder, usable, .Popcnt, .Bmi2), graphics.COLOR_TEXT, 168)

	// One row for each thread, one square for each register.
	builder.count = 0
	interface.text_put_number(&builder, u64(worker_count))
	interface.text_put(&builder, " threads on ")
	interface.text_put_number(&builder, u64(processor_count))
	interface.text_put(&builder, " processors hold ")
	interface.text_put(&builder, level_names[held_level])
	interface.text_put(&builder, ", the x87 stack and MXCSR")
	content = interface.card(&frame, {8, 168, WIDTH - 16, 384}, "EACH REGISTER OF EACH THREAD", interface.text_of(&builder), graphics.COLOR_PROGRAM)
	column = interface.column_of(content)
	// A row of 16 pixels has room for a line of text. More threads than
	// 21 (a machine with more than 19 processors) get rows of 11 pixels
	// with the squares only; the log has their counts.
	with_text := worker_count * 16 <= content.height - LINE
	row_height := with_text ? 16 : 11
	square_size := with_text ? 10 : 8
	for &worker, index in workers[:worker_count] {
		if (index + 1) * row_height > content.height - LINE {
			break
		}
		row := interface.column_take(&column, row_height)
		if with_text {
			builder.count = 0
			interface.text_put(&builder, "thread ")
			interface.text_put_number(&builder, u64(worker.number))
			interface.draw_text(frame.table, row.x, row.y, interface.text_of(&builder), graphics.COLOR_DIM)
		}
		done := intrinsics.atomic_load(&worker.done)
		x := row.x + 96
		for register in 0 ..< 32 {
			color: graphics.Color = graphics.COLOR_NOT_USABLE
			if register < vector_count(held_level) {
				color = worker.wrong_vectors & (1 << u32(register)) != 0 ? graphics.COLOR_FAILED : (done ? graphics.COLOR_PROGRAM : graphics.COLOR_TRACK)
			}
			interface.mark(&frame, x + register * (square_size + 2), row.y + 2, square_size, color)
		}
		x += 32 * (square_size + 2) + 8
		others := [?]Register_Kind{.Opmask, .X87, .X87_Control, .Mxcsr}
		for kind, place in others {
			color: graphics.Color = graphics.COLOR_NOT_USABLE
			if kind != .Opmask || held_level >= .Avx_512 {
				color = worker.wrong_others & (1 << u8(kind)) != 0 ? graphics.COLOR_FAILED : (done ? graphics.COLOR_PROGRAM : graphics.COLOR_TRACK)
			}
			interface.mark(&frame, x + place * (square_size + 2), row.y + 2, square_size, color)
		}
		x += 4 * (square_size + 2) + 16
		if !with_text {
			continue
		}
		builder.count = 0
		interface.text_put_number(&builder, intrinsics.atomic_load(&worker.passes))
		interface.text_put(&builder, " passes, ")
		interface.text_put_number(&builder, intrinsics.atomic_load(&worker.entries))
		interface.text_put(&builder, " entries")
		if intrinsics.atomic_load(&worker.start_state_done) {
			interface.text_put(&builder, intrinsics.atomic_load(&worker.start_state_wrong) == 0 ? ", start state good" : ", START STATE WRONG")
		}
		wrong := worker.wrong_registers != 0 || worker.start_state_wrong != 0
		interface.draw_text(frame.table, x, row.y, interface.text_of(&builder), wrong ? graphics.COLOR_FAILED : graphics.COLOR_TEXT)
	}
	interface.cell_text(&frame, {content.x, content.y + content.height - LINE, content.width, LINE}, "a square: one vector register; then the opmasks, the x87 stack, the x87 control word, MXCSR", graphics.COLOR_DIM)

	content = interface.card(&frame, {8, 560, WIDTH - 16, HEIGHT - 568}, "ONE EMPTY KERNEL ENTRY", "a syscall with no command and no wait, 100000 times, after the test", graphics.COLOR_MACHINE)
	column = interface.column_of(content)
	for measured in Level {
		if measured == .Avx_512_With_Wide_Opmasks {
			continue
		}
		builder.count = 0
		if entry_nanoseconds[measured] == 0 {
			interface.text_put(&builder, measured > held_level ? "not usable here" : "not measured yet")
		} else {
			interface.text_put_number(&builder, entry_nanoseconds[measured])
			interface.text_put(&builder, " ns")
		}
		interface.label_value_line(&frame, interface.column_take(&column, LINE), level_names[measured], interface.text_of(&builder), entry_nanoseconds[measured] == 0 ? graphics.COLOR_DIM : graphics.COLOR_TEXT, 248)
	}
	if finished {
		interface.label_value_line(&frame, interface.column_take(&column, LINE), "result", passed ? "each register of each thread was kept" : "a register was not kept: see the log", passed ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED, 248)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

// entry starts the threads that fill and check the registers
// (`registers.asm` holds the code that touches each register), waits for
// their passes, writes the summary line, measures the empty kernel entry
// with each level of registers in use, then keeps the window open until the
// program is stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "extended_state")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	facts = sets.processor_facts_read()
	usable = sets.usable_from(facts)
	held_level = .Sse
	if .Avx in usable {
		held_level = .Avx
	}
	if .Avx512_F in usable {
		held_level = .Avx_512
	}
	if .Avx512_Bw in usable {
		held_level = .Avx_512_With_Wide_Opmasks
	}
	builder, second_builder, third_builder: interface.Text_Builder
	system.log("extended_state: the kernel saves ", components_text(&builder, sets.saved_components(facts)))
	system.log("extended_state: the usable instruction sets: ", sets_text(&builder, usable, .Sse, .Pclmulqdq), "; ", sets_text(&second_builder, usable, .Avx, .Avx512_Vl), "; ", sets_text(&third_builder, usable, .Popcnt, .Bmi2))
	if held_level == .Sse {
		system.log("extended_state: AVX is not usable: the processor does not have it or the kernel does not save it; the test holds xmm0 to xmm15")
	}

	processor_count = max(system.thread_record().processors, 1)
	worker_count = min(int(processor_count) + 2, WORKER_CAPACITY)
	if worker_count < int(processor_count) + 2 {
		// A program has 32 threads: on a larger machine some processors run
		// no thread of the test, and the threads still move at each wait.
		system.log("extended_state: ", u64(processor_count), " processors: ", u64(worker_count), " threads, the most that a program can have, fewer than the processors plus two")
	}
	start_time = system.time()
	for index in 0 ..< worker_count {
		worker := &workers[index]
		worker.number = u32(index + 1)
		status: system.Status
		worker.thread, status = system.thread_start(worker_run, worker)
		if status != .Ok {
			system.log("extended_state: cannot start thread ", u64(index + 1))
			system.stop(1)
		}
	}
	for !finished {
		draw(&window)
		display.wait(&window, system.time() + 100)
		interface.window_events(&drawing, &window)
		all_done := true
		for &worker in workers[:worker_count] {
			if !intrinsics.atomic_load(&worker.done) {
				all_done = false
			}
		}
		if !all_done {
			continue
		}
		passes, entries, wrong, start_wrong: u64
		for &worker in workers[:worker_count] {
			system.thread_wait(worker.thread)
			passes += worker.passes
			entries += worker.entries
			wrong += worker.wrong_registers
			start_wrong += worker.start_state_wrong
		}
		entry_measure()
		parts_measure()
		hand_over_counts[0], hand_over_nanoseconds[0] = hand_over_measure(false)
		if .Avx in usable {
			hand_over_counts[1], hand_over_nanoseconds[1] = hand_over_measure(true)
		}
		first_part, second_part, third_part: interface.Text_Builder
		system.log("extended_state: the parts of a save and a restore, each alone in this program, cycles of the cycle counter for one loop (ns): ", part_text(&first_part, .Loop_Alone, .Fxsave_And_Fxrstor), "; ", part_text(&second_part, .Xsaveopt_And_Xrstor, .Xsaveopt_Vzeroupper_And_Xrstor), "; ", part_text(&third_part, .Xsaveopt_Vzeroupper_And_Xrstor_With_Avx, .Xsave_And_Xrstor))
		system.log("extended_state: each instruction alone, cycles of the cycle counter for one loop (ns), the loop included: ", part_text(&first_part, .Fxsave, .Fxrstor), "; ", part_text(&second_part, .Xsaveopt, .Xrstor), "; ", part_text(&third_part, .Vzeroupper, .Vzeroupper))
		system.log("extended_state: a hand-over between two threads by the word wait (a wake, a wait, and the save and restore of the thread that waits and of the thread that runs): ", hand_over_nanoseconds[0], " ns with x87 and SSE in use, ", hand_over_nanoseconds[1], " ns with the ymm high halves in use (0: not usable); ", hand_over_counts[0], " and ", hand_over_counts[1], " hand-overs in ", u64(HAND_OVER_MILLISECONDS), " ms each")
		system.log("extended_state: an empty kernel entry, ", u64(MEASURE_ENTRIES), " times: ", entry_nanoseconds[.Sse], " ns with xmm in use, ", entry_nanoseconds[.Avx], " ns with ymm in use, ", entry_nanoseconds[.Avx_512], " ns with zmm in use (0: not usable)")
		passed = wrong == 0 && start_wrong == 0
		finished = true
		if passed {
			system.log("extended_state: ok, ", u64(worker_count), " threads on ", u64(processor_count), " processors, ", passes, " passes, ", entries, " kernel entries in the passes: each thread kept ", level_names[held_level], ", the x87 stack, the x87 control word and MXCSR, and started with the start state")
		} else {
			system.log("extended_state: failed: ", wrong, " wrong registers after a pass, ", start_wrong, " parts of a start state wrong")
		}
	}
	for {
		draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&drawing, &window)
	}
}
