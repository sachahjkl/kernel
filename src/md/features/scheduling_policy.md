# The policy of scheduling: the placement of a thread, and a share for each program

The scheduler is in the kernel, and its strategies are a closed set (`docs/DECISIONS.md`, D-226). A custom scheduling has this form: a program that holds a right sets the weights, the budgets and the placement of threads at a slow rate, and the kernel applies them at each tick with its own strategy. No code of a program runs on the path of the scheduler (`docs/DECISIONS.md`, D-227).

This file records the design of two layers of that policy. The placement of a thread on processors is built in the kernel. A share of processor time for each budget is not built in the kernel: it is a policy of the program `scheduler` (`docs/DECISIONS.md`, D-233).

The rules that a caller reads are in [`docs/SCHEDULING.md`](../../../docs/SCHEDULING.md), "The placement of a thread" and "The schedule of a live thread".

## The lesson that both layers start from

The first layer of the policy lets a program write the weight and the request of a live thread. Four designs of it failed their review, each with the same cause: the program chose the moment and the direction of a write while the strategy kept a history of the thread. A thread gained processor time by the moment of its writes, or an honest thread waited for seconds.

The rule that was built takes that choice away (`docs/DECISIONS.md`, D-231): a write by the program only lowers, and changes no field of the strategy. Only the holder of the machine handle with Schedule and Inspect raises, and a raised thread starts as a new thread.

So a design of a policy layer answers one question first: which history does a write convert, and who chooses its moment.

## The placement of a thread

### Purpose

The placement is the set of the processors that can run a thread. It is the mitigation that the properties name for side channels between two programs on one core: the holder of Schedule keeps two programs on separate processors. It also lets a program keep a thread on one processor for its own speed.

### The chosen form

- **No new kernel operation.** Two commands of the control of a thread read and write the placement, with the three ways to name a thread and the rights of the schedule commands.
- **A set of processors is one word of 64 bits.** The kernel has at most 64 processors, so one word names each one.
- **Two sets, not one: the set and its limit.** A set that a thread chose for itself is a choice of speed. A limit is a policy. With one field, a service that narrows its own thread gives that narrow set to each program that it starts. With two, a new thread gets the limit of its creator only, as it gets the weight limit.
- **The rule is the rule of the schedule.** A program, and the holder of a thread handle with Control, only narrow the set. The holder of the machine handle with Schedule and Inspect writes any set inside the limit, and writes the limit. A set with no processor of the machine is refused: a thread with no processor never runs, and that is a stop, which has its own right.
- **One byte on the hot line of the thread.** The hot line had 6 free bytes: a word of 64 bits does not fit, one byte does. The byte says "restricted". A thread that never gets a placement costs one test of one byte of a line that the path already read, and no new cache line. Zero is the default: a new record is not restricted.
- **No history is converted.** A thread that leaves its processor moves with the procedure that the balance already runs for each thread. A program only narrows, so one thread commands at most one move for each processor less in its life. This is why the cause of the four failed designs is absent here.

### The invariant

The home of a thread is in its set, or the thread is on the processor of its home.

- A thread in a list whose home leaves its set moves at once, in one section under the run locks of the two queues. No state "ready, in no list, on no processor, not held" appears: a change of strategy skips that state, and a stop relies on its absence.
- A thread that runs on a processor that leaves its set moves at its next pass through the scheduler, at most one time slice later.
- The test of a pick from another queue, under the two run locks, is the authority. Each other read of a set is a hint with no lock: a wrong read costs one wake of an idle processor that finds nothing.

### The refused forms

- **An interrupt to the other processor at a write.** An interrupt ends the turn of the thread that runs there when it arrives, and that can be a thread of another program. The wake preemption has a rate limit for this; a placement write would be a second way with no limit. A holder that must know when the thread left reads the thread report.
- **A new argument of the creation of a thread.** A program that wants a narrow new thread writes its placement after the creation. The thread can run one turn on the wider set first. The set is the program's own choice, so nothing depends on that turn.
- **A silent change of a set that is partly outside the limit to another set.** A write through the machine handle keeps the part inside the limit. An empty part is refused: a silent change hides a mistake of the holder.
- **The topology of the processor in the kernel.** The kernel does not know which processors are siblings of one core. The holder can find them itself: it places its own thread on each processor in turn and reads the processor identification there. The topology stays in the policy.

