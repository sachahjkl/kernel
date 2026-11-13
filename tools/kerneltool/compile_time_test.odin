package kerneltool

import "core:testing"

// Two builds of one source differ by the time of the compile only: after
// the change they are the same text. The expression stands before its
// variable, as the compiler writes it, and a constant of another name
// keeps its value.
@(test)
the_time_of_a_compile_is_not_in_the_llvm_ir :: proc(t: ^testing.T) {
	first :=
		"!206 = !DIGlobalVariableExpression(var: !300, expr: !DIExpression(DW_OP_constu, 42, DW_OP_stack_value))\n" +
		"!207 = !DIGlobalVariableExpression(var: !208, expr: !DIExpression(DW_OP_constu, 1794609658063181000, DW_OP_stack_value))\n" +
		"!208 = distinct !DIGlobalVariable(name: \"ODIN_COMPILE_TIMESTAMP\", scope: null, type: !154, isLocal: false, isDefinition: true, align: 8)\n" +
		"!300 = distinct !DIGlobalVariable(name: \"PAGE_SIZE\", scope: null, type: !154, isLocal: false, isDefinition: true, align: 8)\n"
	second :=
		"!206 = !DIGlobalVariableExpression(var: !300, expr: !DIExpression(DW_OP_constu, 42, DW_OP_stack_value))\n" +
		"!207 = !DIGlobalVariableExpression(var: !208, expr: !DIExpression(DW_OP_constu, 1794610141720057000, DW_OP_stack_value))\n" +
		"!208 = distinct !DIGlobalVariable(name: \"ODIN_COMPILE_TIMESTAMP\", scope: null, type: !154, isLocal: false, isDefinition: true, align: 8)\n" +
		"!300 = distinct !DIGlobalVariable(name: \"PAGE_SIZE\", scope: null, type: !154, isLocal: false, isDefinition: true, align: 8)\n"
	expected :=
		"!206 = !DIGlobalVariableExpression(var: !300, expr: !DIExpression(DW_OP_constu, 42, DW_OP_stack_value))\n" +
		"!207 = !DIGlobalVariableExpression(var: !208, expr: !DIExpression(DW_OP_constu, 0, DW_OP_stack_value))\n" +
		"!208 = distinct !DIGlobalVariable(name: \"ODIN_COMPILE_TIMESTAMP\", scope: null, type: !154, isLocal: false, isDefinition: true, align: 8)\n" +
		"!300 = distinct !DIGlobalVariable(name: \"PAGE_SIZE\", scope: null, type: !154, isLocal: false, isDefinition: true, align: 8)\n"
	first_result, first_changed := llvm_ir_without_compile_time(first, context.temp_allocator)
	second_result, second_changed := llvm_ir_without_compile_time(second, context.temp_allocator)
	testing.expect_value(t, first_result, expected)
	testing.expect_value(t, second_result, expected)
	testing.expect_value(t, first_changed, 1)
	testing.expect_value(t, second_changed, 1)
	// An IR with no debug information has no such constant: it is not changed.
	plain := "define void @entry() {\n  ret void\n}\n"
	plain_result, plain_changed := llvm_ir_without_compile_time(plain, context.temp_allocator)
	testing.expect_value(t, plain_result, plain)
	testing.expect_value(t, plain_changed, 0)
}
