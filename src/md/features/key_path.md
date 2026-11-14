# The path of a key: no queue drops a record in silence

A key goes through four queues between the keyboard and the program that reads it. The rule of the system is that none of them loses a key in silence. The queues, their capacities and their log lines are in [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The path of a key". This file records where the rule comes from and why it has two forms.

## The fault that made the rule

A machine test typed one line, and the line never ran. The log named no place. The investigation read the path of a key and found this:

- The line was 44 key records: a key is two records, and a key with Shift is four.
- Two queues on the path were rings of 32 records: from the input service to the compositor, and from the compositor to a window.
- At each of them, the writer sent a record and did not read the answer of the send. A full ring dropped the record with no count and no line.
- A third queue dropped in silence too, and a fourth wrote one line for its first loss only.
- A full ring drops the end of a burst. Enter was record 43 of 44, so the line had no Enter, and the console wrote nothing.

The cause was never proven for that run: no counter existed that could name the place. The failing run was about ten times slower at that step than a passing run. A reader that stalls while its writer runs is what fills a ring of 32 records.

So the fault was two faults. A queue lost a record. And the system could not say which queue.

## The rule, in two forms

For each queue on the path, one of two forms holds.

1. **Back pressure.** When the writer can wait, a full queue stops the writer. Nothing is lost.
2. **A stated bound and a counted refusal.** When the writer cannot wait, the queue has a capacity with a reason. Each refusal is counted. The log has one line when a loss begins and one line with the count when it ends.

Which form a queue takes follows from one question: what stops when the writer waits.

- **The input service can wait.** It must not read a byte that it cannot send. A byte that it does not read stays in the keyboard controller, and the device holds the bytes after it. The back pressure reaches the keyboard, and the tool that types, with no new signal: the tool already waits for the status bit of the controller.
- **The compositor cannot wait for a window.** One program that does not read must not stop the desktop. So the compositor keeps the records that a ring refused, for each window, and sends them in order before any newer record. The bound of that queue is stated, and a refusal past it is counted.
- **The terminal cannot wait for its program.** Its first thread also draws the window. Its queue has a stated bound and a counted refusal.

## The refused forms

- **A larger ring alone.** A capacity of 1024 records makes the loss need a longer stall. It does not make it impossible, and it keeps the silence. The capacity is not the fault: the unread answer of the send is.
- **One line of the log for each lost record.** A loss comes in bursts. The log gets one line at the start of a loss period and one at its end.
- **Pointer records in the queue of the keys.** A move of the pointer with the same buttons has no order: only the newest place counts. A newer move replaces the move that waits, and takes no place of the queue of the keys. A key and a change of a button have an order and wait in the queue.
- **Records that follow the focus.** A key was typed for the window that had the focus when it arrived. A change of the focus moves no record.

## The subtle points

- **No wait can form a cycle.** The input service waits only for the compositor. The compositor waits for no program: each of its sends gives its answer at once. The terminal and the console wait for no program before them on the path.
- **The compositor waits for room only on a ring that is exactly full.** A program writes the read counter of its own ring. A false count must not make the compositor run with no end.
- **The count of the compositor was a false proof.** The compositor counted a key record before it sent the record to the window. A caller that read the count concluded that the window had the key. The counts are now separate: sent, unread, waiting, refused.
- **The condition of the tool.** "The keyboard controller holds no byte" means "the input ring took each record" only because of the back pressure. It depends on a setting of the virtual keyboard controller of QEMU that is off by default: with it on, the status bit stays clear for a time after each byte. See [`docs/TOOLS.md`](../../../docs/TOOLS.md), "How the tool sends input and waits".
- **The echo of the line is the last proof.** The console writes the line on the log before it runs it. After the keys of a typed line, the tool waits for that echo. A lost Enter then fails at the step that typed, not minutes later at the next wait.
- **The test must not depend on speed.** The test of the rule is a window that reads nothing while keys arrive, then reads: each key arrives in order, or the log names the count that was refused.

## State

Built: the two forms on each of the four queues, the counts as exports of the compositor, the log lines of a loss period, the host tests of the queue of the compositor, and the machine test that types a line while a call holds the console.

Left: the machine test does not fill the queue of the compositor, because no program of the test stops reading its window for a time that the test controls. The one wait of the compositor holds a fixed count of words; with about 30 windows it is full.
