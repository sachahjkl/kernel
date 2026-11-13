title: A program sets the share of a thread that runs
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/SCHEDULING.md

A program can now change the weight and the request of a thread while the thread runs. The weight is the share of the thread on a processor. The request is the length of the turns that it asks for. Before, a program gave both only when it created the thread. The program chooses the values, and the kernel applies them with its own scheduling strategy: no code of a program runs when the kernel picks a thread. A program changes its own threads. The machine handle with the right Schedule, which the system gives to the program `scheduler` only, changes any thread, and sets a weight limit: the thread, and each thread that it creates, then stays at or under that weight. A change keeps what a thread owes to the others, so no change gives a thread more than its share. The program `scheduler` writes the weights 1, 2 and 4 to 12 threads that run, and checks that the heavier weight gets more time under the fair strategy and EEVDF. It also checks that 1000 rounds of writes under a limit give no weight above the limit.
