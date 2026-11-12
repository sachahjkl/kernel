#+build !freestanding
package principals

import "core:testing"

// The store of a program has the name of the program for the machine, so
// the stores of the system keep their names; a named principal has a store
// of its own for each program.
@(test)
store_names_carry_the_principal :: proc(t: ^testing.T) {
	out: [32]u8
	cases := [?]struct {
		program:   string,
		principal: u64,
		history:   bool,
		name:      string,
	} {
		{"notes", MACHINE, false, "notes"},
		{"console", MACHINE, true, "console.history"},
		{"notes", 1, false, "notes.principal.1"},
		{"console", 1, true, "console.history.principal.1"},
		{"notes", 32767, false, "notes.principal.32767"},
	}
	for item in cases {
		testing.expect(t, store_name_write(&out, item.program, item.principal, item.history))
		length := 0
		for length < len(out) && out[length] != 0 {
			length += 1
		}
		testing.expect_value(t, string(out[:length]), item.name)
	}
	// Two principals that run one program: two stores.
	first, second: [32]u8
	testing.expect(t, store_name_write(&first, "notes", MACHINE, false))
	testing.expect(t, store_name_write(&second, "notes", 1, false))
	testing.expect(t, first != second)
}

// A name that does not fit with its zero byte is refused, never cut: a cut
// name can be the name of another store.
@(test)
a_store_name_that_does_not_fit_is_refused :: proc(t: ^testing.T) {
	out: [32]u8
	testing.expect(t, store_name_write(&out, "interface_through_module", MACHINE, false))
	testing.expect(t, !store_name_write(&out, "interface_through_module", 1, false))
	testing.expect_value(t, out, [32]u8{})
	// 31 bytes fit; 32 do not.
	testing.expect(t, store_name_write(&out, "abcdefghijklmnopqrstuvwxyz01234", MACHINE, false))
	testing.expect(t, !store_name_write(&out, "abcdefghijklmnopqrstuvwxyz012345", MACHINE, false))
}

@(test)
names_and_passphrases :: proc(t: ^testing.T) {
	testing.expect_value(t, name_problem("alice"), Name_Problem.None)
	testing.expect_value(t, name_problem("a.b-c_9"), Name_Problem.None)
	testing.expect_value(t, name_problem(""), Name_Problem.Empty)
	testing.expect_value(t, name_problem("abcdefghijklmnopqrstuvwx"), Name_Problem.Too_Long)
	testing.expect_value(t, name_problem("two words"), Name_Problem.Bad_Byte)
	testing.expect_value(t, name_problem("quote\""), Name_Problem.Bad_Byte)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("correct horse")), Passphrase_Problem.None)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("short")), Passphrase_Problem.Too_Short)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("tab\tinside it")), Passphrase_Problem.Bad_Byte)
	long: [PASSPHRASE_LIMIT + 1]u8
	for &character in long {
		character = 'a'
	}
	testing.expect_value(t, passphrase_problem(long[:]), Passphrase_Problem.Too_Long)
	testing.expect_value(t, passphrase_problem(long[:PASSPHRASE_LIMIT]), Passphrase_Problem.None)
	values := name_pack("alice")
	name, length := name_unpack(values)
	testing.expect_value(t, string(name[:length]), "alice")
	full := name_pack("abcdefghijklmnopqrstuvw")
	name, length = name_unpack(full)
	testing.expect_value(t, length, NAME_LIMIT)
}

test_file :: proc() -> Principal_File {
	file := Principal_File{name_length = 5}
	copy(file.name[:], "alice")
	for index in 0 ..< PUBLIC_KEY_SIZE {
		file.signing_public_key[index] = u8(index)
		file.unlock_public_key[index] = u8(100 + index)
	}
	for index in 0 ..< SALT_SIZE {
		file.salt[index] = u8(200 + index)
	}
	for index in 0 ..< NONCE_SIZE {
		file.nonce[index] = u8(50 + index)
	}
	for index in 0 ..< SEALED_SIZE {
		file.sealed[index] = u8(index * 3)
	}
	return file
}

@(test)
a_file_round_trip :: proc(t: ^testing.T) {
	file := test_file()
	bytes: [FILE_SIZE]u8
	file_encode(&file, &bytes)
	decoded, kept, problem := file_decode(bytes[:])
	testing.expect_value(t, problem, File_Problem.None)
	testing.expect(t, decoded == file)
	testing.expect(t, kept == bytes)
	testing.expect_value(t, len(file_additional_data(&kept)), OFFSET_SEALED)
	testing.expect_value(t, string(bytes[:8]), "PRINCIPL")
}

// A file is data from the disk: each field that the code trusts is checked.
@(test)
hostile_files_are_refused :: proc(t: ^testing.T) {
	file := test_file()
	good: [FILE_SIZE]u8
	file_encode(&file, &good)
	expect :: proc(test: ^testing.T, bytes: []u8, wanted: File_Problem) {
		_, _, problem := file_decode(bytes)
		testing.expect_value(test, problem, wanted)
	}
	expect(t, good[:FILE_SIZE - 1], .Wrong_Size)
	expect(t, nil, .Wrong_Size)
	changed := good
	changed[0] = 'X'
	expect(t, changed[:], .Wrong_Magic)
	changed = good
	changed[OFFSET_FORMAT] = 2
	expect(t, changed[:], .Wrong_Format)
	// A file cannot ask for a cheaper derivation, or for more memory.
	changed = good
	changed[OFFSET_MEMORY] = 8
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[OFFSET_PASSES] = 1
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[OFFSET_NAME_LENGTH] = NAME_LIMIT + 1
	expect(t, changed[:], .Bad_Name)
	changed = good
	changed[OFFSET_NAME_LENGTH] = 0
	expect(t, changed[:], .Bad_Name)
	changed = good
	changed[OFFSET_NAME + 1] = ' '
	expect(t, changed[:], .Bad_Name)
	changed = good
	changed[OFFSET_NAME + 10] = 'x'
	expect(t, changed[:], .Bytes_After_Name)
}
