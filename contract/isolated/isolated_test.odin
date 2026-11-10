#+build !freestanding
package isolated

import module "contract:module"
import "core:math/rand"
import "core:testing"

@(private = "file")
description :: proc(types: ..module.Type) -> (function: module.Function) {
	function.parameter_count = u8(len(types))
	copy(function.parameters[:], types)
	return function
}

// What encode writes, decode reads: the same integers, and for each Text
// the same bytes, at an address in the call region.
@(test)
arguments_round_trip :: proc(t: ^testing.T) {
	region: [256]u8
	function := description(.Integer, .Text, .Integer, .Text, .Text, .Integer)
	first, second := "the first text", "second"
	arguments := [?]Argument{{integer = 7}, {text = transmute([]u8)first}, {integer = max(u64)}, {text = transmute([]u8)second}, {}, {integer = 1 << 40}}
	offset, size, _, encoded := encode(function, arguments[:], region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 3 * 8 + 3 * 16)

	registers: [module.PARAMETER_CAPACITY]u64
	slices: [module.PARAMETER_CAPACITY]Slice
	testing.expect(t, decode(function, offset, size, region[:], &registers, &slices))
	testing.expect_value(t, registers[0], 7)
	testing.expect_value(t, registers[2], max(u64))
	testing.expect_value(t, registers[5], 1 << 40)
	// A Text register has the address of a slice record with the layout of a string.
	testing.expect_value(t, (^string)(uintptr(registers[1]))^, first)
	testing.expect_value(t, (^string)(uintptr(registers[3]))^, second)
	testing.expect_value(t, (^string)(uintptr(registers[4]))^, "")
	low, high := uintptr(&region[0]), uintptr(&region[0]) + len(region)
	for index in ([]int{1, 3, 4}) {
		testing.expect(t, uintptr(slices[index].start) >= low && uintptr(slices[index].start + slices[index].count) <= high)
	}
}

@(test)
encode_refuses :: proc(t: ^testing.T) {
	region: [64]u8
	long: [64]u8
	_, _, _, ok := encode(description(.Integer), {}, region[:])
	testing.expect(t, !ok, "the argument count differs from the description")
	_, _, _, ok = encode(description(.Text), {{text = long[:]}}, region[:])
	testing.expect(t, !ok, "the text does not fit in the call region")
	_, _, _, ok = encode(description(.Text), {{text = long[:48]}}, region[:])
	testing.expect(t, ok, "the text fills the call region exactly")
	_, _, _, ok = encode(description(module.Type(200)), {{}}, region[:])
	testing.expect(t, !ok, "the description has an unknown type")
	unknown := description(.Integer)
	unknown.parameter_count = module.PARAMETER_CAPACITY + 1
	_, _, _, ok = encode(unknown, {{}}, region[:])
	testing.expect(t, !ok, "the description has too many parameters")
}

// decode refuses each argument record that names memory out of the call region.
@(test)
decode_refuses :: proc(t: ^testing.T) {
	region: [128]u8
	registers: [module.PARAMETER_CAPACITY]u64
	slices: [module.PARAMETER_CAPACITY]Slice
	function := description(.Integer, .Text)
	SIZE :: 8 + 16

	Case :: struct {
		offset, size: u64,
		slice:        Slice,
		ok:           bool,
		about:        string,
	}
	cases := [?]Case {
		{offset = 0, size = SIZE, slice = {start = 24, count = 104}, ok = true, about = "a slice to the last byte"},
		{offset = 104, size = SIZE, slice = {start = 0, count = 0}, ok = true, about = "a record at the end"},
		{offset = 0, size = SIZE, slice = {start = 128, count = 0}, ok = true, about = "an empty slice at the end"},
		{offset = 0, size = SIZE, slice = {start = 24, count = 105}, about = "a slice one byte too long"},
		{offset = 0, size = SIZE, slice = {start = 129, count = 0}, about = "a slice that starts after the end"},
		{offset = 0, size = SIZE, slice = {start = 8, count = max(u64)}, about = "a count that wraps"},
		{offset = 0, size = SIZE, slice = {start = max(u64), count = 2}, about = "a start that wraps"},
		{offset = 105, size = SIZE, about = "a record that crosses the end"},
		{offset = max(u64), size = SIZE, about = "a record offset that wraps"},
		{offset = 0, size = SIZE - 8, about = "a record that is too small"},
		{offset = 0, size = SIZE + 8, about = "a record that is too large"},
		{offset = 0, size = max(u64), about = "a size that wraps"},
	}
	for item in cases {
		region = {}
		if item.offset <= len(region) - SIZE {
			store(region[:], item.offset + 8, item.slice)
		}
		testing.expectf(t, decode(function, item.offset, item.size, region[:], &registers, &slices) == item.ok, "%s", item.about)
	}
}

