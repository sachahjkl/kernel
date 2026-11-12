// The return to a program, with hostile threads (docs/ARCHITECTURE.md, "The
// return to a program").
//
// The kernel returns to a thread with iretq. A thread whose saved state the
// processor refuses there made the processor fault in the kernel, and one
// program stopped the machine. Each case of this program starts a child
// program (this module, with a role) that gives the kernel such a thread.
// The kernel must stop that child as its own fault, or return to it with a
// state that a program may have; the machine goes on, and the next case
// runs.
//
//   1. A syscall in the last two bytes below the half of a program: its
//      return address is 2^47, which is not canonical. The thread holds
//      values in the high halves of its ymm registers when the kernel stops
//      it, so a switch saves them.
//   2. A stack address that is not canonical, held in rsp while the thread
//      waits for the timer.
//   3. The flag nested task, set with popfq before a syscall: the kernel
//      clears it for itself, and the program gets its flags back without it.
//   4. The trap flag, set with popfq right before a syscall: the kernel
//      clears it for itself, takes no trap, and gives it back; the trap then
//      comes in the program, after its first instruction: its own fault.
//   5. A stack address that is not canonical, held at a syscall: the entry
//      saves it without a use of it, and the return refuses it.
package return_fault

import "contract:module"
import op "contract:operation"
import "support:display"
import "support:graphics"
import sets "support:instruction_sets"
import "support:interface"
import "support:random"
import "support:system"

LINE :: interface.TABLE_LINE
WIDTH :: 896
HEIGHT :: 320

VALUE_ROLE :: 0 // The value of the context that gives the role of a child.
VALUE_WITH_AVX :: 1 // 1: the child of the instruction address holds ymm values.

// The last page below the half of a program, and the address of its last
// two bytes.
LAST_PAGE :: u64(op.USER_END) - system.PAGE_SIZE
LAST_INSTRUCTION :: u64(op.USER_END) - 2

// The code with which a child of the trap flag stops itself if no trap came.
TRAP_NOT_TAKEN :: 4

// The codes with which a child of the nested task stops itself.
NESTED_TASK_CLEARED :: 1 // The flag was set before the entry, and clear after it.
NESTED_TASK_NOT_SET :: 2 // popfq did not set the flag: the case did not run.
NESTED_TASK_KEPT :: 3 // The flag came back after the entry.

Role :: enum u64 {
	Parent              = 0,
	Instruction_Address = 1,
	Stack_Address       = 2,
	Nested_Task         = 3,
	Trap_Flag           = 4,
	Stack_At_A_Syscall  = 5,
}

foreign _ {
	jump_to_the_last_instruction :: proc "c" (address: rawptr, with_avx: bool) -> ! ---
	spin_with_a_stack_that_is_not_canonical :: proc "c" () -> ! ---
	syscall_with_nested_task :: proc "c" (before: ^u64) -> u64 ---
	syscall_with_the_trap_flag :: proc "c" () -> u64 ---
	syscall_with_a_stack_that_is_not_canonical :: proc "c" () -> ! ---
}

// One case: what the child gave, and if it is what the kernel must give.
Case :: struct {
	name:      string,
	role:      Role,
	ran:       bool,
	right:     bool,
	code:      u32, // The stop code of the child.
	address:   u64, // The address of its stop report.
}

cases := [5]Case {
	{name = "the instruction address after the last page", role = .Instruction_Address},
	{name = "a stack address that is not canonical", role = .Stack_Address},
	{name = "the flag nested task at a syscall", role = .Nested_Task},
	{name = "the trap flag at a syscall", role = .Trap_Flag},
	{name = "a stack address that is not canonical at a syscall", role = .Stack_At_A_Syscall},
}

program_generator: random.Generator
image: []u8
with_avx: bool

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

// child_instruction_address writes a syscall in the last two bytes of an
// object, maps the object with Execute at the last page below the half of a
// program, and jumps there.
child_instruction_address :: proc "contextless" (holds_ymm: bool) -> ! {
	memory, created := system.memory_create(1)
	if created != .Ok {
		system.stop(10)
	}
	address, mapped := system.memory_map(memory, {.Write})
	if mapped != .Ok {
		system.stop(11)
	}
	page := ([^]u8)(address)
	page[system.PAGE_SIZE - 2] = 0x0F // syscall
	page[system.PAGE_SIZE - 1] = 0x05
	system.memory_unmap(address)
	if _, at_the_end := system.memory_map(memory, {.Execute}, 0, LAST_PAGE); at_the_end != .Ok {
		system.stop(12)
	}
	jump_to_the_last_instruction(rawptr(uintptr(LAST_INSTRUCTION)), holds_ymm)
}

