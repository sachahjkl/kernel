package operation

// The form of each kernel operation: its name, and the name and the form of
// each parameter. The kernel reads the forms to find the error record of an
// operation that failed (kernel/diagnose.odin); a program reads the names to
// write the sentence of an error record. One table for the two.

// The form of one parameter of a kernel operation: what the kernel checks
// on it before the operation, and how a sentence names its value.
//
// The kernel reads it in `kernel/diagnose.odin` to find which argument of a
// failed operation is wrong; `support/sentence` reads it to say the
// argument by its name and its value in its form.
Form :: enum u8 {
	None    = 0, // No parameter.
	Value   = 1, // A number that the operation does not check.
	Handle  = 2, // A handle of `kind` (None: any kind) with `rights`.
	Handle_Or_Zero = 3, // The same, or 0: the caller itself, or no handle.
	Address = 4, // An address in the program.
	Count   = 5, // A count. `limit`: the largest, or 0.
	Flags   = 6, // A set of flags. `limit`: the flags that the operation knows.
	Choice  = 7, // A value of an enumeration. `limit`: the largest.
}

// One parameter of a kernel operation, as `OPERATIONS` describes it.
//
// Example: the first parameter of `Memory_Create` is `{"budget", .Handle,
// .Budget, {.Spend}, 0}`: a budget handle with **Spend**.
Parameter_Form :: struct {
	name:   string, // The name of the parameter, as the comment of the operation names it: "budget", "pages".
	form:   Form, // What the value is.
	kind:   Object_Kind, // For a handle: the kind of object that it must name. `None`: any kind.
	rights: Rights, // For a handle: the rights that it must have.
	limit:  u64, // For a count, a set of flags or a choice: the bound that the comment of `Form` gives. 0: none.
}

// One kernel operation, as a sentence names it: its name and its seven
// parameters, in the order of the values of its command record. A parameter
// with the form `None` is a value that the operation does not take.
Operation_Form :: struct {
	name:       string, // The name of the operation, as `Operation` names it.
	parameters: [7]Parameter_Form, // In the order of the values of the command record.
}

