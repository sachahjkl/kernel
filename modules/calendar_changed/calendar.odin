// The days of the months of a calendar that a parameter chooses.
//
// The export has the name of the export of the module calendar, and another description: one more parameter. A loader refuses this module as the replacement of calendar: a replacement cannot change a description.
package calendar_changed

@(rodata)
month_lengths := [12]i64{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// days_in_month gives the count of days of a month of a year: Gregorian when gregorian is not 0, Julian when it is 0.
@(export, link_name = "days_in_month")
days_in_month :: proc "c" (month, year, gregorian: i64) -> i64 {
	days := month_lengths[month - 1]
	leap := year % 4 == 0
	if gregorian != 0 {
		leap = leap && year % 100 != 0 || year % 400 == 0
	}
	if month == 2 && leap {
		days += 1
	}
	return days
}
