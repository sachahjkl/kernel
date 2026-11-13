type: Fixed

**Keys typed while a line of the console runs keep their meaning**: a line ends when its result is drawn, and the save of the line history no longer holds the keys after it. Escape typed during a line that is in no call of a sandboxed program or of a service now waits in order with the other keys and acts on the edit line; before, it was taken out of order as a stop of the line, so a list that the keys before it opened stayed open.
