# The scroll bar

## Purpose

A view that shows a part of a longer content has a scroll bar: it says where the view is, and the pointer moves the view with it. The system and the site show the same scroll bar, drawn from one description.

The form before was a flat rectangle on a track, drawn again in each program, with no pointer. A reader did not see it as a control, and it was not one.

## Constraints

- **One standard.** The form is the scroll bar of the desktop shell that the design of the system comes from (the project `shojiwm-desktop`: `crates/shell/src/ui/scroll.rs`, and the same colors in `gtk-theme/_scroll-bar-colours.scss`). Its geometry, its colors and its states are taken as they are. The site had a form of its own before (`docs/DECISIONS.md`, D-222).
- **One description for two drawers.** The system draws rectangles and gradients into a draw table. The site writes a style sheet. Both must show the same numbers, and a change of one number must change both.
- **No blend.** A draw of the system is opaque ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "2. Forms"). The standard has one translucent line.
- **No state in a program.** A program must get the pointer on its scroll bar with one call, and keep nothing between two frames.
- **No wait in a test.** A held arrow button repeats in time. A test of it must not wait.

## The chosen form

**One table.** `support/graphics/scroll_bar.odin` holds the sizes, the places of the stops of each gradient and the colors of the dark and of the light form. `support/interface/scroll_bar.odin` draws from it. `tools/kerneltool/site_style.odin` writes the variables of the style sheet from it. The rules of the style sheet hold no size and no color: a host test refuses `px`, `#` and `gradient(` in them.

**The parts**, along the bar: an arrow button, the track, an arrow button. The thumb lies on the track.

| Number | Value | From the standard |
|---|---|---|
| Thickness of the bar, side of an arrow button | 17 pixels | `THICKNESS` |
| Border of the track, of a button, of the thumb | 1 pixel | `border(1.0)` |
| Least thumb | 8 % of the track | `MINIMUM_THUMB` |
| Grip | 4 lines of 7 by 1 pixels, 1 pixel apart, on a thumb longer than 20 pixels | the grip of `bar` |
| Stops of the track | 0, 50, 100 % | `horizontal_gradient` of the track |
| Stops of the thumb | 0, 45, 55, 100 % | `horizontal_gradient` of the thumb |
| A held arrow button | repeats after 400 ms, then each 60 ms | `REPEAT_AFTER`, `REPEAT_EVERY` |

**The gradients go across the bar**: from the left to the right of a vertical bar, from the top to the bottom of a horizontal one. The draw record has both directions, with two colors each. A gradient of three or four stops is two or three records, each from the place of one stop to the place of the next; two neighbours share the pixel of their common stop.

**The states** are those of the standard. At rest: the track, the thumb with its quiet border and its grip, and two triangles with no button under them. Lit, when the pointer is over the bar or the thumb is held: each arrow button has a border and a fill, and the thumb has the blue border, the blue fill and the light grip. Hot: the arrow button under the pointer is blue. Pressed: a darker blue for a held button and for a held thumb.

**The inner line of the thumb** is white at 12 % in the standard (40 % in the light form). The system draws the color that this blend gives over each stop of the fill, as an opaque line. The site writes the translucent white: a browser blends it.

**The input** is in the element. A press on an arrow button moves the view by one line. A press on the track moves it by one page. A press on the thumb holds it, and the thumb follows the pointer until the button goes up, also outside the bar. The interface state keeps the held part: one button is down at a time, so one scroll bar at most is held, and a program keeps nothing.

**The repeat of a held button** reads the clock of the frame. A frame carries the time of the system in milliseconds, and the element compares it with the time of the next step. A test gives each frame its time as a number.

**The press is where the button went down.** One frame can hold a press and the moves after it. The input keeps the place of the press beside the place of the pointer: a press on the thumb followed by a fast move is a drag, not a press on the track where the pointer ended.

## Where the form leaves the standard, and why

