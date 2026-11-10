// A program that writes lines to its terminal as fast as it can.
//
// Each line has four runs of text with four styles: a number, a level, a
// name, a text. The program sends no escape sequence: the style of a run
// is a field of its record. The status has the count of lines.
package flood

import "../../system"
import "../../terminal"

STATUS_LINES :: 1 << 16 // The lines between two statuses.
ROUND :: 100_000_000 // The lines of one round of the status.

Level :: struct {
	text: string,
	tone: terminal.Tone,
}

@(rodata)
levels := [?]Level{{" info    ", .Good}, {" info    ", .Good}, {" debug   ", .Dim}, {" info    ", .Good}, {" warning ", .Warning}, {" debug   ", .Dim}, {" info    ", .Good}, {" error   ", .Bad}}

@(rodata)
names := [?]string{"scheduler ", "memory    ", "ring      ", "compositor", "storage   ", "network   ", "loader    ", "terminal  "}

@(rodata)
texts := [?]string {
	"  the thread 4 took the processor 2 after a wait of 12 microseconds",
	"  a memory object of 64 pages returned to its budget",
	"  one wake for 2048 records: the reader continued",
	"  the surface 3 changed: one rectangle of 800 x 16 pixels",
	"  the block 81 244 has the hash 6437b3ac38465133",
	"  the packet 7 of the connection 12 arrived in order",
	"  the module has 14 exports and 3 imports: each import has a type",
	"  the line left the view: the terminal draws only what the window shows",
	"  a program gave a handle with the right Read",
	"  the page table of the program has no page that is write and execute",
	"  the queue was full: the writer waited for the reader",
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	output, ok := terminal.open(ctx)
	if !ok {
		system.log("flood: no terminal")
		system.stop(1)
	}
	system.log("flood: ok")
	digits: [10]u8
	for &digit in digits {
		digit = '0'
	}
	for number: u64 = 1;; number += 1 {
		// Add 1 to the decimal number.
		for place := len(digits) - 1; place >= 0; place -= 1 {
			if digits[place] != '9' {
				digits[place] += 1
				break
			}
			digits[place] = '0'
		}
		level := levels[number * 7 / 3 % len(levels)]
		terminal.line(
			&output,
			{string(digits[:]), {tone = .Number}},
			{level.text, {tone = level.tone, flags = level.tone == .Bad ? {.Reverse} : {}}},
			{names[number / 3 % len(names)], {tone = .Accent}},
			{texts[number * 5 / 2 % len(texts)], {}},
		)
		if number % STATUS_LINES == 0 {
			terminal.status(&output, "lines written", number % ROUND, ROUND, {tone = .Good})
		}
	}
}
