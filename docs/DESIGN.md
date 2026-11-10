# The design rules

These rules say how a program of this system looks. The owner asked for them on 2026-11-10, after the new boot display: "peut-être extrait en des design rules". They are taken from the boot display (`support/bootscreen/`), which the owner approved. The boot display is the model.

A new graphical program follows these rules. The programs of the desktop that came before do not follow all of them yet: see "State" at the end.

## 1. What is on the screen

- Each thing on the screen is a fact of a record. A display invents nothing.
- Each card has a caption that names its record, for example `Boot_Report.stages`. A person can find the source of each number.
- A record that is all zero is valid. Its card says "not known yet", in the dim color. A card never shows a zero as if it was a measure.
- A size on the screen carries a fact when it can: the width of a stage is its duration, the width of a tile is the size of its module. A form has a least width, so that its name stays readable.
- A step is an interface, not a printed line: a list of steps shows each step with its state ("done", "now", "failed").

## 2. Forms

- Each form is a rectangle. There is no round corner, no circle and no ellipse (owner, 2026-11-10).
- A point or a mark is a square.
- A line is a rectangle that is 1 or 2 pixels thick.
- Lines at an angle are used for one meaning only: a part that has no measure on this scale (the firmware before the line of time).
- There is no shadow and no transparency.

## 3. Surfaces

There are three levels. Each is a constant of the package.

| Level | Color | Use |
|---|---|---|
| Background | `0x0B1018` | Under all cards. A grid of points of 2 pixels, each 24 pixels, lies on it |
| Card | `0x17212E` at the top to `0x111822` at the bottom | The frame of one subject |
| Track | `0x1C2633` | The empty part of a bar, a band or a tube |

- A surface has a color that goes from lighter at the top to darker at the bottom. This is the one sign of depth.
- A card has a border of 1 pixel in its accent, at 28 % at the top and 14 % at the bottom.
- A full part of a bar goes from 120 to 130 % of its color at the top to 78 % at the bottom.

## 4. Color

One color is one concept, as one term is one concept.

| Concept | Color |
|---|---|
| Firmware | `0x8E7CC3` |
| Boot program | `0xE0A040` |
| Kernel | `0x4A9CF0` |
| Program | `0x58D878` |
| Memory | `0x38C0B0` |
| Machine | `0xD070B0` |
| Failed | `0xF06060` |
| Not usable | `0x4A5563` |
| Text | `0xDCE4EC` |
| Dim text | `0x7C8A99` |

- The state of a thing has three colors: the color of the boot program while it starts, the color of a program when it runs, the color "failed" when it failed.
- Two neighbours of one concept take two shades of its color, so that their limit is visible.
- If a thing has an identity (a hash), its color can come from the hash. A thing that changes takes a new color.
- A color never stands alone for a fact: a text or a place says the same fact.

## 5. Text

- One font: Spleen 8x16. Three sizes: 1, 2 and 3 times. No other size.
- The title of a card is in capital letters, in the accent of the card, after a bar of 4 x 16 pixels in the same accent.
- A name is in the dim color. A value is in the text color. A measure of a concept is in the color of that concept.
- A card has at most one number in the large size: the number that the card is about.
- Numbers of one column are aligned on the right, each with its unit.
- A sentence follows the language rules of the project: short, exact, one term for one concept.

## 6. Grid

- The unit is 8 pixels. A position and a size are multiples of 8, or of 4 inside a form.
- A line of text is 16 pixels.
- The space between two cards is 8 pixels. The margin inside a card is 16 pixels. The title of a card takes 40 pixels.

## 7. Cost

- Drawing is `fill` of rectangles with integer arithmetic. No floating point and no image file.
- A display does not wait so that a person can see it. A display that fails stays.
- Each display has a measured draw time in its choice in `docs/FIRST_MILESTONE.md`.

## 8. Decoration

Two things carry no fact: the grid of points on the background, and the blue of the head, which goes darker toward the right. A new decoration needs a decision of the owner.

## State

- The boot display follows all rules.
- The rules live as constants in `support/bootscreen/`. They are not yet in `support/graphics`, so each other program still has its own colors.
- The compositor, the bar, the windows and the programs of the desktop came before these rules. To bring them to the rules is a later step, with the look request of the owner (the gradient and the launcher).
