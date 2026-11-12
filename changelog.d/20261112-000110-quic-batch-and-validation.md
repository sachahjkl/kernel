type: Fixed

**Two datagrams of a new QUIC connection that arrive together are both taken**: `quic_echo` lost the second one, and the client waited for its probe timeout. A connection whose client came back just after the server released it is now validated by the network service, so it is no longer held to 3 times the bytes that its client sent.
