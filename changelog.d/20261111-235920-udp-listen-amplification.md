type: Security

**The network service limits what a UDP listen grant sends to an unproven address**: at most 3 times the bytes that came from the remote, until the program marks it validated with the new command `Validate`; a send no longer keeps a remote admitted.
