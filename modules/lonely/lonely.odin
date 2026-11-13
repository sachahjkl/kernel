// A module of commands whose import is not in the boot image.
//
// It imports the module test_callee, that the build makes and the boot image does not hold. A loader finds an import only in what the program was granted: it refuses this module with the hash of the missing import.
//
// **What it is for.** It is the negative case of a load: an import that no grant holds. `load("lonely")` in the console fails with "error: cannot load lonely" and the error of the load, which names the import test_callee and its hash; no part of lonely runs. A loader never searches a path or another program for a module.
package lonely

foreign _ {
	apply :: proc "c" (operation, x: i64) -> i64 ---
}

// twice gives what apply of the module test_callee gives for the operation 0: two times the integer, plus its count of calls.
//
// It never runs from the boot image: the load of lonely fails first.
@(export, link_name = "twice")
twice :: proc "c" (x: i64) -> i64 {
	return apply(0, x)
}
