package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// The extended state of the processor: three machines (docs/ARCHITECTURE.md,
// "The extended state of the processor").
//
// The first machine has each feature of the processor (`-cpu max`): the
// kernel saves x87, SSE and AVX, and AVX-512 when the host has it, with
// xsaveopt; the program extended_state holds ymm0 to ymm15, or zmm0 to
// zmm31 and k0 to k7, in more threads than processors. The tool reads the
// host first and waits for the exact lines of that machine: a host with no
// AVX-512 does not test the AVX-512 path, and the output says so. The
// second machine has no AVX: the kernel saves x87 and SSE with xsaveopt
// (576 bytes), and the program says that AVX is not usable and holds xmm0
// to xmm15. The third machine has no xsave: the kernel saves with fxsave
// (512 bytes), the other form of the same save, and the program holds xmm0
// to xmm15.

TEST_OUTPUT_EXTENDED_STATE :: BUILD_FOLDER + "/test_output_extended_state.txt"

// What AVX-512 the guest of `-cpu max` gets from this host.
Host_Avx_512 :: enum {
	None, // The host has no AVX-512, or QEMU cannot use KVM and emulates a processor with none.
	Foundation, // AVX-512 F: the opmasks move 16 bits at a time (kmovw).
	Foundation_And_Byte_Word, // AVX-512 F and BW: the opmasks move 64 bits (kmovq).
}

// host_avx_512 reads the flags of the host processor. Without KVM, QEMU
// emulates the processor (TCG), and the emulation has no AVX-512.
host_avx_512 :: proc() -> Host_Avx_512 {
	if !os.exists("/dev/kvm") {
		return .None
	}
	bytes, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
	if err != nil {
		return .None
	}
	text := string(bytes)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "flags") {
			continue
		}
		foundation, byte_word := false, false
		flags := line
		for flag in strings.fields_iterator(&flags) {
			if flag == "avx512f" {
				foundation = true
			}
			if flag == "avx512bw" {
				byte_word = true
			}
		}
		if !foundation {
			return .None
		}
		return byte_word ? .Foundation_And_Byte_Word : .Foundation
	}
	return .None
}

// The lines of the first machine, by what the host gives it.
@(rodata)
kernel_lines_with_each_feature := [Host_Avx_512]string {
	.None                     = "kernel: extended state: x87, SSE, AVX; one save writes at most 832 bytes, in an area of 2688 bytes in each thread entry; saved with xsaveopt",
	.Foundation               = "kernel: extended state: x87, SSE, AVX, AVX-512; one save writes at most 2688 bytes, in an area of 2688 bytes in each thread entry; saved with xsaveopt",
	.Foundation_And_Byte_Word = "kernel: extended state: x87, SSE, AVX, AVX-512; one save writes at most 2688 bytes, in an area of 2688 bytes in each thread entry; saved with xsaveopt",
}

@(rodata)
saved_lines_with_each_feature := [Host_Avx_512]string {
	.None                     = "extended_state: the kernel saves x87, SSE, AVX; one save writes at most 832 bytes",
	.Foundation               = "extended_state: the kernel saves x87, SSE, AVX, AVX-512; one save writes at most 2688 bytes",
	.Foundation_And_Byte_Word = "extended_state: the kernel saves x87, SSE, AVX, AVX-512; one save writes at most 2688 bytes",
}

@(rodata)
kept_lines_with_each_feature := [Host_Avx_512]string {
	.None                     = "kernel entries in the passes: each thread kept ymm0 to ymm15, the x87 stack, the x87 control word and MXCSR, and started with the start state",
	.Foundation               = "kernel entries in the passes: each thread kept zmm0 to zmm31 and k0 to k7 (16 bits), the x87 stack, the x87 control word and MXCSR, and started with the start state",
	.Foundation_And_Byte_Word = "kernel entries in the passes: each thread kept zmm0 to zmm31 and k0 to k7 (64 bits), the x87 stack, the x87 control word and MXCSR, and started with the start state",
}

// The three lines that depend on the host are the steps 0, 4 and 7:
// extended_state_tests_run sets them.
@(rodata)
scenario_extended_state_with_each_feature := [?]Step {
	{kind = .Wait, text = ""},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"extended_state\")"},
	{kind = .Wait, text = ""},
	{kind = .Wait, text = "extended_state: the usable instruction sets: SSE, SSE2"},
	{kind = .Wait, text = "extended_state: an empty kernel entry, 100000 times: "},
	{kind = .Wait, text = ""},
	{kind = .Front, text = "extended_state"},
	{kind = .Shot, text = "extended_state"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

@(rodata)
scenario_extended_state_without_avx := [?]Step {
	{kind = .Wait, text = "kernel: extended state: x87, SSE; one save writes at most 576 bytes, in an area of 2688 bytes in each thread entry; saved with xsaveopt"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"extended_state\")"},
	{kind = .Wait, text = "extended_state: the kernel saves x87, SSE; one save writes at most 576 bytes"},
	{kind = .Wait, text = "extended_state: AVX is not usable: the processor does not have it or the kernel does not save it; the test holds xmm0 to xmm15"},
	{kind = .Wait, text = "kernel entries in the passes: each thread kept xmm0 to xmm15, the x87 stack, the x87 control word and MXCSR, and started with the start state"},
	{kind = .Front, text = "extended_state"},
	{kind = .Shot, text = "extended_state_without_avx"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

@(rodata)
scenario_extended_state_without_xsave := [?]Step {
	{kind = .Wait, text = "kernel: extended state: x87, SSE; one save writes at most 512 bytes, in an area of 2688 bytes in each thread entry; saved with fxsave: the processor has no xsave or no xsaveopt"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"extended_state\")"},
	{kind = .Wait, text = "extended_state: the kernel saves x87, SSE; one save writes at most 512 bytes"},
	{kind = .Wait, text = "extended_state: AVX is not usable: "},
	{kind = .Wait, text = "kernel entries in the passes: each thread kept xmm0 to xmm15, the x87 stack, the x87 control word and MXCSR, and started with the start state"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

extended_state_tests_run :: proc() -> bool {
	host := host_avx_512()
	if host == .None {
		fmt.println("kerneltool: the host gives the machine no AVX-512 (no avx512f, or no KVM): the AVX-512 path of the kernel is not tested here")
	} else {
		fmt.printfln("kerneltool: the host gives the machine AVX-512 (%v): the machine with each feature tests it", host)
	}
	with_each_feature := scenario_extended_state_with_each_feature
	with_each_feature[0].text = kernel_lines_with_each_feature[host]
	with_each_feature[4].text = saved_lines_with_each_feature[host]
	with_each_feature[7].text = kept_lines_with_each_feature[host]
	return machine_test(with_each_feature[:], BOOT_VOLUME, TEST_OUTPUT_EXTENDED_STATE, MACHINE_STOP_OK, TEST_DATA_DISK) && machine_test(scenario_extended_state_without_avx[:], BOOT_VOLUME, TEST_OUTPUT_EXTENDED_STATE, MACHINE_STOP_OK, TEST_DATA_DISK, processor = .Without_Avx) && machine_test(scenario_extended_state_without_xsave[:], BOOT_VOLUME, TEST_OUTPUT_EXTENDED_STATE, MACHINE_STOP_OK, TEST_DATA_DISK, processor = .Without_Xsave)
}
