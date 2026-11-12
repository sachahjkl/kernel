package kernel

import "base:intrinsics"
import op "contract:operation"

// The extended state of the processor: the x87, SSE, AVX and AVX-512
// registers of a thread (docs/ARCHITECTURE.md, "The extended state of the
// processor"). The first processor chooses the state components that the
// kernel saves; each other processor takes the same choice. A component is
// enabled in XCR0 only when the kernel saves it.
//
// The kernel saves the extended state of a thread only when a processor
// leaves it for another thread, and restores it only when a processor
// takes a thread from a queue (schedule.odin). Between the two, the
// registers of the thread stay live through each kernel entry: no code of
// the kernel changes an x87, SSE or AVX register. The build makes the
// kernel with no such instruction, and refuses a kernel that has one
// outside the three procedures of the save and the restore
// (tools/kerneltool/vector_check.odin).

// The area of one thread: the standard form of xsave, with x87, SSE, AVX
// and the three components of AVX-512 at their offsets (1664 + 1024 bytes
// for the last one). xsave and xrstor need an address on 64 bytes.
EXTENDED_STATE_CAPACITY :: 2688

Extended_State_Area :: struct #align (64) {
	bytes: [EXTENDED_STATE_CAPACITY]u8,
}
#assert(size_of(Extended_State_Area) == EXTENDED_STATE_CAPACITY)

// One bit of XCR0 for each component (Intel SDM, volume 1, section 13.1).
Extended_State_Component :: enum u64 {
	X87                = 0,
	Sse                = 1,
	Avx                = 2, // The high halves of ymm0 to ymm15.
	Opmask             = 5, // k0 to k7.
	Zmm_High_Halves    = 6, // The high halves of zmm0 to zmm15.
	Zmm_High_Registers = 7, // zmm16 to zmm31.
}
Extended_State_Components :: bit_set[Extended_State_Component; u64]

AVX_512_COMPONENTS :: Extended_State_Components{.Opmask, .Zmm_High_Halves, .Zmm_High_Registers}
LEGACY_COMPONENTS :: Extended_State_Components{.X87, .Sse}
LEGACY_AREA_SIZE :: 512 // What fxsave writes.

CR4_OSFXSR :: 1 << 9 // The processor saves the SSE registers with fxsave, and programs can use them.
CR4_OSXMMEXCPT :: 1 << 10 // A SIMD floating-point exception is vector 19, not an invalid opcode.
CR4_OSXSAVE :: 1 << 18 // xsave, xrstor and xgetbv work, and CPUID says so to programs.

// The offsets in the start state of a thread.
X87_CONTROL_OFFSET :: 0
MXCSR_OFFSET :: 24
MXCSR_MASK_OFFSET :: 28 // The bits of MXCSR that the processor takes: fxsave writes it.
MXCSR_MASK_DEFAULT :: 0xFFBF // The mask of a processor that writes 0 there (Intel SDM, volume 1, section 11.6.6).
HEADER_OFFSET :: 512 // XSTATE_BV, then XCOMP_BV, then reserved bytes.
X87_CONTROL_START :: 0x037F // Every exception masked, 64-bit precision, round to nearest.
MXCSR_START :: 0x1F80 // Every exception masked, round to nearest.

// The instructions of the save and the restore of a thread.
Extended_State_Form :: enum u8 {
	Fxsave   = 0, // fxsave64 and fxrstor64: the processor has no xsave or no xsaveopt.
	Xsaveopt = 1, // xsaveopt64 and xrstor64.
}

foreign _ {
	// The save of a thread that a processor leaves, and the restore of a
	// thread that a processor takes; also the proofs at boot.
	extended_state_save :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) ---
	extended_state_restore :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) ---
	// The restore, then a read of the x87 control word, MXCSR, the low 8
	// bytes of xmm0 and, with with_avx, bytes 16 to 23 of ymm0, in that
	// order, at read: one routine, so no compiled code runs between.
	extended_state_restore_and_read :: proc "c" (area: ^Extended_State_Area, read: ^[4]u64, with_avx: bool, form: Extended_State_Form) ---
}

// What the first processor chose. Read-only after its setup.
extended_state_form: Extended_State_Form
extended_state_components: Extended_State_Components
extended_state_size: u64 // The bytes of the area that a save writes at most.
// The bits of MXCSR that the processor takes: a restore of an area with
// another bit faults, so a write of Thread_Control is checked against it.
extended_state_mxcsr_mask: u32
// The offset and the size of each component above SSE, from CPUID leaf 0xD:
// each other processor must give the same, since an area is restored on
// any processor.
extended_state_layout: [8][2]u32

