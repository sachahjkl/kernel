package system

import module "contract:module"

// Tables and bytes as parameters of an export, in Odin
// (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters").
//
// Each type has the layout of the table place (module.Table_Place): the
// address of the first record, the count, and the capacity. The name of the
// type is the direction; the kernel tool reads it from the source:
//
//   sum_values :: proc "c" (readings: ^system.Table_To_Read(Reading)) -> i64
//
// The callee of a Read table reads records[0 ..< count]. The callee of a
// Change table reads and writes them; the count stays. The callee of an
// Append table writes records[count ..< capacity], reads none before count,
// and sets count to the count of the full answer, across calls: a count
// larger than the capacity means that the answer did not fit; on entry it
// means that earlier calls did not fit, and nothing more is written
// (table_append and bytes_append do it, with a count that stops at the
// largest number).

Table_To_Read :: struct($Record: typeid) {
	records:  [^]Record,
	count:    u64,
	capacity: u64,
}

Table_To_Change :: struct($Record: typeid) {
	records:  [^]Record,
	count:    u64,
	capacity: u64,
}

Table_To_Append :: struct($Record: typeid) {
	records:  [^]Record,
	count:    u64,
	capacity: u64,
}

Bytes_To_Read :: struct {
	bytes:    [^]u8,
	count:    u64,
	capacity: u64,
}

Bytes_To_Change :: struct {
	bytes:    [^]u8,
	count:    u64,
	capacity: u64,
}

Bytes_To_Append :: struct {
	bytes:    [^]u8,
	count:    u64,
	capacity: u64,
}

#assert(size_of(Table_To_Read(u64)) == size_of(module.Table_Place))
#assert(size_of(Table_To_Change(u64)) == size_of(module.Table_Place))
#assert(size_of(Table_To_Append(u64)) == size_of(module.Table_Place))
#assert(size_of(Bytes_To_Read) == size_of(module.Table_Place))
#assert(size_of(Bytes_To_Change) == size_of(module.Table_Place))
#assert(size_of(Bytes_To_Append) == size_of(module.Table_Place))

// table_records gives the records of a Read or Change table as a slice.
table_records :: proc "contextless" (table: ^$T/Table_To_Read($R)) -> []R {
	return table.records[:table.count]
}

// table_changed_records gives the records of a Change table as a slice.
table_changed_records :: proc "contextless" (table: ^$T/Table_To_Change($R)) -> []R {
	return table.records[:table.count]
}

// table_append appends one record: it writes it when it fits, and adds 1
// to the count in each case. It gives false when the record did not fit.
table_append :: proc "contextless" (table: ^$T/Table_To_Append($R), record: R) -> bool {
	fits := table.count < table.capacity
	if fits {
		table.records[table.count] = record
	}
	table.count = table.count == max(u64) ? max(u64) : table.count + 1
	return fits
}

// bytes_append appends bytes: those that fit are written, and the count
// grows by all of them. It gives the offset of the first byte. No sum
// wraps: the index is compared with the free bytes, and the count stops at
// the largest number (it stays larger than the capacity).
bytes_append :: proc "contextless" (place: ^Bytes_To_Append, bytes: []u8) -> (start: u64) {
	start = place.count
	free := place.count < place.capacity ? place.capacity - place.count : 0
	for b, index in bytes {
		if u64(index) < free {
			place.bytes[place.count + u64(index)] = b
		}
	}
	place.count = place.count > max(u64) - u64(len(bytes)) ? max(u64) : place.count + u64(len(bytes))
	return start
}
