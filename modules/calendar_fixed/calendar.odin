// The days of the months of the Gregorian calendar, with the correction of the module calendar.
//
// The module calendar forgets the rule of the 400 years. This module has the same export with the same description, and the correct rule: a leap year is a year that 4 divides, except a year that 100 divides and 400 does not. A replacement {calendar, calendar_fixed} gives this module to each module that imports calendar, with no new build of that module.
//
// **What it is for.** It is the correction that the replacement gives: `replace("calendar", "calendar_fixed")` in the console, then each new load of a module that imports calendar gets this module. A program that loaded before keeps what it loaded.
package calendar_fixed

@(rodata)
month_lengths := [12]i64{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// days_in_month gives the count of days of a month, from 1 to 12, of a year. A month out of this range stops the program on a bounds check.
//
// It has the description of the export of calendar, parameter for parameter: that is the condition for a loader to give it in place of calendar. February 2000 has 29 days, February 1900 has 28.
@(export, link_name = "days_in_month")
days_in_month :: proc "c" (month, year: i64) -> i64 {
	days := month_lengths[month - 1]
	if month == 2 && (year % 4 == 0 && year % 100 != 0 || year % 400 == 0) {
		days += 1
	}
	return days
}
