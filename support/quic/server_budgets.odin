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

// The budget of Initial checks of each address whose token opened. A table
// of addresses: a new address takes a free place, or the place that was
// used the longest time ago, whose bucket has refilled the most.
SERVER_ADDRESS_BUDGETS :: 32

Server_Address_Budget :: struct {
	used:    bool,
	address: u32,
	bucket:  Work_Bucket,
}

// server_address_budget_take takes one Initial check from the budget of an
// address.
@(private)
server_address_budget_take :: proc "contextless" (server: ^Server, address: u32, now: u64) -> bool {
	place, oldest := -1, -1
	for &item, index in server.address_budgets {
		if item.used && item.address == address {
			place = index
			break
		}
		if oldest < 0 || !item.used || (server.address_budgets[oldest].used && item.bucket.updated_at < server.address_budgets[oldest].bucket.updated_at) {
			oldest = index
		}
	}
	if place < 0 {
		place = oldest
		server.address_budgets[place] = {used = true, address = address}
	}
	return work_bucket_take(&server.address_budgets[place].bucket, server.limits.initial_checks_per_address_per_second, server.limits.initial_checks_per_address_depth, now)
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