### The fault that this design found

The balance tried one other queue only: the busiest. A queue whose threads the processor cannot take stopped the balance, and a processor went idle while threads waited in a third queue. The fault existed before the placement, with a budget that has no processor time: its threads stay ready in one queue, which is the busiest for ever. The balance now tries the next queue when a move gives no thread. One pick takes at most one pair of run locks for each other processor, where it took one.

### What the placement does not give

- Two cores share the last level cache. A set of processors does not divide it.
- A thread that a program created just before the write of the limit of its creator keeps the old limit. The holder writes each thread of the program, reads the thread report again, and repeats.
- A service that starts programs gives its own limit to them. To start a program inside a limit, the service starts it from a thread that has that limit.
- Up to one time slice passes between the write and the move of a thread that runs.
- Interrupts and the tick of the kernel run on each processor for all programs.
- A program can keep a thread on one processor where a thread of another program also runs. This is not a new capability: a program with one thread for each processor is on each core already. The limit that the holder writes is the control.

## A share for each budget

### Purpose

Give two programs equal parts of the machine when both want it, and let each one use the whole machine when the other sleeps. The processor limit of a budget does not do this: it is a cap, and it stops a budget also when the processors are idle.

### The numbers that decided

One case, by arithmetic on the rules of the code, not measured: 4 processors, a program with 32 threads that compute with no end, and a program with one such thread. With equal shares the single thread can use 1.0 processor.

| Method | Change of the kernel | The single thread gets |
|---|---|---|
| No policy | none | 0.12 |
| A cap of 3 processors on the large program | none | about 0.32, and one processor idle when the other program sleeps |
| The holder of Schedule writes the weight "full weight / count of threads" to each thread of the large program | none | 0.80 |
| A share for each budget in each queue, with a fixed weight in each queue | about 500 lines | 0.50 |
| The same, with the weight of a group divided between the queues by its load | much more | 0.80 |

The smallest kernel form gives less than the policy that a program can run today. The kernel form that gives as much is the complex one. No form reaches 1.0 without a balance by weight, which the kernel does not have: the balance counts threads.

### The chosen form

The program `scheduler` runs the policy with no change of the kernel. One round reads the thread report of each program, counts the threads that are ready or that ran since the last round, and writes the weight and the weight limit of each thread through the machine handle. A program is a budget here, because the loader gives each started program its own budget. The measure decides the rest.

### The refused forms

- **The weight of a group divided between the queues.** It needs a sum of the load of a group that each processor writes at each enqueue: a cache line that two processors write on a fast path, which the data rules of the kernel forbid. That weight also changes at each wake, wait and placement of a thread of the group. A program chooses those moments, so the kernel converts a history at a moment that a program chose: the cause of the four failed designs.
- **A fixed weight in each queue, now.** It makes each procedure of two strategies work on two levels: about 400 lines more in the code that needed five reviews for one rule of 40 lines. And it gives 0.50 where the policy outside gives 0.80. A program with threads in each queue has one full share in each queue; this form does not close that.

### Where the policy outside is weak

The holder writes at a slow rate. When 31 of 32 threads of a program sleep, the one thread that runs has a small weight until the next round. With an idle processor it loses nothing. With each processor busy, the program gets too little for one round. A raise of a weight also starts the thread as new. A measure must say if this matters.

### The form to build if the measure asks for it

One level, fixed at creation: a budget can be a share group, and its threads are one entity in each queue.

- The share is one more argument of the creation of a budget. No write of a live budget exists, so no sequence of writes exists for a review to search.
- It needs the right Spend on the parent only. A group has at most the weight of one thread, so to make a group is a change that lowers.
- A budget under a group cannot be a group. Without this rule a program inside a group makes a second group and has two entities.
- A thread never enters a group after its creation.
- Not checked in the design: the lock order between the frame lock and the run lock when the budget of a group ends while its threads are in lists.

A smaller change is near and not designed: a write of the processor limit of a live budget. The limit is a filter, not a history, so it has no conversion.

## State

Built: the placement of a thread, with the correction of the balance. Not built: the policy of a share in the program `scheduler`, and its measure. The kernel gets no share for a budget.
