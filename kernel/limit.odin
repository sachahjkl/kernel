package kernel

import "base:intrinsics"

// The limits of a budget: processor time and log records (property 20).
//
// Pages, programs and threads are things that a budget holds: they move
// from a budget to a new budget, and they return. Time does not return, so
// processor time and log records are limits for each second:
//   processor:   microseconds of processor time in each second, on all the
//                processors together. 1 000 000 is one full processor.
//   log_records: records that the budget can write on the log in each second.
// A limit is for a budget and for each budget that came from it: the kernel
// counts what a thread uses in the budget of the thread and in each budget
// above it. A new budget cannot have a limit above the limit of the budget
// that it came from. A budget with the limit 0 has no time: its threads do
// not run.
//
// The kernel counts processor time with the cycle counter, from the moment
// when a processor takes a thread to the moment when it leaves it: the time
// of the kernel entries of the thread is time of the thread. The limit
// holds in each period of 100 ms. What a budget used above its part of a
// period, it has less in the next period: over many periods the limit is
// exact.
//
// A period is 100 ticks, and a tick can come late: a machine that runs
// under another system loses time. The kernel measures the true length of
// each period with the cycle counter. A budget has its part of the true
// length: a late tick takes time from no budget.
//
// No lock protects these counts: each one is an atomic word (docs/
// ARCHITECTURE.md, "Locks of the kernel", "Budgets and the tick"). The tick
// reads the chain of budgets with no lock: `parent` changes only when a
// budget ends, and the slot of a budget that ended is used again only after
// processor_sync to all processors (budget_create).
LIMIT_PERIOD :: 100 // Ticks.
LOG_PERIOD :: 1000 // Ticks.

// budget_charge counts the time of the thread of a processor, up to now.
budget_charge :: proc "contextless" (cpu: ^Processor) {
	now := cycles_now()
	spent := now - cpu.charged_from
	cpu.charged_from = now
	if cpu.current == 0 {
		return
	}
	for index := intrinsics.atomic_load(&threads[cpu.current].budget); index != 0; index = intrinsics.atomic_load(&budgets[index].parent) {
		intrinsics.atomic_add(&budgets[index].spent, spent)
		intrinsics.atomic_add(&budgets[index].spent_total, spent)
	}
}

period_start: u64 // The cycle counter at the start of this period.

// The cycles of this period that a budget can use: its part of the length
// of a period, or of the true length when the period is longer.
@(private = "file")
allowance :: proc "contextless" (budget: ^Budget) -> u64 {
	now := cycles_now()
	start := intrinsics.atomic_load(&period_start)
	length := max(cycle_frequency * LIMIT_PERIOD / TICKS_PER_SECOND, now > start ? now - start : 0)
	// A whole day in one period does not overflow, with 64 processors.
	return budget.amounts.processor * (length / 1000) / 1000
}

// budget_spent says if a budget, or a budget above it, has no processor
// time left in this period.
budget_spent :: proc "contextless" (index: u32) -> bool {
	for at := index; at != 0; at = intrinsics.atomic_load(&budgets[at].parent) {
		if intrinsics.atomic_load(&budgets[at].spent) >= allowance(&budgets[at]) {
			return true
		}
	}
	return false
}

// budget_period starts a new period, at a tick of the first processor.
// Only this processor subtracts from `spent`; the others only add. So
// `spent` is at least the value read when the subtraction happens.
budget_period :: proc "contextless" (now: u64) {
	if now % LIMIT_PERIOD == 0 {
		refreshed := false
		for &budget in budgets[1:] {
			part := allowance(&budget)
			spent := intrinsics.atomic_load(&budget.spent)
			if spent >= part {
				refreshed = true
			}
			intrinsics.atomic_sub(&budget.spent, min(spent, part))
		}
		intrinsics.atomic_store(&period_start, cycles_now())
		if refreshed {
			// Threads of these budgets can run again: the idle processors look.
			kick_all()
		}
	}
}

// budget_log counts one log record of a program. false: a budget has no
// record left in this second. The word `logged` holds the second in its
// high 32 bits and the count of that second in its low 32 bits: a new
// second starts at 0 with no reset by another processor. A record is
// accepted only if each budget of the chain counted it under its limit; a
// refusal takes back the counts that this record added, in the same second
// only. So no budget accepts more records than its limit in one second.
budget_log :: proc "contextless" (index: u32) -> bool {
	second := intrinsics.atomic_load(&ticks) / LOG_PERIOD
	counted: [BUDGET_CAPACITY]u32
	depth := 0
	accepted := true
	for at := index; at != 0 && depth < BUDGET_CAPACITY; at = intrinsics.atomic_load(&budgets[at].parent) {
		budget := &budgets[at]
		for {
			word := intrinsics.atomic_load(&budget.logged)
			count := word >> 32 == second ? word & 0xFFFF_FFFF : 0
			if count >= budget.amounts.log_records {
				accepted = false
				break
			}
			if _, swapped := intrinsics.atomic_compare_exchange_strong(&budget.logged, word, second << 32 | (count + 1)); swapped {
				counted[depth] = at
				depth += 1
				break
			}
		}
		if !accepted {
			break
		}
	}
	if accepted {
		return true
	}
	for at in counted[:depth] {
		budget := &budgets[at]
		for {
			word := intrinsics.atomic_load(&budget.logged)
			if word >> 32 != second || word & 0xFFFF_FFFF == 0 {
				break
			}
			if _, swapped := intrinsics.atomic_compare_exchange_strong(&budget.logged, word, word - 1); swapped {
				break
			}
		}
	}
	intrinsics.atomic_add(&budgets[index].refused, 1)
	return false
}
