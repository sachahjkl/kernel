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
