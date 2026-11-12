// The formats of the principals (docs/PRINCIPALS.md): the name of a store
// of a principal, the name of a principal, the passphrase, and the file in
// which the program `unlock` keeps the record of a named principal, with its
// secret keys sealed under a key that Argon2id derives from the passphrase.
//
// No allocator and no kernel operation: the host tests run each procedure
// (principals_test.odin). The root service, `unlock` and the console use
// the same procedures.
package principals

// Principal 0 is the machine. Its record exists at each boot, and its
// session needs no unlock.
MACHINE :: 0
MACHINE_NAME :: "machine"
// The records that the root service holds: principal 0 and one named
// principal. Several named principals on one machine are not built.
PRINCIPAL_CAPACITY :: 2

// The bytes of the name of a principal: three values of a ring record, with
// a zero byte after it.
NAME_LIMIT :: 23
PASSPHRASE_LEAST :: 8
PASSPHRASE_LIMIT :: 128

// The context values of the program `unlock`. 0 to 4 are the roles that the
// root service gives (the store: 3).
VALUE_CREATE :: 5 // 1: create the principal named at VALUE_NAME; 0: unlock the principal of the file.
VALUE_NAME :: 6 // 6, 7 and 8: the name, 24 bytes with zero bytes after it.

// The key derivation: Argon2id (RFC 9106) with the first parameter set of
// the OWASP password storage cheat sheet: 19 MiB, 2 passes, 1 lane. A file
// with other parameters is refused: no file names its own cost.
DERIVATION_MEMORY_KIBIBYTES :: 19 * 1024
DERIVATION_PASSES :: 2
DERIVATION_MEMORY_PAGES :: DERIVATION_MEMORY_KIBIBYTES / 4

SALT_SIZE :: 16
NONCE_SIZE :: 12
TAG_SIZE :: 16
KEY_SIZE :: 32
PUBLIC_KEY_SIZE :: 32
// The two secret keys, sealed together: the Ed25519 seed (to sign grants)
// and the X25519 scalar (to unlock documents).
SECRET_KEYS_SIZE :: 64

// The file of a named principal: the object FILE_OBJECT in the store of
// `unlock`. The offsets, in bytes; each number is little-endian.
FILE_OBJECT :: "principal"
FILE_MAGIC :: "PRINCIPL"
FILE_FORMAT :: u32(1)
OFFSET_MAGIC :: 0 // 8 bytes.
OFFSET_FORMAT :: 8 // u32.
OFFSET_MEMORY :: 12 // u32: the KiB of Argon2id.
OFFSET_PASSES :: 16 // u32.
OFFSET_NAME_LENGTH :: 20 // u8.
OFFSET_NAME :: 21 // NAME_LIMIT bytes, zero bytes after the name.
OFFSET_SIGNING_PUBLIC_KEY :: OFFSET_NAME + NAME_LIMIT // 44: Ed25519.
OFFSET_UNLOCK_PUBLIC_KEY :: OFFSET_SIGNING_PUBLIC_KEY + PUBLIC_KEY_SIZE // 76: X25519.
OFFSET_SALT :: OFFSET_UNLOCK_PUBLIC_KEY + PUBLIC_KEY_SIZE // 108.
OFFSET_NONCE :: OFFSET_SALT + SALT_SIZE // 124.
// The sealed secret keys and their tag. The bytes before them are the
// additional data of the seal: a change of the name, of a public key, of the
// salt or of a parameter makes the open fail.
OFFSET_SEALED :: OFFSET_NONCE + NONCE_SIZE // 136.
SEALED_SIZE :: SECRET_KEYS_SIZE + TAG_SIZE
FILE_SIZE :: OFFSET_SEALED + SEALED_SIZE // 216.
#assert(FILE_SIZE == 216)

Principal_File :: struct {
	name:               [NAME_LIMIT]u8,
	name_length:        int,
	signing_public_key: [PUBLIC_KEY_SIZE]u8,
	unlock_public_key:  [PUBLIC_KEY_SIZE]u8,
	salt:               [SALT_SIZE]u8,
	nonce:              [NONCE_SIZE]u8,
	sealed:             [SEALED_SIZE]u8,
}

File_Problem :: enum u8 {
	None,
	Wrong_Size,
	Wrong_Magic,
	Wrong_Format,
	Other_Parameters,
	Bad_Name,
	Bytes_After_Name,
}

