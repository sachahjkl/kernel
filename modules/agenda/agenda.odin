// A module of commands that imports the module calendar.
//
// Each export calls days_in_month of calendar through an import slot: one indirect call. The loader puts calendar in the same program, or the module that a replacement gives in its place: the file of this module does not change, so its hash does not change.
package agenda

foreign _ {
	days_in_month :: proc "c" (month, year: i64) -> i64 ---
}

// year_days gives the count of days of a year: the sum of the days of its months, from the module calendar.
@(export, link_name = "year_days")
year_days :: proc "c" (year: i64) -> i64 {
	total: i64
	for month in i64(1) ..= 12 {
		total += days_in_month(month, year)
	}
	return total
}

// month_days gives the count of days of one month of a year, from the module calendar.
@(export, link_name = "month_days")
month_days :: proc "c" (month, year: i64) -> i64 {
	return days_in_month(month, year)
}

// calls calls days_in_month a count of times and gives the sum of the results: a measure of a call through an import slot.
@(export, link_name = "calls")
calls :: proc "c" (count: i64) -> i64 {
	total: i64
	for index in 0 ..< count {
		total += days_in_month(index % 12 + 1, 2000 + index % 7)
	}
	return total
}
