package quic

// The budgets of the work of new connections (docs/QUIC.md, section 6), and
// the tokens that already took a record.
//
// A budget is a token bucket: it holds at most its depth of units of work,
// it gains its rate of units in each second, continuously, and each piece
// of work takes one unit. A burst can take the depth at once, then the
// rate: no window has a boundary where a burst gets twice the budget.
//
// The server keeps state for an address only after a token opened for it:
// a token opens only for the address and port that received the Retry, so
// a forged source never gets a place in these tables.

// One unit of work in the level of a bucket: the level counts millionths
// of a unit, so a rate per second adds its value in each microsecond.
WORK_UNIT :: 1_000_000

Work_Bucket :: struct {
	level:      u64, // Millionths of a unit of work.
	updated_at: u64, // The time of the last take, in microseconds.
	filled:     bool, // false: the bucket was never used, and starts full.
}

// work_bucket_take takes one unit of work from a bucket, after it gained
// what the time since its last take gives. false: the bucket is empty.
work_bucket_take :: proc "contextless" (bucket: ^Work_Bucket, per_second: int, depth: int, now: u64) -> bool {
	capacity := u64(max(depth, 0)) * WORK_UNIT
	switch {
	case !bucket.filled:
		bucket.level = capacity
		bucket.filled = true
	case now > bucket.updated_at && per_second > 0:
		elapsed := now - bucket.updated_at
		// The time that fills an empty bucket: past it, the product could
		// overflow, and the bucket is full anyway.
		if elapsed >= capacity / u64(per_second) {
			bucket.level = capacity
		} else {
			bucket.level = min(capacity, bucket.level + elapsed * u64(per_second))
		}
	}
	bucket.updated_at = max(bucket.updated_at, now)
	if bucket.level < WORK_UNIT {
		return false
	}
	bucket.level -= WORK_UNIT
	return true
}

// work_bucket_is_full says if a bucket holds its depth at a time: it was
// never used, or the time since its last take refilled it.
work_bucket_is_full :: proc "contextless" (bucket: ^Work_Bucket, per_second: int, depth: int, now: u64) -> bool {
	if !bucket.filled {
		return true
	}
	capacity := u64(max(depth, 0)) * WORK_UNIT
	if bucket.level >= capacity {
		return true
	}
	if per_second <= 0 || now <= bucket.updated_at {
		return false
	}
	return now - bucket.updated_at >= (capacity - bucket.level) / u64(per_second)
}

// The budget of Initial checks of each address whose token opened, in a
// table of SERVER_ADDRESS_BUDGETS places of 32 bytes (32 KiB).
//
// A new address takes a place only when that place holds no information:
// it is free, or its bucket refilled to its depth. A full bucket is the
// state that a new address would get anyway, so moving a place to another
// address never gives more checks than the place would give to one
// address: the table as a whole is a set of buckets, and gives at most the
// sum of their depths at once, then the places times the rate in each
// second, whatever the addresses that rotate through it. When no place can
// be taken, the new address gets no check.
//
// A full bucket is not an address that stopped: it is an address that
// asks less often than the rate. An address that keeps asking faster keeps
// its place. A client that needed one check frees its place 1 s after it,
// and any new address can then take it, the first one to ask. So while
// more than SERVER_ADDRESS_BUDGETS real addresses keep asking, a new
// client gets a place only when it asks before them: the table bounds the
// checks, not the wait of a new client.
SERVER_ADDRESS_BUDGETS :: 1024

Server_Address_Budget :: struct {
	used:    bool,
	address: u32,
	bucket:  Work_Bucket,
}

Address_Budget_Result :: enum u8 {
	Taken, // One check, from the bucket of the address.
	Over_Budget, // The bucket of the address is empty.
	Table_Full, // A new address, and no place holds a full bucket.
}

// server_address_budget_take takes one Initial check from the budget of an
// address.
@(private)
server_address_budget_take :: proc "contextless" (server: ^Server, address: u32, now: u64) -> Address_Budget_Result {
	rate, depth := server.limits.initial_checks_per_address_per_second, server.limits.initial_checks_per_address_depth
	place, free := -1, -1
	for &item, index in server.address_budgets {
		if item.used && item.address == address {
			place = index
			break
		}
		if free < 0 && (!item.used || work_bucket_is_full(&item.bucket, rate, depth, now)) {
			free = index
		}
	}
	if place < 0 {
		if free < 0 {
			return .Table_Full
		}
		place = free
		server.address_budgets[place] = {used = true, address = address}
	}
	if !work_bucket_take(&server.address_budgets[place].bucket, rate, depth, now) {
		return .Over_Budget
	}
	return .Taken
}

// The tokens that took a record: each token takes a record once. The table
// keeps the counter of each one for its lifetime. When it is full and no
// token in it has expired, the token issued first is forgotten: that one
// token can take a record again, from the address and port that it was
// issued to, until it expires.
SERVER_USED_TOKENS :: 64

Server_Used_Token :: struct {
	used:      bool,
	counter:   u64, // The counter of the token: no two tokens of one start have the same.
	issued_at: u64,
}

@(private)
server_token_was_used :: proc "contextless" (server: ^Server, counter: u64) -> bool {
	for item in server.used_tokens {
		if item.used && item.counter == counter {
			return true
		}
	}
	return false
}

@(private)
server_token_mark_used :: proc "contextless" (server: ^Server, counter: u64, issued_at: u64, now: u64) {
	place := -1
	for &item, index in server.used_tokens {
		if !item.used || now - min(item.issued_at, now) > RETRY_TOKEN_LIFETIME {
			place = index
			break
		}
		if place < 0 || item.issued_at < server.used_tokens[place].issued_at {
			place = index
		}
	}
	if server.used_tokens[place].used && now - min(server.used_tokens[place].issued_at, now) <= RETRY_TOKEN_LIFETIME {
		server.counters.used_tokens_forgotten += 1
	}
	server.used_tokens[place] = {used = true, counter = counter, issued_at = issued_at}
}
