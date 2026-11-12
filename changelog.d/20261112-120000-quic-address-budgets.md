type: Security

**A QUIC server can no longer be stopped by a few dozen real addresses**: the budget of Initial checks of each address can no longer be renewed by addresses that take turns, so 33 hosts no longer stop every new client of `quic_echo`. A new address gets no check while the table of 1024 addresses is busy, and `quic_echo` counts it.
