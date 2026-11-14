# The bar of the site: three buttons and one menu

## Purpose

The bar is the way from each page to each section of the site. The site has six sections under the home: the docs, the status, the news, the releases, the roadmap and the gallery. The bar names them all, on one line.

What the bar looks like and how the menu behaves is in [`docs/SITE.md`](../../../docs/SITE.md), "The buttons and the menu of the bar".

## Constraints

- **One line of a fixed height.** The bar stays at the top of the window while the page scrolls. The parts under it are placed by its height: the column "On this page", the tree of the documentation, the target of a link. A bar that breaks into two lines covers the start of the page.
- **The line must hold from 720 pixels**, the width where the phone menu ends, with the mark, the name and the search field.
- **Each page is whole with no script.** A section that the reader cannot reach with no script is not in the bar.
- **No cut text, no text over a text.** A panel has a definite width that holds its longest line, and it never passes the edge of the window.
- **The pictures are near.** The gallery is one click from each page.
- **Rectangular forms**, the colors of the site, no new decoration.

## The measure that decided the form

The widths come from the style sheet. The mark and the name take 98 pixels, the search field 224, the paddings of the bar 32, the two gaps between the parts 48. That leaves 318 pixels for the sections on a window of 720 pixels, and about 302 when the window has a scroll bar.

A button is its text and 16 pixels of padding, and 8 pixels stand between two buttons. At about 8 pixels a character, six buttons need 424 pixels: the bar breaks. Four buttons of the same count of characters fit. So the bar has at most four buttons from 720 pixels, and the mark of the menu takes 12 pixels of the fourth.

## The chosen form

**Three buttons: Docs, Gallery, News. One menu, Project: Status, Releases, Roadmap.**

- The rule that decides: a button is what a first reader looks for. What is the system and how does it work (Docs), what does it look like (Gallery), what is new (News). The menu holds the pages that report how the project goes: what is built and what is missing, what each release brought, what is planned. A reader who follows the project opens it; a first reader does not need it.
- The word of the menu is "Project", the name of the group of the glossary that holds the words of these pages.
- The releases and the roadmap are side by side in the menu: the work that is done, then the work that is planned.

**The menu is a `details` element, and its button is its `summary`.** With no script a click, Enter or Space on the button opens and closes the panel. The panel is a card under the button, as a menu of the bar of the desktop: a border of 1 pixel, one row for each section. It lies over the page and moves nothing.

**One mechanism for the two menus.** The site menu, which holds the sections and the search under 720 pixels, is already a `details` element that the style sheet shows open on a wide window, and that the script opens where the style sheet cannot. The menu of the sections uses the same two ways in the other direction: under 720 pixels its panel is shown with no click, in the list of the site menu, under the word of its group. So the phone menu names all six sections.

**The script only adds ways to close**: Escape, a click outside, and a focus that leaves the menu. It is a part of the one script of the site.

**The current mark.** On a page of a section of the menu, the button of the menu has the line of a current button, and the link of the section in the panel is marked. A reader sees where the page is before the menu opens.

**The states of a control.** A button of the bar was a rectangle of the track, and a link under the pointer takes the track: so a button showed nothing under the pointer and nothing while pressed. Each control of the site now has its states from one table and one procedure, in the colors of the desktop of the system: the blue of the title bar at 60 % with the pointer over a button or with the focus, the blue of a chosen row with a white label while it is pressed or open. A line of the panel under the pointer is a chosen row, as a line of a menu of the desktop. A row of a list takes the band of the track. The look is in [`docs/SITE.md`](../../../docs/SITE.md), "The states of a control".

- One table, because a control with states of its own drifts: the fault was that each control had only what its author thought of.
- A state changes a color, never a size: a border that appears moves the text beside it.
- No transition: the site shows a state at once, as the desktop does.
- The rules of the states are the end of the style sheet, so a state wins over a rule of the same weight that gives a control its current mark.

## Refused forms

- **A lighter track under the pointer.** The step from the track to a lighter track is under the contrast that a reader sees at a glance, and it is not a color of the desktop.
- **A line that appears under a button under the pointer.** A line under a button is the mark of the current section: two meanings for one sign.
- **A second line of the bar.** The height of the bar would change with the width of the window, and each part that is placed by that height would need a second rule. A sticky bar of two lines also takes 80 pixels of a small window.
- **Smaller text.** The buttons have the size of the text of the page. A smaller size gains about one button, and the next section breaks the bar again.
- **Icons with no word.** A reader does not know the icon of "Status" or of "Roadmap". The site uses an icon for a kind of value, beside its word, never in the place of a word.
- **A hamburger at every width.** A wide window has the room for the sections that a first reader needs. Behind one button they are two clicks away, and the bar no longer says what the site holds.
- **The gallery reached only from the home.** That was the form before the menu. A reader on a guide had no way to the pictures but through the home.
- **A menu that opens on hover.** It opens when the pointer passes, it has no form for a touch screen, and it needs a script or a fragile rule to stay open.
- **A list inside the list of the bar.** Each list under an item of a navigation of the site is a list of tree lines, and the check of the pages refuses another one. The panel holds three links and is not a tree.
- **A narrower search field.** It gains the room of about one button, and the next section breaks the bar again.
- **Two menus.** Three sections need one panel. A second button costs the room of the gain.

## Subtle points

- **A `details` element that is closed in the file cannot be shown open by every style sheet.** A browser that has `::details-content` shows the content of a closed element; another one needs the script, which sets the element open. With neither, under 720 pixels, the word of the group is a button that opens its three lines: the page stays whole.
- **Under 720 pixels the button of the menu is a word, not a control.** Where the style sheet shows the panel, the button takes no click. The script refuses the click that would close the panel.
- **The panel starts at the left edge of its button.** The button is at the left of the search field, so the panel, 176 pixels wide, ends near 520 pixels on a window of 720. It cannot pass the right edge.
- **The panel is in the stacking of the bar**, which is over the page. In the bar it is over the list of the search.
- **The width of a text depends on the font of the reader.** The site uses the fonts of the system of the reader. The host test computes the bar at 9 pixels a character, wider than the common fonts give, and with a scroll bar. A reader with a much wider font sees the bar on two lines: the page still works.
- **A new section under the home must go in one of the two tables.** A host test fails for a section that is in neither, or in both.
- **The home keeps a door for each section**, with no menu: the home has the room.

## State

Built: the two tables, the navigation, the rules, the part of the script, the states of every control, the host tests.

Not yet seen in a browser. Left: the focus of the keyboard does not move into the panel when it opens; Tab reaches its links in the order of the page.
