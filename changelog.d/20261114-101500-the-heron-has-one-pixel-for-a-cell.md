type: Changed

**The pictures of the heron of the site have one pixel for a cell**: the page gives a cell its size, 8 pixels on the home, with no smoothing. The sprite sheet of the animations goes from 3072 by 992 pixels to 384 by 124, and from about 99 000 bytes to about 6 000; the home shows the picture of 24 by 24 pixels of the bar in place of a picture of 192 by 192; the icon of the tab is cut from the same sheet, so the home loads three files for its heron in place of five. A cell of the heron of the home is now one color: before, each of its 64 pixels took the gradient at its own place.
