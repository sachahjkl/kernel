# The gallery and the carousel of the site

## Purpose

The machine tests take a picture of the screen for each thing that they show. The site shows these pictures: a reader sees the system before reading a guide. The gallery is the page of every picture, in groups. The carousel is the few pictures that the home shows, one in view.

The details of the pages are in [`docs/SITE.md`](../../../docs/SITE.md), "The gallery".

## Constraints

- A new picture of a machine test must reach the site. Before this design the home had a list of its own, and most pictures of the folder were on no page.
- The home must stay short: it shows a few pictures, not all.
- Each page is whole with no script.
- No text is cut, and no text lies over another text. A caption has a box that grows with its text.
- Nothing moves that the reader did not ask for.
- No layout shift: the page keeps the room of a picture before the picture came.
- The bytes that a reader loads follow what the reader looks at.
- A picture is never shown wider than its pixels.

## The chosen form

**One table is the source.** A row names a file of `docs/screenshots`, its group, its caption, its guide, and whether the home shows it. The gallery shows every row. The carousel shows the rows that the home flag marks, with a stated most count.

**The table is checked against the folder.** Each PNG file of the folder is in one row, or in one line of the excluded files with its reason. The site command stops, and a host test fails, on a file that neither names, on a file that both name, on a row whose file is gone, and on an excluded line with no reason. So the step that adds a picture writes its row.

**A caption is written for the table.** The writer of a row looks at the picture and states what it shows, in one sentence. The caption is also the alt text.

**A thumbnail at one half, by the mean of 2 by 2.** The gallery shows a thumbnail, and the link opens the picture at its full size. The divisor is whole, so each pixel of the thumbnail is the mean of whole pixels. A picture of the screen is text and lines of 1 pixel: the mean keeps a line as a line of half its tone, and a large text keeps its form. The measure that decided it: a thumbnail has about 38 % of the bytes of its picture. The tool writes the thumbnails at each build; the repository holds none.

**The carousel is CSS scroll snap with numbered links.** A row holds every picture, each as wide as the row. The row scrolls sideways and stops at a picture. Above it, one numbered link for each picture leads to the id of its picture. Every picture is in the page. A reader with no script uses a link, the scroll bar, a swipe, or the arrow keys when the row has the focus.

**A small script adds three things**: a numbered link changes the picture with no move of the page, the keys Left, Right, Home and End change the picture, and the link of the picture in view is marked. It sets no style, adds no element, stores nothing and starts no timer.

## Refused forms

- **A second list for the home.** Two lists drift: the home had one, and it named a fifth of the folder.
- **Captions from the file names.** A file name with spaces says nothing that the picture does not say.
- **A scan of the folder with no table.** A picture needs a group, a caption and a guide, and a picture with a fault must stay out with a stated reason.
- **Autoplay.** A picture that changes by itself takes the eye from the text, and a reader who asks for reduced motion must see the same page.
- **A carousel that needs its script.** With no script the reader would see one picture and no way to the others.
- **Radio inputs that choose the picture.** They work with no script, but the pictures are then hidden parts of a form, a screen reader announces a group of options, and a link cannot name a picture.
- **Previous and next buttons that the script adds.** The script would add elements, the page would shift, and the reader with no script would have other controls than the reader with it.
- **A caption over the picture.** It is a text over a picture of text: the rule on texts refuses it, and it hides a part of the screen that the picture shows.
- **The full pictures, scaled by the style sheet.** The gallery would load about 17 MB for a reader who scrolls it whole, against about 6 MB.
- **Nearest as the filter of a thumbnail.** One pixel of each square drops every second row and column: a line of 1 pixel is whole or gone, and each letter loses half of its strokes.
- **A smooth scroll.** A change of picture is a jump. A slide is a move that the reader did not ask for, and it needs a rule for reduced motion.

## Subtle points

- **A definite width, so that a lazy picture has its height.** Each picture has its `width` and its `height` in the page, and the style sheet gives it a width: a share of its box, with a most width. The browser then knows the height before the picture came. With `height: auto` and no width, a picture that loads late has no height, the row of the carousel has no height, and the page shifts.
- **The row has the height of its tallest picture and caption.** The pictures are the items of one flex line. A change of picture moves nothing under the row.
- **With no script, a numbered link also moves the page**, so that the picture is under the bar. The room above a picture keeps the numbered links in view.
- **A file of the folder that git ignores.** `docs/screenshots/pointers.png` is in the folder of a machine that drew it, and git ignores it: it is not a file of the repository. The check reads the folder. On such a machine the check must not ask for a row for that file, and must not let a row name it: an excluded line for it needs a reason of its own kind, "not in the repository", so that a clean checkout, where the file is absent, does not fail on a line whose file is gone.
- **A picture of the table has the size of the screen of the system.** The command stops on another size, because the two widths of the style sheet come from that size.
- **A row with a film shows the film** in the place of the thumbnail, by the procedure of the news, with no autoplay.
- **The gallery is a button of the bar**: see [site_bar.md](site_bar.md).

## State

Built: the table and its check, the page of the gallery, the thumbnails, the carousel of the home and its script, the host tests.

Built also: an excluded line can say that git ignores its file (`not_in_the_repository`), so the check passes on a machine that holds the file and on a clean copy that does not.

Left: a picture for a narrow screen: under the width of a picture, the carousel scales the picture, and its small text is not readable.
