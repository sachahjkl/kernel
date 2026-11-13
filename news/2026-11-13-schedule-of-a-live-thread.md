title: The share of a thread changes while it runs
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/SCHEDULING.md

A weight and a request of a thread can now change while the thread runs. The weight is the share of the thread on a processor. The request is the length of the turns that it asks for. Before, a program gave both only when it created the thread. Someone outside the kernel chooses the values, and the kernel applies them with its own scheduling strategy: no code of a program runs when the kernel picks a thread. A program only lowers the weight and the request of its own threads. Only the machine handle with the right Schedule, which the system gives to the program `scheduler` only, raises them, for any thread; a thread with a raised weight starts again as a new thread. That handle also sets a weight limit: the thread, and each thread that it creates, then stays at or under that weight. The program `scheduler` writes the weights 1, 2 and 4 to 12 threads that run, and checks that the heavier weight gets more time under the fair strategy and EEVDF. It also checks that the kernel refuses each raise by the program.
