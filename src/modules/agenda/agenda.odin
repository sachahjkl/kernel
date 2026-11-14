// A module of commands that imports the module calendar.
//
// Each export calls days_in_month of calendar through an import slot: one indirect call. The loader puts calendar in the same program, or the module that a replacement gives in its place: the file of this module does not change, so its hash does not change. The module is also a program that waits: two programs that import calendar at two places share one copy of its code.
//
// **What it is for.** It is the importer of the test of the replacement of an import. The program `imports` loads it with calendar, then with calendar_fixed in place of calendar, and compares: year_days(2000) is 365 with the fault and 366 with the correction, from the same file of agenda.
//
// **Example**, in the console:
//
// ```
// load("agenda")
// year_days(2000)                         365: calendar forgets the rule of the 400 years
// replace("calendar", "calendar_fixed")
// unload("agenda")
// load("agenda")
// year_days(2000)                         366
// ```
//
// The design: (docs/MODULE_CONTRACT.md, "Replacement of an import").
package agenda

import "support:system"

foreign _ {
	days_in_month :: proc "c" (month, year: i64) -> i64 ---
}

// year_days gives the count of days of a year: the sum of the days of its months, from the module calendar.
//
// It makes 12 calls through the import slot, one for each month, so its answer is the answer of the module that the loader put in that slot: 365 for the year 2000 with calendar, 366 with calendar_fixed. It never fails.
@(export, link_name = "year_days")
year_days :: proc "c" (year: i64) -> i64 {
	total: i64
	for month in i64(1) ..= 12 {
		total += days_in_month(month, year)
	}
	return total
}

// month_days gives the count of days of one month of a year, from the module calendar.
//
// - **month**: 1 to 12. Another month makes calendar stop the program on a bounds check: after `load` that program is the caller itself.
// - **year**: any year.
@(export, link_name = "month_days")
month_days :: proc "c" (month, year: i64) -> i64 {
	return days_in_month(month, year)
}

// calls calls days_in_month a count of times and gives the sum of the results: a measure of a call through an import slot.
//
// The months and the years change with each call (the years 2000 to 2006), so the compiler cannot keep one answer. The program `imports` times it to compare a slot that holds calendar with a slot that holds its replacement. A count of 0 or less gives 0.
@(export, link_name = "calls")
calls :: proc "c" (count: i64) -> i64 {
	total: i64
	for index in 0 ..< count {
		total += days_in_month(index % 12 + 1, 2000 + index % 7)
	}
	return total
}

// entry runs agenda as a program: it waits with no end. A program that runs agenda maps the code of calendar that another program of the same starter maps.
//
// The program `imports` starts two such programs from the boot image and reads their page tables: the code pages of calendar are one copy in the two. The program does nothing else and never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	for {
		system.sleep(max(u64))
	}
}
