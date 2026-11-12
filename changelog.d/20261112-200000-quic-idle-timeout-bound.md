type: Fixed

**A QUIC server frees the connection of a client that went silent at its idle timeout**: a client that vanished while the server had data in flight kept its connection, and its place in the table of `quic_echo`, for about two hours, because each unanswered probe pushed the idle timeout further. It now ends after 30 s, whatever the probes. A replayed packet can no longer keep a silent connection alive, a server can no longer be started with no idle timeout, and `quic_echo` logs how long each idle end took against its bound.
