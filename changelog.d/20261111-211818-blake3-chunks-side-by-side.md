type: Changed

**BLAKE3 hashes four chunks at a time**: in an input of more than 4096 bytes, the four chunks of each subtree of four chunks are compressed side by side in the SSE2 registers, with the same hash as before. The root service checks the hash of each module and resource at its start with it.
