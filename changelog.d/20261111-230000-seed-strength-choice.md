type: Added

**A program chooses how strong its random seed must be**: a key drawn with `random.fill_for_a_key` names the least seed strength that the program accepts (weak, processor or entropy), and a weaker seed gives the error "the random seed of this program has the strength ..." with nothing made; QUIC and TLS ask for processor at least.
