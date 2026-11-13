// A test module with one export. It uses the three things that a loader must
// get right: addresses in data (rebases), constant data, and private data
// that the module writes.
package test_callee

double :: proc "c" (x: i64) -> i64 {return x * 2}
triple :: proc "c" (x: i64) -> i64 {return x * 3}

operations := [2]proc "c" (x: i64) -> i64{double, triple}
calls: i64

// apply gives `operations[operation](x)`, plus the number of calls so far.
@(export, link_name = "apply")
apply :: proc "c" (operation, x: i64) -> i64 {
	calls += 1
	return operations[operation & 1](x) + calls
}
