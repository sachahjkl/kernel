type: Fixed

**A reset QUIC stream no longer closes the whole connection**: when a stream was reset while flow control still held back some of its bytes, the reset named the bytes written instead of the bytes sent, and a correct peer closed the connection. The bytes of a stream are now erased from memory when the stream ends.
