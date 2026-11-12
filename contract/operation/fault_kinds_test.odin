#+build !freestanding
package operation

import "core:testing"

// The mask of the delivered kinds names each value of Fault_Kind, and no
// other vector: the enumeration and the mask are one list.
@(test)
the_delivered_kinds_are_the_values_of_the_enumeration :: proc(t: ^testing.T) {
	from_values: u64
	for kind in Fault_Kind {
		from_values |= u64(1) << u64(kind)
	}
	testing.expect_value(t, from_values, FAULT_KINDS_DELIVERED)
	// A set of kinds is the mask of their vectors.
	all: Fault_Kinds
	for kind in Fault_Kind {
		all += {kind}
	}
	testing.expect_value(t, transmute(u64)all, FAULT_KINDS_DELIVERED)
	two := Fault_Kinds{.Divide_Error, .Page_Fault}
	testing.expect_value(t, transmute(u64)two, u64(1 | 1 << 14))
}

// The class of each vector below 32, as the processor defines it for an
// instruction of a program in 64-bit mode, and the vectors that the kernel
// never delivers.
@(test)
the_class_of_each_vector :: proc(t: ^testing.T) {
	expected := [32]Fault_Class {
		0  = .Fault, // divide error
		1  = .Trap, // debug: the trap flag, int1
		3  = .Trap, // breakpoint: int3
		6  = .Fault, // invalid opcode
		11 = .Fault, // segment not present
		12 = .Fault, // stack fault
		13 = .Fault, // general protection
		14 = .Fault, // page fault
		16 = .Fault, // x87 floating point
		17 = .Fault, // alignment check
		19 = .Fault, // SIMD floating point
	}
	for vector in u64(0) ..< 32 {
		testing.expectf(t, fault_kind_class(vector) == expected[vector], "vector %d: %v, not %v", vector, fault_kind_class(vector), expected[vector])
	}
	for vector in ([]u64{2, 4, 5, 7, 8, 9, 10, 15, 18, 20, 21, 29, 30, 31, 32, 48, 63, 64, 128, max(u64)}) {
		testing.expectf(t, fault_kind_class(vector) == .Never_Delivered, "vector %d is delivered", vector)
		testing.expectf(t, !fault_kind_resumes(vector), "vector %d resumes", vector)
	}
}

// Resume: the traps and the page fault only. Every other delivered fault
// runs the same instruction on the same registers again.
@(test)
the_kinds_that_resume :: proc(t: ^testing.T) {
	for kind in Fault_Kind {
		resumes := kind == .Debug || kind == .Breakpoint || kind == .Page_Fault
		testing.expectf(t, fault_kind_resumes(u64(kind)) == resumes, "%v: resumes %v", kind, fault_kind_resumes(u64(kind)))
		if fault_kind_class(u64(kind)) == .Trap {
			testing.expectf(t, fault_kind_resumes(u64(kind)), "the trap %v does not resume", kind)
		}
	}
}

// The argument of Fault_Handler_Set: 0 is page faults only; a set of
// delivered kinds is itself; a bit of a vector that the kernel never
// delivers refuses the whole argument.
@(test)
the_argument_of_the_handler :: proc(t: ^testing.T) {
	pages := Fault_Kinds{.Page_Fault}
	divide := Fault_Kinds{.Divide_Error}
	mask, ok := fault_kinds_of_argument(0)
	testing.expect(t, ok)
	testing.expect_value(t, mask, transmute(u64)pages)
	mask, ok = fault_kinds_of_argument(transmute(u64)divide)
	testing.expect(t, ok)
	testing.expect_value(t, mask, u64(1))
	mask, ok = fault_kinds_of_argument(FAULT_KINDS_DELIVERED)
	testing.expect(t, ok)
	testing.expect_value(t, mask, FAULT_KINDS_DELIVERED)
	for vector in ([]u64{2, 4, 5, 7, 8, 9, 10, 15, 18, 20, 21, 31, 32, 63}) {
		mask, ok = fault_kinds_of_argument(u64(1) << vector | u64(1) << 14)
		testing.expectf(t, !ok && mask == 0, "vector %d accepted", vector)
	}
}

// The record holds the kind and the error code in the words that were
// reserved: its size is the size of a slot of the ring.
@(test)
the_record_keeps_its_size :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Fault_Record), 64)
	testing.expect_value(t, offset_of(Fault_Record, kind), 40)
	testing.expect_value(t, offset_of(Fault_Record, error_code), 48)
}