- **An arrow button moves the view by one line**, not by a tenth of the content. A line is the unit that a reader of a text follows.
- **The thumb has a least length of 8 pixels**, beside the 8 % of the standard. On a short track 8 % is less than a border, a line and a place for the pointer.
- **A bar shorter than two buttons and a least thumb has no arrow button.** The completion list of the terminal can be one row high. The track takes the whole bar.
- **The triangle is rows of 1, 3, 5 and 7 pixels.** The standard draws a character of a font at 7 pixels. The system draws rectangles, as it draws its icons.
- **The site cannot light the whole bar.** A style sheet reaches a part of a scroll bar only under the pointer. On the site the thumb is hot when the pointer is over the thumb, and a button when the pointer is over that button.
- **The site has a least thumb of 21 pixels.** A style sheet cannot remove the grip of a short thumb, so each thumb is long enough for its grip.

## What it changes in the design rules

The scroll bar is a decoration that the design rules did not have, and it has three exceptions to them. Each is stated in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The scroll bar".

- Its gradients go across, where the sign of depth of a surface goes from the top down.
- Its thickness is 17 pixels, which is not on the grid of 8. It is odd so that the grip and the point of a triangle are on its middle line. A caller places it so that the bar and the gap before it are a multiple of 8.
- Its colors are its own: gray-blue tones that no concept has.

## Refused forms

- **A flat bar.** A rectangle of one color on a track says where the view is. It does not say that the pointer can move it, and the pointer could not.
- **A drawing in each program.** The terminal, the lists and the palette each drew a bar of their own, of 2 or 8 pixels. A change of the form was three changes, and none had the pointer.
- **An overlay bar that hides.** A bar that shows only while the view moves takes no room, and a reader cannot find it. The bar is always there, as the standard states for its desktop.
- **Round corners.** The standard has a radius of 3 pixels for the thumb and 2 for a button in one of its themes, and 0 in the theme of this design (`$scroll_radius` in `gtk-theme/_kernel.scss`). The system draws square corners: rectangular forms are the preference of the design, and the draw table has no round rectangle.
- **A blend for the inner line.** One translucent record kind for one line of one element. The opaque color of the blend is the same pixels.
- **A state of the bar in each program.** A program would keep the held part and the time of the next step for each of its bars. The interface state holds them once.
- **A second table for the site.** The site had its own colors, mixed from the colors of the page. They were near the standard and not the standard.
- **A grid thickness of 16 pixels.** The grip of 7 pixels and the point of a triangle then have no middle column, and the form is no longer the standard.

## Subtle points

- **A window gets one pointer event when the pointer leaves it.** The compositor sent the pointer only while it was over the surface. A bar at the edge of a window then stayed lit when the pointer left by that edge. The compositor now sends one event more, outside the surface, and one when another window takes the front.
- **A program that draws only after a change** asks the element if the pointer needs a frame (`scroll_bar_wants_frame`), and wakes for a held button at the time that the interface state holds (`window_scroll_bar_wake`). A frame for each move of the pointer over the text would make a view of the terminal for nothing.
- **A held scroll bar that a frame does not draw** takes no step: the time of the next step is cleared, so a program that wakes for it sleeps again.
- **A thumb that the pointer did not move keeps its unit.** The place of a thumb is coarser than the units of a long content: a press on the thumb with no move must not shift the view.
- **The scroll bar takes no key and is not in the order of Tab.** The keys of a view belong to the element that owns the view.
- **The list with a choice has a view that follows its choice.** Its scroll bar moves the choice to the last line of the view that the pointer asks for.
- **At rest the standard is quiet.** The border of the thumb has 2.1 to 1 on the track (2.5 in the light form), and the grip 1.7 to 1 on the thumb (2.7). The parts that the pointer lights have 3 to 1 or more, and a host test holds those.

## State

Built: the table, the element in both directions, the terminal (the lines, with the pointer; the completion list, shown only), the program `manual` (the text, with the pointer), the list with a choice (with the pointer), the list of rows and the palette (shown only), the style sheet of the site in both forms, the host tests, and a case of the machine scenario on the scroll bar of the console.

Left: the pointer on the scroll bar of the palette and of the completion list, whose choice another party owns; a wheel, which the input service does not read; the list of the modules of `manual`, which has no scroll bar.