// With random bytes in the call region and random numbers in the command
// record, decode gives only addresses in the call region.
@(test)
decode_random :: proc(t: ^testing.T) {
	region: [512]u8
	low, high := u64(uintptr(&region[0])), u64(uintptr(&region[0])) + len(region)
	accepted := 0
	for _ in 0 ..< 200_000 {
		function: module.Function
		function.parameter_count = u8(rand.int_max(module.PARAMETER_CAPACITY + 2))
		function.result = module.Type(rand.int_max(4))
		for &type in function.parameters {
			type = module.Type(rand.int_max(4))
		}
		for &b in region[:64] {
			b = u8(rand.uint32())
		}
		// Small numbers most of the time, so that many records pass the checks.
		if rand.int_max(4) != 0 {
			for i := 0; i < 64; i += 8 {
				store(region[:], u64(i), u64(rand.int_max(600)))
			}
		}
		size, _ := record_size(function)
		offset := u64(rand.int_max(8)) * 8
		if rand.int_max(8) == 0 {
			size, offset = rand.uint64(), rand.uint64()
		}
		registers: [module.PARAMETER_CAPACITY]u64
		slices: [module.PARAMETER_CAPACITY]Slice
		if !decode(function, offset, size, region[:], &registers, &slices) {
			continue
		}
		accepted += 1
		types := function.parameters
		count := int(function.parameter_count)
		if function.result == .Text {
			// The buffer of the result is one more slice.
			testing.expect(t, count < module.PARAMETER_CAPACITY)
			types[count] = .Text
			count += 1
		}
		for type, index in types[:count] {
			if type != .Text {
				continue
			}
			slice := slices[index]
			testing.expect(t, registers[index] == u64(uintptr(&slices[index])))
			if slice.start < low || slice.start > high || slice.count > high - slice.start {
				testing.expectf(t, false, "a slice is out of the call region: start %x count %x", slice.start, slice.count)
				return
			}
		}
	}
	testing.expect(t, accepted > 1000, "the test must accept many records")
}

// A Text result: the buffer is the rest of the call region. The callee
// writes there; the caller reads the count that the callee gave, and never
// more than the buffer.
@(test)
text_result :: proc(t: ^testing.T) {
	region: [128]u8
	function := description(.Text, .Integer)
	function.result = .Text
	argument := "abc"
	offset, size, result, encoded := encode(function, {{text = transmute([]u8)argument}, {integer = 5}}, region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 16 + 8 + 16)
	testing.expect_value(t, result, Slice{start = 43, count = 85})

	registers: [module.PARAMETER_CAPACITY]u64
	slices: [module.PARAMETER_CAPACITY]Slice
	testing.expect(t, decode(function, offset, size, region[:], &registers, &slices))
	buffer := (^[]u8)(uintptr(registers[2]))^
	testing.expect_value(t, len(buffer), 85)
	testing.expect(t, raw_data(buffer) == &region[43])
	copy(buffer, "result")

	text, complete := result_text(region[:], result, 6)
	testing.expect_value(t, string(text), "result")
	testing.expect(t, complete)
	text, complete = result_text(region[:], result, 86)
	testing.expect_value(t, len(text), 85)
	testing.expect(t, !complete, "the callee gave a count larger than the buffer")
	text, complete = result_text(region[:], result, max(u64))
	testing.expect(t, len(text) == 85 && !complete)
	_, complete = result_text(region[:], Slice{start = 100, count = 29}, 1)
	testing.expect(t, !complete, "a buffer that is not in the call region")

	full := description(.Integer, .Integer, .Integer, .Integer, .Integer, .Integer)
	full.result = .Text
	_, _, _, ok := encode(full, {{}, {}, {}, {}, {}, {}}, region[:])
	testing.expect(t, !ok, "six parameters leave no register for the buffer")
}
