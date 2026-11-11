// The part of `core:bytes` that the cryptography of `core:crypto` uses: a
// compatibility layer (docs/CRYPTOGRAPHY.md); the names are the names of
// the origin.
package compatibility_bytes

// alias says if two byte ranges share a byte.
alias :: proc "contextless" (a, b: []byte) -> bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	a_start, b_start := uintptr(raw_data(a)), uintptr(raw_data(b))
	return a_start < b_start + uintptr(len(b)) && b_start < a_start + uintptr(len(a))
}

// alias_inexactly says if two byte ranges share a byte and do not start at
// the same byte: an encryption in place is right, a shifted one is not.
alias_inexactly :: proc "contextless" (a, b: []byte) -> bool {
	if raw_data(a) == raw_data(b) {
		return false
	}
	return alias(a, b)
}
