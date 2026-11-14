title: The test checks by count, a measure run measures by time
date: 2026-11-13
release: 0.92.0
picture: none
kind: Shown
guide: docs/TOOLS.md

The programs that show a rate (`clock`, `flow`, `crowd`, `disk`, `locks`, `scheduler`) no longer measure for a fixed time at each start. In a test, each one checks a fixed count of work: 200 000 records through a ring with none lost, one million reads of the time with no kernel entry. The window shows these counts. The rates in one second come from a measure run, which `kerneltool measure` starts with the same modules and with no other load. The machine test also takes each picture when the screen is settled, with no fixed time before it.