// What the processor that runs it can save.
extended_state_supported :: proc "contextless" () -> (with_xsave: bool, components: Extended_State_Components) {
	components = LEGACY_COMPONENTS
	highest, _, _, _ := intrinsics.x86_cpuid(0, 0)
	_, _, features, _ := intrinsics.x86_cpuid(1, 0)
	XSAVE :: 1 << 26
	AVX :: 1 << 28
	if highest < 0xD || features & XSAVE == 0 {
		return false, components
	}
	optimized, _, _, _ := intrinsics.x86_cpuid(0xD, 1)
	if optimized & 1 == 0 {
		return false, components // No xsaveopt.
	}
	low, _, _, high := intrinsics.x86_cpuid(0xD, 0)
	processor_components := transmute(Extended_State_Components)(u64(low) | u64(high) << 32)
	if features & AVX != 0 && .Avx in processor_components {
		components += {.Avx}
		AVX_512_FOUNDATION :: 1 << 16
		if highest >= 7 {
			_, extended, _, _ := intrinsics.x86_cpuid(7, 0)
			if extended & AVX_512_FOUNDATION != 0 && AVX_512_COMPONENTS <= processor_components {
				components += AVX_512_COMPONENTS
			}
		}
	}
	return true, components
}

// extended_state_layout_read gives the offset and the size of each
// component above SSE that the processor that runs it reports.
extended_state_layout_read :: proc "contextless" (components: Extended_State_Components) -> (layout: [8][2]u32) {
	for component in components - LEGACY_COMPONENTS {
		size, offset, _, _ := intrinsics.x86_cpuid(0xD, u32(component))
		layout[int(component)] = {offset, size}
	}
	return
}

// extended_state_first_setup sets the control registers of the extended
// state on the first processor and chooses the components for all
// processors: the widest choice whose area fits the area of a thread.
extended_state_first_setup :: proc "contextless" () {
	with_xsave, supported := extended_state_supported()
	cr4 := control_register_4_read() | CR4_OSFXSR | CR4_OSXMMEXCPT
	extended_state_components = LEGACY_COMPONENTS
	extended_state_size = LEGACY_AREA_SIZE
	if !with_xsave {
		control_register_4_write(cr4 &~ CR4_OSXSAVE)
		extended_state_form = .Fxsave
		return
	}
	control_register_4_write(cr4 | CR4_OSXSAVE)
	candidates := [3]Extended_State_Components{supported, supported - AVX_512_COMPONENTS, LEGACY_COMPONENTS}
	for candidate in candidates {
		extended_control_register_write(0, transmute(u64)candidate)
		// EBX: the size that the components enabled in XCR0 now need.
		_, size, _, _ := intrinsics.x86_cpuid(0xD, 0)
		if size <= EXTENDED_STATE_CAPACITY {
			extended_state_components = candidate
			extended_state_size = u64(size)
			break
		}
	}
	extended_state_layout = extended_state_layout_read(extended_state_components)
	extended_state_form = .Xsaveopt
}

// extended_state_other_setup sets on another processor the control
// registers that the first processor chose. False: this processor cannot
// save the same components in the same form, or takes other bits of MXCSR,
// and must not run threads. A write of Thread_Control is checked against
// the mask of the first processor, and the thread can be restored on any
// processor: a processor that refuses a bit that the first one takes would
// fault in the kernel at that restore. cpu is the record of this processor:
// its buffer of the extended state holds no thread yet.
extended_state_other_setup :: proc "contextless" (cpu: ^Processor) -> bool {
	cr4 := control_register_4_read() | CR4_OSFXSR | CR4_OSXMMEXCPT
	if extended_state_form == .Fxsave {
		control_register_4_write(cr4 &~ CR4_OSXSAVE)
		return extended_state_mxcsr_mask_measure(&cpu.extended_state_written) == extended_state_mxcsr_mask
	}
	with_xsave, supported := extended_state_supported()
	if !with_xsave || !(extended_state_components <= supported) {
		return false
	}
	if extended_state_layout_read(extended_state_components) != extended_state_layout {
		return false
	}
	control_register_4_write(cr4 | CR4_OSXSAVE)
	extended_control_register_write(0, transmute(u64)extended_state_components)
	_, size, _, _ := intrinsics.x86_cpuid(0xD, 0)
	return u64(size) == extended_state_size && extended_state_mxcsr_mask_measure(&cpu.extended_state_written) == extended_state_mxcsr_mask
}

// extended_state_start writes the start state of a new thread: no register
// of another thread, every exception masked.
extended_state_start :: proc "contextless" (area: ^Extended_State_Area) {
	area^ = {}
	(^u16)(&area.bytes[X87_CONTROL_OFFSET])^ = X87_CONTROL_START
	(^u32)(&area.bytes[MXCSR_OFFSET])^ = MXCSR_START
	// XSTATE_BV: x87 and SSE come from the area, every other component
	// starts in its init state (zero). fxrstor does not read the header.
	(^u64)(&area.bytes[HEADER_OFFSET])^ = transmute(u64)LEGACY_COMPONENTS
}

// The areas of the proofs at boot. Only the first processor uses them,
// once, before any program runs.
start_state_proof: [2]Extended_State_Area

// Values that are not the init state, for the proof of the offsets.
PROOF_X87_CONTROL :: 0x027F // 53-bit precision: every exception masked.
PROOF_MXCSR :: 0x3F80 // Round down: every exception masked, no reserved bit.
PROOF_XMM0 :: 0x0123_4567_89AB_CDEF
PROOF_YMM0_HIGH :: 0xFEDC_BA98_7654_3210
XMM0_OFFSET :: 160