// child_nested_task stops with the code of what it saw.
child_nested_task :: proc "contextless" () -> ! {
	NESTED_TASK :: u64(1) << 14
	before: u64
	after := syscall_with_nested_task(&before)
	switch {
	case before & NESTED_TASK == 0:
		system.stop(NESTED_TASK_NOT_SET)
	case after & NESTED_TASK != 0:
		system.stop(NESTED_TASK_KEPT)
	}
	system.stop(NESTED_TASK_CLEARED)
}

// case_run starts the child of a case, waits for its stop, and reads its
// stop code and its stop report.
case_run :: proc "contextless" (item: ^Case) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = u64(item.role)
	values[VALUE_WITH_AVX] = with_avx ? 1 : 0
	error: module.Load_Error
	program, status := system.program_start(system.image_find(image, "return_fault"), "return_fault child", grants, random.values_with_seed(&program_generator, values), {pages = 256, programs = 1, threads = 1, processor = 200_000, log_records = 10}, nil, nil, {image = image}, &error)
	if status != .Ok {
		system.log("return_fault: ", item.name, ": the child did not start")
		return
	}
	defer system.close(program)
	for deadline := system.time() + 5000; system.time() < deadline; {
		if state, _ := system.program_state(program); state == .Stopped {
			break
		}
		system.sleep(system.time() + 10)
	}
	state, code := system.program_state(program)
	report := system.program_stop_report(program)
	item.ran = true
	item.code = code
	item.address = report.address
	switch item.role {
	case .Instruction_Address:
		item.right = state == .Stopped && code == op.STOP_CODE_RETURN && report.address == u64(op.USER_END)
	case .Stack_Address:
		item.right = state == .Stopped && code == op.STOP_CODE_RETURN && report.address == 0x8000_0000_0000_0000
	case .Nested_Task:
		item.right = state == .Stopped && code == NESTED_TASK_CLEARED
	case .Trap_Flag:
		// A debug exception of the program (vector 1) stops it as its own fault.
		item.right = state == .Stopped && code == op.STOP_CODE_FAULT + 1
	case .Stack_At_A_Syscall:
		item.right = state == .Stopped && code == op.STOP_CODE_RETURN && report.address == 0x8000_0000_0000_0000
	case .Parent:
	}
	system.log("return_fault: ", item.name, ": the child stopped with the code ", system.Hex(u64(code)), ", the address ", system.Hex(item.address), item.right ? string(": as it must") : string(": WRONG"))
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE RETURN TO A PROGRAM", "each child gives the kernel a thread that the processor would refuse at iretq", graphics.COLOR_KERNEL)
	column := interface.column_of(content)
	builder: interface.Text_Builder
	for &item in cases {
		builder.count = 0
		color: graphics.Color = graphics.COLOR_DIM
		if !item.ran {
			interface.text_put(&builder, "not run yet")
		} else {
			interface.text_put(&builder, item.right ? "stopped as its own fault, or returned clean; the machine goes on" : "WRONG: see the log")
			color = item.right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED
		}
		interface.label_value_line(&frame, interface.column_take(&column, LINE), item.name, interface.text_of(&builder), color, 400)
	}
	interface.column_take(&column, 8)
	interface.cell_text(&frame, interface.column_take(&column, LINE), with_avx ? "the child of the instruction address holds values in the high halves of ymm0 to ymm15" : "no AVX here: the child of the instruction address holds no ymm values", graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	switch Role(ctx.values[VALUE_ROLE]) {
	case .Instruction_Address:
		child_instruction_address(ctx.values[VALUE_WITH_AVX] != 0)
	case .Stack_Address:
		spin_with_a_stack_that_is_not_canonical()
	case .Nested_Task:
		child_nested_task()
	case .Trap_Flag:
		syscall_with_the_trap_flag()
		system.stop(TRAP_NOT_TAKEN)
	case .Stack_At_A_Syscall:
		syscall_with_a_stack_that_is_not_canonical()
	case .Parent:
	}
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("return_fault: no random seed in the context")
		system.stop(1)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "return_fault")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		system.log("return_fault: no boot image")
		system.stop(1)
	}
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	with_avx = .Avx in sets.usable_instruction_sets()
	draw(&window)
	right := 0
	for &item in cases {
		case_run(&item)
		if item.right {
			right += 1
		}
		draw(&window)
	}
	if right == len(cases) {
		system.log("return_fault: ok, ", u64(len(cases)), " cases: each child stopped as its own fault or returned with the flags of a program, and the machine goes on")
	} else {
		system.log("return_fault: failed: ", u64(len(cases) - right), " cases of ", u64(len(cases)))
	}
	for {
		draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&drawing, &window)
	}
}
