package quic

// The budgets of the work of new connections (docs/QUIC.md, section 6), and
// the tokens that already took a record.
//
// A datagram of an unknown client costs the server work before the server
// knows anything of its sender: a Retry to write, a token to open, an Initial
// packet to open. Each kind of work has a budget, so a flood of such datagrams
// takes a bounded share of the processor, and the rest is dropped before any
// cryptography.
//
// A budget is a token bucket: it holds at most its depth of units of work, it
// gains its rate of units in each second, continuously, and each piece of work
// takes one unit. A burst can take the depth at once, then the rate: no window
// has a boundary where a burst gets twice the budget.
//
// The server keeps state for an address only after a token opened for it: a
// token opens only for the address and port that received the Retry, so a
// forged source never gets a place in these tables.

// One unit of work in the level of a bucket: the level counts millionths of a
// unit, so a rate per second adds its value in each microsecond, with no
// division and no rounding.
WORK_UNIT :: 1_000_000

// One token bucket: the state of one budget of work.
//
// The rate and the depth are not in the bucket: each call gives them, from the
// `Server_Limits`. The zero value is a bucket that was never used, and it
// starts full: a server that starts gives its whole depth at once.
Work_Bucket :: struct {
	level:      u64, // The work that the bucket holds now, in millionths of a unit (`WORK_UNIT`): 0 to the depth.
	updated_at: u64, // The time of the last take, in microseconds: the bucket gained nothing since then that `level` counts.
	filled:     bool, // false: the bucket was never used, and starts full at its first take.
}

// work_bucket_take takes one unit of work from a bucket, after the bucket
// gained what the time since its last take gives.
//
// - `per_second`: the rate, in units of work in each second.
// - `depth`: the most units that the bucket holds: the size of a burst.
// - `now`: the time, in microseconds. A time before the last take gains
//   nothing.
//
// **Result**: true when a unit was taken: the caller does the work. false: the
// bucket holds less than one unit, and the caller drops the datagram. A depth
// of 0 always gives false.
//
// ```odin
// if !work_bucket_take(&server.work_buckets[.Retry], 20_000, 2000, now) {
// 	return // Over the budget of Retries: no answer.
// }
// ```
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

// work_bucket_is_full says if a bucket holds its depth at a time: it was never
// used, or the time since its last take refilled it. It changes nothing.
//
// The table of address budgets uses it to find a place that holds no
// information: a full bucket is the state that a new address gets anyway.
//
// - `per_second`, `depth`: the rate and the depth of the bucket, as for
//   `work_bucket_take`.
// - `now`: the time, in microseconds.
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

// The places of the table of address budgets: the budget of Initial checks of
// each address whose token opened, in a table of `SERVER_ADDRESS_BUDGETS`
// places of 32 bytes (32 KiB).
//
// **Why each address has its own budget.** A host with one real address takes
// one Retry, so it has a valid token, and can send Initial packets with it
// that pass the token check and do not open. Without a budget of its own it
// would spend the shared budget of Initial checks, and stop every new client.
//
// **How a place is taken.** A new address takes a place only when that place
// holds no information: it is free, or its bucket refilled to its depth. A
// full bucket is the state that a new address would get anyway, so moving a
// place to another address never gives more checks than the place would give
// to one address: the table as a whole is a set of buckets, and gives at most
// the sum of their depths at once, then the places times the rate in each
// second, whatever the addresses that rotate through it. When no place can be
// taken, the new address gets no check.
//
// **What the table does not bound.** A full bucket is not an address that
// stopped: it is an address that asks less often than the rate. An address
// that keeps asking faster keeps its place. A client that needed one check
// frees its place 1 s after it, and any new address can then take it, the
// first one to ask. So while `SERVER_ADDRESS_BUDGETS` real addresses keep
// asking (one for each place is enough), a new client gets a place only when
// it asks before them: the table bounds the checks, not the wait of a new
// client (docs/QUIC.md, "The budgets of work").
SERVER_ADDRESS_BUDGETS :: 1024

// One place of the table of address budgets: an address whose token opened,
// and its bucket of Initial checks.
Server_Address_Budget :: struct {
	used:    bool, // The place holds an address. false: the place is free.
	address: u32, // The remote address, with no port: every port of one address shares the bucket.
	bucket:  Work_Bucket, // The Initial checks that the address can still take, with the rate and the depth of `Server_Limits` for one address.
}

// What `server_address_budget_take` found for an address: whether the Initial
// packet gets its check.
Address_Budget_Result :: enum u8 {
	Taken, // One check was taken from the bucket of the address: the server goes on to open the Initial packet.
	Over_Budget, // The bucket of the address is empty: the datagram is dropped, and `Server_Counters.over_address_budget` counts it.
	Table_Full, // A new address, and no place is free or holds a full bucket: the datagram is dropped, and `Server_Counters.address_table_full` counts it.
}

// server_address_budget_take takes one Initial check from the budget of an
// address.
//
// - `address`: the remote address of an Initial packet whose token opened.
// - `now`: the time, in microseconds.
//
// An address that has a place takes from its bucket. A new address takes the
// first place that is free or whose bucket is full again, with a new bucket,
// and takes its first check from it. The result says which case came
// (`Address_Budget_Result`). The search reads each place of the table once.
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

// The places of the table of the Retry tokens that took a record: each token
// takes a record once.
//
// A token is good for its lifetime, and whoever sees it on the path can send
// it again from the address of its client. Without this table, such a replay
// would take a record again after the first connection ended. The table keeps
// the counter of each token that took a record, for the lifetime of the token
// (`RETRY_TOKEN_LIFETIME`). When it is full and no token in it has expired,
// the token issued first is forgotten: that one token can take a record again,
// from the address and port that it was issued to, until it expires.
//
// Only a token that took a record has a place, so a flood of Retries does not
// touch the table.
SERVER_USED_TOKENS :: 64

// One place of the table of used tokens: a Retry token that took a record.
Server_Used_Token :: struct {
	used:      bool, // The place holds a token. false: the place is free.
	counter:   u64, // The counter of the token, which is its nonce: no two tokens of one start of the server have the same.
	issued_at: u64, // When the server made the token, in microseconds: the place is free again `RETRY_TOKEN_LIFETIME` after it, when the token no longer opens.
}

// server_token_was_used says if the token with a counter took a record before:
// its counter is in the table of used tokens.
@(private)
server_token_was_used :: proc "contextless" (server: ^Server, counter: u64) -> bool {
	for item in server.used_tokens {
		if item.used && item.counter == counter {
			return true
		}
	}
	return false
}

// server_token_mark_used notes that a token took a record.
//
// - `counter`, `issued_at`: the counter of the token and the time when the
//   server made it, from the token itself.
// - `now`: the time, in microseconds.
//
// It takes the first place that is free or whose token expired. When there is
// none, it takes the place of the token issued first: that token is forgotten
// before its lifetime ended, and `Server_Counters.used_tokens_forgotten`
// counts it.
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
