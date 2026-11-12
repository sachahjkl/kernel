type: Security

**A program no longer reads where the kernel placed its tables**: on a processor with UMIP, `sgdt`, `sidt`, `sldt`, `smsw` and `str` of a program give a protection fault, where they gave the addresses of the segment table and of the interrupt table of the kernel; the kernel now writes its own control registers on each processor (an x87 error and an alignment check are faults of the thread on every machine, no breakpoint of the firmware stays on), and a boot line says whether UMIP is on.