@(rodata)
file_problem_sentences := [File_Problem]string {
	.None             = "",
	.Wrong_Size       = "the file does not have 216 bytes",
	.Wrong_Magic      = "the file does not start with PRINCIPL",
	.Wrong_Format     = "the file has another format number",
	.Other_Parameters = "the file names other parameters of Argon2id than 19456 KiB and 2 passes",
	.Bad_Name         = "the name in the file is not a name of a principal",
	.Bytes_After_Name = "the file has bytes that are not zero after the name",
}

Name_Problem :: enum u8 {
	None,
	Empty,
	Too_Long,
	Bad_Byte,
}

@(rodata)
name_problem_sentences := [Name_Problem]string {
	.None     = "",
	.Empty    = "the name is empty",
	.Too_Long = "the name has more than 23 bytes",
	.Bad_Byte = "the name has a byte that is not a letter, a digit, '-', '_' or '.'",
}

// name_problem checks the name of a principal: 1 to 23 bytes of letters,
// digits, '-', '_' and '.'. The name is for display only: the number names
// the principal in the system.
name_problem :: proc "contextless" (name: string) -> Name_Problem {
	if len(name) == 0 {
		return .Empty
	}
	if len(name) > NAME_LIMIT {
		return .Too_Long
	}
	for index in 0 ..< len(name) {
		switch name[index] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.':
		case:
			return .Bad_Byte
		}
	}
	return .None
}

Passphrase_Problem :: enum u8 {
	None,
	Too_Short,
	Too_Long,
	Bad_Byte,
}

@(rodata)
passphrase_problem_sentences := [Passphrase_Problem]string {
	.None      = "",
	.Too_Short = "the passphrase has fewer than 8 bytes",
	.Too_Long  = "the passphrase has more than 128 bytes",
	.Bad_Byte  = "the passphrase has a byte that is not a printable character",
}

// passphrase_problem checks a passphrase: 8 to 128 printable bytes (32 to
// 126), the bytes that the input service gives for the keys of the US layout.
passphrase_problem :: proc "contextless" (passphrase: []u8) -> Passphrase_Problem {
	if len(passphrase) < PASSPHRASE_LEAST {
		return .Too_Short
	}
	if len(passphrase) > PASSPHRASE_LIMIT {
		return .Too_Long
	}
	for character in passphrase {
		if character < 32 || character > 126 {
			return .Bad_Byte
		}
	}
	return .None
}

// name_pack puts a name of a principal into three values of a ring record:
// 24 bytes, zero bytes after the name. A longer name is cut: check it first.
name_pack :: proc "contextless" (name: string) -> (values: [3]u64) {
	bytes: [24]u8
	copy(bytes[:NAME_LIMIT], name)
	return transmute([3]u64)bytes
}

// name_unpack gives the bytes of a name from three values, and its length:
// the bytes before the first zero byte, NAME_LIMIT at most.
name_unpack :: proc "contextless" (values: [3]u64) -> (name: [NAME_LIMIT]u8, length: int) {
	bytes := transmute([24]u8)values
	for length < NAME_LIMIT && bytes[length] != 0 {
		name[length] = bytes[length]
		length += 1
	}
	return
}

// store_name_write writes the name of the store that the root service gives
// to the connection of a program to the storage service: the name of the
// program for principal 0, so the stores of the system keep their names;
// "<program>.principal.<number>" for a named principal, so two principals
// that run one program have two stores. history adds ".history" after the
// name of the program (the store of the line history of the console). It
// gives false when the name and its zero byte do not fit in 32 bytes: the
// root service then refuses the connection, as a cut name could be the
// name of another store. This is the one place that builds the name: the
// identity of the package of the program (the key of the principal that
// signs it, and its name) enters here when storage attaches data to it
// (docs/PRINCIPALS.md, section 6).
store_name_write :: proc "contextless" (out: ^[32]u8, program: string, principal: u64, history: bool) -> bool {
	out^ = {}
	count := 0
	put :: proc "contextless" (into: ^[32]u8, written: ^int, text: string) -> bool {
		if written^ + len(text) > len(into^) - 1 {
			return false
		}
		copy(into^[written^:], text)
		written^ += len(text)
		return true
	}
	ok := put(out, &count, program)
	if ok && history {
		ok = put(out, &count, ".history")
	}
	if ok && principal != MACHINE {
		ok = put(out, &count, ".principal.")
		digits: [20]u8
		place := len(digits)
		value := principal
		for {
			place -= 1
			digits[place] = u8('0' + value % 10)
			value /= 10
			if value == 0 {
				break
			}
		}
		ok = ok && put(out, &count, string(digits[place:]))
	}
	if !ok {
		out^ = {}
	}
	return ok
}

