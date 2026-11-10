package kernel

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
	for index := threads[cpu.current].budget; index != 0; index = budgets[index].parent {
		budgets[index].spent += spent
		budgets[index].spent_total += spent
	}
}

period_start: u64 // The cycle counter at the start of this period.

// The cycles of this period that a budget can use: its part of the length
// of a period, or of the true length when the period is longer.
@(private = "file")
allowance :: proc "contextless" (budget: ^Budget) -> u64 {
	now := cycles_now()
	length := max(cycle_frequency * LIMIT_PERIOD / TICKS_PER_SECOND, now > period_start ? now - period_start : 0)
	// A whole day in one period does not overflow, with 64 processors.
	return budget.amounts.processor * (length / 1000) / 1000
}

// budget_spent says if a budget, or a budget above it, has no processor
// time left in this period.
budget_spent :: proc "contextless" (index: u32) -> bool {
	for at := index; at != 0; at = budgets[at].parent {
		if budgets[at].spent >= allowance(&budgets[at]) {
			return true
		}
	}
	return false
}

// budget_period starts a new period, at a tick of the first processor.
budget_period :: proc "contextless" () {
	if ticks % LIMIT_PERIOD == 0 {
		refreshed := false
		for &budget in budgets[1:] {
			if !budget.live {
				continue
			}
			part := allowance(&budget)
			if budget.spent >= part {
				refreshed = true
			}
			budget.spent -= min(budget.spent, part)
		}
		period_start = cycles_now()
		if refreshed {
			// Threads of these budgets can run again: the idle processors look.
			kick_all()
		}
	}
	if ticks % LOG_PERIOD == 0 {
		for &budget in budgets[1:] {
			budget.logged = 0
		}
	}
}

// budget_log counts one log record of a program. false: a budget has no
// record left in this second.
budget_log :: proc "contextless" (index: u32) -> bool {
	for at := index; at != 0; at = budgets[at].parent {
		if budgets[at].logged >= budgets[at].amounts.log_records {
			budgets[index].refused += 1
			return false
		}
	}
	for at := index; at != 0; at = budgets[at].parent {
		budgets[at].logged += 1
	}
	return true
}
