type: Fixed

**A damaged TCP segment no longer ends a connection of `server`**: a segment from the remote of a live connection with a wrong checksum or a malformed option made `server` ask the network service to forget that remote, and the connection ended by a timeout. `server` now releases a remote only when no connection has it. The network service also keeps a listen port taken after a revocation until its endpoint is removed, and ends a Send that waits for the answer of ARP when the grant of its endpoint changes.