@(private)
u32_put :: proc "contextless" (bytes: []u8, value: u32) {
	bytes[0], bytes[1], bytes[2], bytes[3] = u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)
}

@(private)
u32_get :: proc "contextless" (bytes: []u8) -> u32 {
	return u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24
}

// file_encode writes the bytes of a file. The caller checked the name.
file_encode :: proc "contextless" (file: ^Principal_File, out: ^[FILE_SIZE]u8) {
	out^ = {}
	copy(out^[OFFSET_MAGIC:][:8], FILE_MAGIC)
	u32_put(out^[OFFSET_FORMAT:], FILE_FORMAT)
	u32_put(out^[OFFSET_MEMORY:], DERIVATION_MEMORY_KIBIBYTES)
	u32_put(out^[OFFSET_PASSES:], DERIVATION_PASSES)
	length := clamp(file.name_length, 0, NAME_LIMIT)
	out^[OFFSET_NAME_LENGTH] = u8(length)
	copy(out^[OFFSET_NAME:][:length], file.name[:length])
	copy(out^[OFFSET_SIGNING_PUBLIC_KEY:][:PUBLIC_KEY_SIZE], file.signing_public_key[:])
	copy(out^[OFFSET_UNLOCK_PUBLIC_KEY:][:PUBLIC_KEY_SIZE], file.unlock_public_key[:])
	copy(out^[OFFSET_SALT:][:SALT_SIZE], file.salt[:])
	copy(out^[OFFSET_NONCE:][:NONCE_SIZE], file.nonce[:])
	copy(out^[OFFSET_SEALED:][:SEALED_SIZE], file.sealed[:])
}

// file_decode reads a file that the store gave. It copies the bytes once
// and checks the copy: the store is data from the disk, which another
// machine or a fault can have changed. It does not check the seal: only
// the passphrase opens it.
file_decode :: proc "contextless" (bytes: []u8) -> (file: Principal_File, kept: [FILE_SIZE]u8, problem: File_Problem) {
	if len(bytes) != FILE_SIZE {
		return {}, {}, .Wrong_Size
	}
	copy(kept[:], bytes)
	if string(kept[OFFSET_MAGIC:][:8]) != FILE_MAGIC {
		return {}, {}, .Wrong_Magic
	}
	if u32_get(kept[OFFSET_FORMAT:]) != FILE_FORMAT {
		return {}, {}, .Wrong_Format
	}
	if u32_get(kept[OFFSET_MEMORY:]) != DERIVATION_MEMORY_KIBIBYTES || u32_get(kept[OFFSET_PASSES:]) != DERIVATION_PASSES {
		return {}, {}, .Other_Parameters
	}
	length := int(kept[OFFSET_NAME_LENGTH])
	if length > NAME_LIMIT || name_problem(string(kept[OFFSET_NAME:][:length])) != .None {
		return {}, {}, .Bad_Name
	}
	for after in kept[OFFSET_NAME + length:OFFSET_SIGNING_PUBLIC_KEY] {
		if after != 0 {
			return {}, {}, .Bytes_After_Name
		}
	}
	file.name_length = length
	copy(file.name[:], kept[OFFSET_NAME:][:length])
	copy(file.signing_public_key[:], kept[OFFSET_SIGNING_PUBLIC_KEY:][:PUBLIC_KEY_SIZE])
	copy(file.unlock_public_key[:], kept[OFFSET_UNLOCK_PUBLIC_KEY:][:PUBLIC_KEY_SIZE])
	copy(file.salt[:], kept[OFFSET_SALT:][:SALT_SIZE])
	copy(file.nonce[:], kept[OFFSET_NONCE:][:NONCE_SIZE])
	copy(file.sealed[:], kept[OFFSET_SEALED:][:SEALED_SIZE])
	return file, kept, .None
}

// file_additional_data gives the bytes of a file that the seal covers and
// that are not sealed: each byte before the sealed keys.
file_additional_data :: proc "contextless" (bytes: ^[FILE_SIZE]u8) -> []u8 {
	return bytes^[:OFFSET_SEALED]
}
