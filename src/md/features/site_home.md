# The home of the site: a line of time, charts, and a press on the heron

## Purpose

The home is the one page that shows the system: it does the tour. Every other page is documentation. A reader who lands on it decides in one screen or two whether the system is worth a longer look.

So each section of the home must be worth a look by itself. A section that only repeats a record in small boxes or in a flat sentence costs room and gives nothing: the record has its own page.

What each section looks like is in [`docs/SITE.md`](../../../docs/SITE.md), "The home".

## Constraints

- **Each fact comes from a record.** A stage and its time are a line of a log. A bar is a number of a log. A release is the changelog. The home types no number.
- **Each page is whole with no script.** A bar, a card and a state are markup and rules of the style sheet.
- **No cut text, no text over a text**, at each width from 360 pixels. A phone has no pointer: what a reader must know is readable with none.
- **A scale never lies.** A width that is not in proportion says so in words, beside it.
- **No style attribute in a page.** A width that comes from a number is an attribute of an SVG rectangle.
- **Rectangular forms**, the colors of the concepts, no new decoration. A line at an angle is allowed where it says a fact.
- **Nothing moves that the reader did not ask for**, and nothing moves for a reader who asks for reduced motion.

## What each section is for

| Section | What it gives a first reader |
|---|---|
| The head | The mark, the name, one sentence, and a door to each section |
| News | What is new, in three cards |
| What it is | The rest of the lead: what the system is |
| The start of the machine | Where the time of a start goes, and who takes it |
| The boot image | What the system holds, by size |
| Measured | A comparison that a reader sees at once: bars of one unit |
| The carousel | What the system looks like |
| The newest release | How far the work is, and what the last release brought |

## The chosen forms

### A card starts at its top

The cards of the news shared the rows of one grid, so that their titles and their pictures stand in line. The text had the last row. A card with no picture then kept an empty row of the height of the picture of its neighbour, and its text sat at the bottom.

The rule is general: the content of a card starts at its top, and no empty room stands between two parts of a card. A card with no picture puts its text in the row of the pictures. A grid whose cards do not share rows gives each card its own height.

Refused: cards of the news with no shared rows. The titles and the pictures of a row then stand at different heights, a fault that was corrected before.

### The start: two bars on stated scales

The stages were seven boxes of one size. A box said a name and a time, and its size said nothing: the firmware, which takes nine tenths of the start, had the box of a stage of half a millisecond.

A line of time gives each stage a width that is its time. One bar cannot show both facts that matter: the firmware takes 91 % of the start, and the six stages of the system then share 26 pixels of a phone.

So the line has two bars. The first is the whole start on one scale, with no least width: it says where the time goes. The second is the stages after the first one, on a larger scale: it says how the system spends its part. Two lines at an angle join the part of the first bar to the ends of the second. A sentence at each bar states its scale, and the second states its least width of a stage.

Refused forms:

- **A logarithmic scale.** It has no zero, and a length on it is not a time: two stages of one time have two lengths. A reader of a bar compares lengths, so the picture would lie while its axis is correct.
- **One bar with a least width for each stage.** The six short stages take room from the firmware, which then looks shorter than it is.
- **A break in the bar of the firmware.** A break hides how much longer the firmware is, which is the first fact of the picture.
- **The name of a stage inside or over its segment.** A segment of 2 % of a phone is 6 pixels wide: a name over it is a text over a text, and a leader line for each of seven names crosses the others. The names are rows under the bars, each with a square in the color of its segment.

### The cards of the stages: one place, no script

A reader wants more than a name: what the stage does, which code runs it, the line that gives its time, and the guide. Each stage has a card with these.

One card shows at a time, in one place beside the rows. All the cards are in one cell of a grid: the cell has the height of the tallest, so a change of card moves nothing. The card of the row that has the focus shows; the card of the row or of the segment under the pointer shows before it; a card under the pointer stays.

Refused forms:

- **A card that opens under its row.** Each move of the pointer down the rows opens a card and pushes the rows under the pointer.
- **A card over the page, placed at the pointer.** It needs a script for its place, and near an edge it leaves the window or covers the row that it explains.
- **A card that shows only under the pointer.** A phone has no pointer, and the pointer cannot reach a link of a card that closes when it leaves the row. The focus holds the card, and a card under the pointer holds itself.
- **A `details` element for each stage.** It works with no script, but it is a click for each stage, and an open card moves the rows.

### Measured: a chart or nothing

The home showed three cards that each quoted one whole line of a log. A line of a log is a record: it is exact, and it is not a picture. The page of the measured numbers already shows each line with its conditions.

The rule: the home shows a measure only as a chart whose bars have one unit and one scale from zero. Two measures of today are such charts: the kernel entries in one second with 1, 2 and 4 programs, and the time of one glyph by five ways. A chart is drawn only when its line holds every number, in the unit of the chart. With no chart, the section is absent.

Refused forms:

- **Bars of several measures on one axis.** Kernel entries, nanoseconds and megabytes a second have no common scale.
- **One bar for a number alone.** A bar with nothing beside it compares nothing.
- **A chart of a measure over the releases, today.** The measure record holds one run and each run replaces it. A history drawn now would be invented.

### The newest release: one large value

A sentence gave the number, the date and two counts in one weight. The band gives the number as its one large value, the counts in the weight of a value, and the first changes by their bold summaries, each a link to the change. The rule of one large number for a card holds: the counts are not large.

Refused: the whole list of the changes. The home stays short, and the page of the releases has the list.

### A press on the heron

The heron plays by itself, with still times. A reader who presses it expects an answer at once. The first press plays the dash, the animation that leaves the window and comes back: it is the clearest answer. Each next press plays the next animation of the rule of the choice, so presses walk the round.

A press during an animation does nothing. Refused: a press that cuts the animation (the heron would jump back to its place from the middle of a move), and a press that waits for the end (the answer comes when the reader has stopped waiting).

For a reader who asks for reduced motion the heron is not a control: a control that does nothing is worse than a picture.

## Subtle points

- **The term is "stage"**, not "phase": the glossary has it, and the log of the kernel names each one.
- **The rules of the cards have no weight.** Each is inside `:where()`, so the order of the rules decides which card shows. A rule with a weight, added later, breaks the order: two cards then show in one cell, a text over a text.
- **A hidden card is hidden, not removed.** A removed card gives its room back, and the cell changes its height.
- **The rules name a stage by its place.** The style sheet has rules for 12 stages. A thirteenth stage has a row and a segment, and its card shows only where every card shows.
- **The text of a stage is typed, its time is not.** The table of the texts is keyed by the name that the kernel logs. A stage that the kernel renames loses its text and keeps its time; a host test fails for a stage of the log with no text.
- **A segment on the light page is darker than its accent.** An accent on white is under the contrast of a form that carries a fact. Each accent has a shade for a form on the light page.
- **A chart reads its numbers from the words of a line.** A program that changes the words of its line removes the chart from the home; it never draws a wrong bar.
- **The animation of the first press is a constant of the tool**, written into the table of the script. The script holds no name and no number of an animation.
- **The box of the heron is in the page, the control is made by the script.** With no script nothing answers a press, so nothing says that a press does something.

## State

Built: the rule of a card, the line of time with its cards, two charts, the band of the release, the press on the heron, the host tests.

Not yet seen in a browser. Left: a history of each measure over the releases, which needs a measure record that keeps the numbers of each release.
