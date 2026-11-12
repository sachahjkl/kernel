type: Changed

**The pictures of the screen are compressed PNG files**: the kernel tool writes each PNG file with the encoder of the Odin standard library, so a picture of 1024 by 768 pixels is no longer 2.36 MB of stored data. The same pixels give the same bytes. `kerneltool screenshots compress` converts the pictures that are not compressed yet, with no machine, and checks each pixel of each converted file.
