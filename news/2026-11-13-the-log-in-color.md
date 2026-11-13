title: The log shows each value in the color of its kind
date: 2026-11-13
release: next
picture: docs/screenshots/log.png
kind: Shown
guide: docs/TOOLS.md

The window of the log now draws each value of a line in the color of what it is: a number or an address in teal, a size with its unit (the free memory in MiB) in teal, a time with its unit in amber, the name of a program in green, the head of a hash in amber, a status in red. These are the colors of the same kinds on the site. The program that writes a line says what each value is, and the log keeps it beside the text: no text is read for its look. The head of the column of the text is the legend. A line of the kernel in the channel boot, "kernel: boot: firmware: ...", shows from "firmware": its program and its channel are in their own columns. The text on the serial port is the same as before.
