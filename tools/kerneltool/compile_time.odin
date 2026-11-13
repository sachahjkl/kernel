package kerneltool

import "core:strings"

// The compiler writes the time of the compile in the debug information of
// each package, as the value of the constant ODIN_COMPILE_TIMESTAMP. Two
// builds of one source then differ by that number only, and a build is no
// longer the same bytes as the build before. No source of the system reads
// the constant. So the tool writes 0 for it in the LLVM IR, before llc
// makes the object: the time of a build is in no file of the system.

COMPILE_TIME_VARIABLE :: "!DIGlobalVariable(name: \"ODIN_COMPILE_TIMESTAMP\""
COMPILE_TIME_EXPRESSION_START :: " = !DIGlobalVariableExpression(var: "
COMPILE_TIME_VALUE_START :: ", expr: !DIExpression(DW_OP_constu, "

// llvm_ir_without_compile_time gives the LLVM IR with 0 as the value of
// each constant ODIN_COMPILE_TIMESTAMP, and the count of the values that
// it changed. A line of the IR that it does not know stays as it is.
llvm_ir_without_compile_time :: proc(ir: string, allocator := context.allocator) -> (result: string, changed: int) {
	// The numbers of the metadata nodes of the constant: "!208 = distinct
	// !DIGlobalVariable(name: ...". The expression that holds the value
	// names such a node, and can stand before it.
	nodes := make([dynamic]string, context.temp_allocator)
	rest := ir
	for line in strings.split_lines_iterator(&rest) {
		if !strings.contains(line, COMPILE_TIME_VARIABLE) {
			continue
		}
		if end := strings.index(line, " = "); end > 0 && line[0] == '!' {
			append(&nodes, line[:end])
		}
	}
	if len(nodes) == 0 {
		return strings.clone(ir, allocator), 0
	}
	builder := strings.builder_make(0, len(ir), allocator)
	rest = ir
	for line in strings.split_lines_iterator(&rest) {
		written := false
		if start := strings.index(line, COMPILE_TIME_EXPRESSION_START); start > 0 {
			after := line[start + len(COMPILE_TIME_EXPRESSION_START):]
			if value_start := strings.index(after, COMPILE_TIME_VALUE_START); value_start > 0 {
				node := after[:value_start]
				value := after[value_start + len(COMPILE_TIME_VALUE_START):]
				value_end := 0
				for value_end < len(value) && value[value_end] >= '0' && value[value_end] <= '9' {
					value_end += 1
				}
				is_the_constant := false
				for known in nodes {
					is_the_constant ||= known == node
				}
				if is_the_constant && value_end > 0 {
					strings.write_string(&builder, line[:start + len(COMPILE_TIME_EXPRESSION_START)])
					strings.write_string(&builder, node)
					strings.write_string(&builder, COMPILE_TIME_VALUE_START)
					strings.write_string(&builder, "0")
					strings.write_string(&builder, value[value_end:])
					changed += int(value[:value_end] != "0")
					written = true
				}
			}
		}
		if !written {
			strings.write_string(&builder, line)
		}
		strings.write_string(&builder, "\n")
	}
	return strings.to_string(builder), changed
}
