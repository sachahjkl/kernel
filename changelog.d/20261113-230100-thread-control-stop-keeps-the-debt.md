type: Fixed

**A `Stop` and a `Resume` of `Thread_Control` no longer forgive what a thread owes**: a thread that a `Stop` took out of its run queue came back as a new thread, so a thread that had run more than its share ran again before the threads that waited. It now leaves the queue as a thread that starts to wait, and comes back as a woken thread.
