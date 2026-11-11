// The retention rule of the versions of an object (docs/ARCHITECTURE.md,
// U5, "Versions"): each version is kept for 10 minutes; after that, the
// newest version of each hour, until the version is one day old; after
// that, the newest version of each day. Pure code: the storage service
// applies it, and the host tests check it.
//
// The times are the time since the format of the disk, in milliseconds,
// until the system has a date. An hour and a day are counted from the
// format: the buckets do not move from one application to the next, so a
// version that the rule keeps stays kept until it changes zone.
package storage_retention

KEEP_ALL_MILLISECONDS :: 10 * 60 * 1000
HOUR_MILLISECONDS :: 60 * 60 * 1000
DAY_MILLISECONDS :: 24 * HOUR_MILLISECONDS

// keeps says, for the times of the versions of one object, the oldest
// first, which versions the rule keeps at the time `now`. keep has the
// length of times. It gives the count of the versions to thin.
keeps :: proc "contextless" (times: []u64, now: u64, keep: []bool) -> (thinned: int) {
	last_hour, last_day := max(u64), max(u64) // The bucket of the last version kept in each zone.
	for index := len(times) - 1; index >= 0; index -= 1 {
		time := times[index]
		age := now > time ? now - time : 0
		switch {
		case age < KEEP_ALL_MILLISECONDS:
			keep[index] = true
		case age < DAY_MILLISECONDS:
			bucket := time / HOUR_MILLISECONDS
			keep[index] = bucket != last_hour
			last_hour = bucket
		case:
			bucket := time / DAY_MILLISECONDS
			keep[index] = bucket != last_day
			last_day = bucket
		}
		if !keep[index] {
			thinned += 1
		}
	}
	return thinned
}

// DATE_SECONDS_LIMIT is the first second of the year 10000: a date at or
// after it is no date that a clock gives, and it is not used.
DATE_SECONDS_LIMIT :: u64(253402300800)

// age gives the age of a version in milliseconds: the smaller of its age in
// the time since the format and its age in the date. The time since the
// format counts only the time when a machine ran, so it never makes a
// version older than it is; the date counts the time when no machine ran,
// but a clock can be wrong on one start and right on the next (an empty
// battery), and then each version of the wrong start would look years old.
// A date of 0 is no date. A version whose time or date is after now has
// the age 0.
//   now_time, version_time: milliseconds since the format.
//   now_date, version_date: seconds since 1970 (UTC).
age :: proc "contextless" (now_time, version_time: u64, now_date, version_date: u64) -> u64 {
	by_time := now_time > version_time ? now_time - version_time : 0
	if now_date == 0 || version_date == 0 || now_date >= DATE_SECONDS_LIMIT || version_date >= DATE_SECONDS_LIMIT {
		return by_time
	}
	by_date := now_date > version_date ? (now_date - version_date) * 1000 : 0
	return min(by_time, by_date)
}

// rule_now gives the time that keeps measures from: the date in
// milliseconds when it is known, else the time since the format. The time
// of a version for keeps is rule_now minus its age.
rule_now :: proc "contextless" (now_time: u64, now_date: u64) -> u64 {
	return now_date != 0 && now_date < DATE_SECONDS_LIMIT ? now_date * 1000 : now_time
}