// extended_state_prove runs two proofs on the first processor, after its
// setup and before any program runs. A failed proof stops the machine with
// a sentence; a restore that the processor refuses faults here, at boot.
//
// 1. The offsets: it restores an area with an x87 control word, an MXCSR,
// xmm0 and the high half of ymm0 that are not their init state, and reads
// the registers back. So the processor reads these places where the start
// state writes them.
// 2. The start state: it restores the start state and saves it again. This
// shows that the start state does not fault and that the header that the
// save writes has no bit outside XCR0. It does not show the values: x87 and
// SSE in the start state are their init state, and xsaveopt does not write
// a component in its init state; the save goes over a copy of the start
// state, so the bytes that it does not write are the right ones.
extended_state_prove :: proc "contextless" () {
	first := &start_state_proof[0]
	second := &start_state_proof[1]

	with_avx := .Avx in extended_state_components
	extended_state_start(first)
	(^u16)(&first.bytes[X87_CONTROL_OFFSET])^ = PROOF_X87_CONTROL
	(^u32)(&first.bytes[MXCSR_OFFSET])^ = PROOF_MXCSR
	(^u64)(&first.bytes[XMM0_OFFSET])^ = PROOF_XMM0
	if with_avx {
		// The high half of ymm0 is at the start of the AVX component.
		avx_offset := extended_state_layout[int(Extended_State_Component.Avx)][0]
		(^u64)(&first.bytes[avx_offset])^ = PROOF_YMM0_HIGH
		(^u64)(&first.bytes[HEADER_OFFSET])^ = transmute(u64)(LEGACY_COMPONENTS + {.Avx})
	}
	read: [4]u64
	extended_state_restore_and_read(first, &read, with_avx, extended_state_form)
	extended_state_start(first)
	extended_state_restore(first, extended_state_form) // The registers go back to the start state.
	if read[0] & 0xFFFF != PROOF_X87_CONTROL || read[1] & 0xFFFF_FFFF != PROOF_MXCSR || read[2] != PROOF_XMM0 || (with_avx && read[3] != PROOF_YMM0_HIGH) {
		log("kernel: extended state: the processor does not read the area where the kernel writes it: x87 control ", Hex(read[0] & 0xFFFF), ", MXCSR ", Hex(read[1] & 0xFFFF_FFFF), ", xmm0 ", Hex(read[2]), ", ymm0 high ", Hex(read[3]))
		machine_stop(1)
	}

	extended_state_start(first)
	extended_state_start(second)
	extended_state_restore(first, extended_state_form)
	extended_state_save(second, extended_state_form)
	control := (^u16)(&second.bytes[X87_CONTROL_OFFSET])^
	mxcsr := (^u32)(&second.bytes[MXCSR_OFFSET])^
	header := (^u64)(&second.bytes[HEADER_OFFSET])^
	if control != X87_CONTROL_START || mxcsr != MXCSR_START || (extended_state_form != .Fxsave && header &~ transmute(u64)extended_state_components != 0) {
		log("kernel: extended state: the processor does not give back the start state of a thread: x87 control ", Hex(u64(control)), ", MXCSR ", Hex(u64(mxcsr)), ", XSTATE_BV ", Hex(header))
		machine_stop(1)
	}

	extended_state_mxcsr_mask = extended_state_mxcsr_mask_measure(second)
}

// extended_state_mxcsr_mask_measure gives the bits of MXCSR that the
// processor that runs it takes. fxsave writes the mask at each save, also
// on a processor where the threads use xsaveopt, which can skip it. The
// area is any area of the processor that holds no thread.
extended_state_mxcsr_mask_measure :: proc "contextless" (area: ^Extended_State_Area) -> u32 {
	extended_state_save(area, .Fxsave)
	mask := (^u32)(&area.bytes[MXCSR_MASK_OFFSET])^
	return mask == 0 ? MXCSR_MASK_DEFAULT : mask
}

// extended_state_write_refusal says what a write of Thread_Control refuses
// in an area of a thread: what would make xrstor or fxrstor fault in the
// kernel, at the next restore of the thread.
extended_state_write_refusal :: proc "contextless" (area: ^Extended_State_Area) -> (refusal: op.Thread_Write_Refusal, value: u64) {
	return op.extended_state_refusal(area.bytes[:extended_state_size], transmute(u64)extended_state_components, extended_state_mxcsr_mask, extended_state_form != .Fxsave)
}

// extended_state_log writes what the first processor chose: the
// components, what one save writes at most, and the fixed area of each
// thread entry.
extended_state_log :: proc "contextless" () {
	avx := .Avx in extended_state_components ? ", AVX" : ""
	avx_512 := AVX_512_COMPONENTS <= extended_state_components ? ", AVX-512" : ""
	how := extended_state_form == .Fxsave ? "fxsave: the processor has no xsave or no xsaveopt" : "xsaveopt"
	log("kernel: extended state: x87, SSE", avx, avx_512, "; one save writes at most ", extended_state_size, " bytes, in an area of ", u64(EXTENDED_STATE_CAPACITY), " bytes in each thread entry; saved at a switch of threads with ", how)
}