// The form of each kernel operation, by its number. The kernel and the
// sentences of the error records read this one table, so a parameter has
// one name everywhere. A new operation adds its row here.
@(rodata)
OPERATIONS := [Operation]Operation_Form {
	.None = {name = "None"},
	.Log = {"Log", {{"log", .Handle, .Log, {.Write}, 0}, {"address", .Address, .None, {}, 0}, {"length", .Count, .None, {}, 4096}, {"level", .Choice, .None, {}, u64(max(Log_Level))}, {"channel", .Value, .None, {}, 0}, {"channel", .Value, .None, {}, 0}, {"runs", .Count, .None, {}, LOG_CALL_RUN_LIMIT}}},
	.Memory_Create = {"Memory_Create", {{"budget", .Handle, .Budget, {.Spend}, 0}, {"pages", .Count, .None, {}, MEMORY_PAGE_LIMIT}, {"flags", .Flags, .None, {}, 0b1111}, {}, {}, {}, {}}},
	.Memory_Map = {"Memory_Map", {{"memory", .Handle, .Memory, {.Read}, 0}, {"program", .Handle_Or_Zero, .Program, {.Control}, 0}, {"address", .Address, .None, {}, 0}, {"flags", .Flags, .None, {}, 0b111}, {"first", .Count, .None, {}, 0}, {"pages", .Count, .None, {}, 0}, {}}},
	.Memory_Unmap = {"Memory_Unmap", {{"program", .Handle_Or_Zero, .Program, {.Control}, 0}, {"address", .Address, .None, {}, 0}, {}, {}, {}, {}, {}}},
	.Memory_Size = {"Memory_Size", {{"memory", .Handle, .Memory, {}, 0}, {}, {}, {}, {}, {}, {}}},
	.Program_Create = {"Program_Create", {{"budget", .Handle, .Budget, {.Spend}, 0}, {"name", .Address, .None, {}, 0}, {"name_length", .Count, .None, {}, 31}, {}, {}, {}, {}}},
	.Program_Start = {"Program_Start", {{"program", .Handle, .Program, {.Control}, 0}, {"entry", .Address, .None, {}, 0}, {"stack", .Address, .None, {}, 0}, {"context", .Address, .None, {}, 0}, {}, {}, {}}},
	.Program_Stop = {"Program_Stop", {{"program", .Handle_Or_Zero, .Program, {.Control}, 0}, {"code", .Value, .None, {}, 0}, {}, {}, {}, {}, {}}},
	.Program_State = {"Program_State", {{"program", .Handle, .Program, {.Read}, 0}, {"report", .Address, .None, {}, 0}, {}, {}, {}, {}, {}}},
	.Handle_Give = {"Handle_Give", {{"target", .Handle_Or_Zero, .None, {}, 0}, {"handle", .Handle, .None, {.Give}, 0}, {"rights", .Flags, .None, {}, 0}, {}, {}, {}, {}}},
	.Handle_Close = {"Handle_Close", {{"handle", .Handle, .None, {}, 0}, {}, {}, {}, {}, {}, {}}},
	.Interrupt_Read = {"Interrupt_Read", {{"interrupt", .Handle, .Interrupt, {.Read}, 0}, {}, {}, {}, {}, {}, {}}},
	.Device_Create = {"Device_Create", {{"machine", .Handle, .Machine, {.Devices}, 0}, {"kind", .Choice, .None, {}, u64(max(Device_Kind))}, {"a", .Value, .None, {}, 0}, {"b", .Value, .None, {}, 0}, {}, {}, {}}},
	.Inspect = {"Inspect", {{"machine", .Handle, .Machine, {.Inspect}, 0}, {"kind", .Choice, .None, {}, u64(max(Inspect_Kind))}, {"index", .Value, .None, {}, 0}, {"address", .Address, .None, {}, 0}, {"size", .Count, .None, {}, 0}, {}, {}}},
	.Machine_Stop = {"Machine_Stop", {{"machine", .Handle, .Machine, {.Stop}, 0}, {"code", .Value, .None, {}, 0}, {}, {}, {}, {}, {}}},
	.Thread_Create = {"Thread_Create", {{"budget", .Handle, .Budget, {.Spend}, 0}, {"entry", .Address, .None, {}, 0}, {"stack", .Address, .None, {}, 0}, {"parameter", .Value, .None, {}, 0}, {"weight", .Count, .None, {}, WEIGHT_FULL}, {"request", .Count, .None, {}, REQUEST_LIMIT}, {}}},
	.Thread_Stop = {"Thread_Stop", {{"thread", .Handle_Or_Zero, .Thread, {.Control}, 0}, {}, {}, {}, {}, {}, {}}},
	.Thread_State = {"Thread_State", {{"thread", .Handle, .Thread, {.Read}, 0}, {}, {}, {}, {}, {}, {}}},
	.Word_Wait = {"Word_Wait", {{"words", .Address, .None, {}, 0}, {"count", .Count, .None, {}, WORD_WAIT_CAPACITY}, {}, {}, {}, {}, {}}},
	.Word_Wake = {"Word_Wake", {{"word", .Address, .None, {}, 0}, {"count", .Value, .None, {}, 0}, {}, {}, {}, {}, {}}},
	.Budget_Create = {"Budget_Create", {{"budget", .Handle, .Budget, {.Spend}, 0}, {"pages", .Count, .None, {}, 0}, {"programs", .Count, .None, {}, 0}, {"threads", .Count, .None, {}, 0}, {"processor", .Count, .None, {}, 0}, {"log_records", .Count, .None, {}, 0}, {}}},
	.Budget_Read = {"Budget_Read", {{"budget", .Handle, .Budget, {.Read}, 0}, {}, {}, {}, {}, {}, {}}},
	.Handle_State = {"Handle_State", {{"handle", .Handle, .None, {}, 0}, {"memory", .Handle_Or_Zero, .Memory, {}, 0}, {}, {}, {}, {}, {}}},
	.Handle_Revoke = {"Handle_Revoke", {{"handle", .Handle, .None, {}, 0}, {"program", .Handle_Or_Zero, .Program, {.Control}, 0}, {}, {}, {}, {}, {}}},
	.Memory_Physical = {"Memory_Physical", {{"machine", .Handle, .Machine, {.Physical}, 0}, {"memory", .Handle, .Memory, {.Read}, 0}, {}, {}, {}, {}, {}}},
	.Program_Module = {"Program_Module", {{"program", .Handle_Or_Zero, .Program, {.Control}, 0}, {"record", .Address, .None, {}, 0}, {}, {}, {}, {}, {}}},
	.Strategy_Set = {"Strategy_Set", {{"machine", .Handle, .Machine, {.Schedule}, 0}, {"strategy", .Choice, .None, {}, u64(max(Strategy))}, {}, {}, {}, {}, {}}},
	.Memory_Commit = {"Memory_Commit", {{"memory", .Handle, .Memory, {.Write}, 0}, {"budget", .Handle_Or_Zero, .Budget, {}, 0}, {"ranges", .Address, .None, {}, 0}, {"count", .Count, .None, {}, RANGE_TABLE_CAPACITY}, {"flags", .Flags, .None, {}, 0b1}, {}, {}}},
	.Memory_Protect = {"Memory_Protect", {{"ranges", .Address, .None, {}, 0}, {"count", .Count, .None, {}, RANGE_TABLE_CAPACITY}, {"flags", .Flags, .None, {}, 0b111}, {}, {}, {}, {}}},
	.Fault_Handler_Set = {"Fault_Handler_Set", {{"thread", .Handle_Or_Zero, .Thread, {.Control}, 0}, {"end", .Choice, .None, {}, 1}, {"kinds", .Flags, .None, {}, FAULT_KINDS_DELIVERED}, {}, {}, {}, {}}},
	.Fault_Answer = {"Fault_Answer", {{"thread", .Value, .None, {}, 0}, {"serial", .Value, .None, {}, 0}, {"answer", .Choice, .None, {}, u64(max(Fault_Answer_Kind))}, {}, {}, {}, {}}},
	.Events_Set = {"Events_Set", {{"machine", .Handle, .Machine, {.Events}, 0}, {"memory", .Handle_Or_Zero, .Memory, {.Write}, 0}, {"rules", .Address, .None, {}, 0}, {"count", .Count, .None, {}, EVENT_RULE_CAPACITY}, {"records", .Count, .None, {}, EVENT_RING_RECORDS_MOST}, {}, {}}},
	// The rights of the thread handle that every command needs: Inspect; a
	// write needs Write too (thread_control_rights).
	.Thread_Control = {"Thread_Control", {{"thread", .Handle_Or_Zero, .Thread, {.Inspect}, 0}, {"number", .Value, .None, {}, 0}, {"command", .Choice, .None, {}, u64(max(Thread_Control_Command))}, {"address", .Address, .None, {}, 0}, {"size", .Count, .None, {}, 0}, {}, {}}},
}

