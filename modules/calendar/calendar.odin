// The days of the months of the Gregorian calendar.
//
// This version has a fault: it forgets the rule of the 400 years, so the year 2000 has 365 days and February 2000 has 28. The module calendar_fixed corrects it with the same description of each export: the system can give calendar_fixed to each module that imports this one (docs/MODULE_CONTRACT.md, "Replacement of an import").
//
// **What it is for.** It is the module with a fault that the replacement of an import corrects. agenda imports it; the program `imports` and the console show the fault and its correction with no new build of agenda.
//
// Example, in the console: `load("calendar")`, then `days_in_month(2, 2000)` gives 28; the true answer is 29.
package calendar

@(rodata)
month_lengths := [12]i64{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// days_in_month gives the count of days of a month, from 1 to 12, of a year. A month out of this range stops the program on a bounds check.
//
// The fault: a year that 100 divides is never a leap year here, so February 2000 has 28 days.
@(export, link_name = "days_in_month")
days_in_month :: proc "c" (month, year: i64) -> i64 {
	days := month_lengths[month - 1]
	// The fault: a year that 100 divides is not a leap year, even when 400 divides it.
	if month == 2 && year % 4 == 0 && year % 100 != 0 {
		days += 1
	}
	return days
}
