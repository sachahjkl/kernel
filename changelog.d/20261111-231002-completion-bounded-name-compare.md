type: Security

**Long names of one length no longer slow each key of the console**: the order of two names in the completion list read whole names, up to 64 times for each name, so a service with long export names of one length made each key slow; it now reads at most 256 bytes of a name, and one key has a fixed bound.
