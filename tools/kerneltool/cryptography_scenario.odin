package kerneltool

// The module `cryptography` as it ships: the program cryptography_vectors
// imports it and runs the published vectors of each primitive through its
// exports, on the machine (docs/CRYPTOGRAPHY.md).

TEST_OUTPUT_CRYPTOGRAPHY :: BUILD_FOLDER + "/test_output_cryptography.txt"

scenario_cryptography := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"cryptography_vectors\")"},
	{kind = .Wait, text = "cryptography_vectors: ChaCha20-Poly1305 (RFC 8439 2.8.2): passed; a bad input is refused with no byte given"},
	{kind = .Wait, text = "cryptography_vectors: AES-128-GCM (GCM test case 4): passed; a bad input is refused with no byte given"},
	{kind = .Wait, text = "cryptography_vectors: SHA-256 (FIPS 180-4): passed"},
	{kind = .Wait, text = "cryptography_vectors: HMAC-SHA-256 (RFC 4231 2): passed"},
	{kind = .Wait, text = "cryptography_vectors: HKDF-SHA-256 (RFC 5869 A.1): passed"},
	{kind = .Wait, text = "cryptography_vectors: X25519 (RFC 7748 5.2, 6.1): passed; a bad input is refused with no byte given"},
	{kind = .Wait, text = "cryptography_vectors: Ed25519 (RFC 8032 7.1 test 1): passed; a bad input is refused with no byte given"},
	{kind = .Wait, text = "cryptography_vectors: Ed25519 (RFC 8032 7.1 test 2): passed; a bad input is refused with no byte given"},
	// The measure record quotes this line: a run that passed holds it.
	{kind = .Wait, text = "cryptography_vectors: seal ChaCha20-Poly1305: "},
	{kind = .Wait, text = "cryptography_vectors: one call of an export of the module, through its import slot: "},
	{kind = .Wait, text = ": 8 of 8 vectors passed"},
	{kind = .Front, text = "cryptography_vectors"},
	{kind = .Shot, text = "cryptography_vectors"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

cryptography_tests_run :: proc() -> bool {
	return machine_test(scenario_cryptography[:], BOOT_VOLUME, TEST_OUTPUT_CRYPTOGRAPHY, MACHINE_STOP_OK, TEST_DATA_DISK)
}