// The name of each object kind, for the sentence of an error record
// (`errors.Kind.Handle_Kind`).
@(rodata)
OBJECT_KIND_NAMES := [Object_Kind]string {
	.None      = "no object",
	.Memory    = "Memory",
	.Program   = "Program",
	.Interrupt = "Interrupt",
	.Ports     = "Ports",
	.Machine   = "Machine",
	.Thread    = "Thread",
	.Budget    = "Budget",
	.Log       = "Log",
}

// The words of each program state, for the sentence of an error record
// (`errors.Kind.State`).
@(rodata)
STATE_NAMES := [Program_State]string {
	.None    = "no state that the handle shows",
	.Created = "created, and not started",
	.Ready   = "running",
	.Waiting = "waiting",
	.Stopped = "stopped",
}

// The name of each status, as `Status` names it: a program prints it with
// no copy of the enumeration names.
@(rodata)
STATUS_NAMES := [Status]string {
	.Ok            = "Ok",
	.Bad_Operation = "Bad_Operation",
	.Bad_Handle    = "Bad_Handle",
	.Bad_Address   = "Bad_Address",
	.No_Memory     = "No_Memory",
	.No_Slot       = "No_Slot",
	.Bad_State     = "Bad_State",
	.No_Right      = "No_Right",
	.No_Budget     = "No_Budget",
}
