package system

import "modus:contract/errors"

// The table of error details (docs/MODULE_CONTRACT.md, section 8, "The table
// of error details"): an optional Append table of error records that the
// caller gives, the last parameter of an export with an error record. The
// export writes one error detail for each thing that it has to say, and its
// error record is the first of them.
//
// In the signature of an export, write the type in full, so that the kernel
// tool reads the direction from it:
//
//   details: ^system.Table_To_Append(errors.Error_Record)
Error_Details :: Table_To_Append(errors.Error_Record)

// error_detail_append appends one error detail. A nil table: the caller
// asked for none, and nothing is written. Else the Append rule: the detail is
// written when it fits, and counted in each case, so that the caller learns
// how many details there were.
error_detail_append :: proc "contextless" (details: ^Error_Details, detail: errors.Error_Record) {
	if details != nil {
		table_append(details, detail)
	}
}

// error_details_written gives the error details that the table holds: the
// first min(count, capacity). The count can be larger: the caller says how
// many did not fit.
error_details_written :: proc "contextless" (details: ^Error_Details) -> []errors.Error_Record {
	if details == nil || details.records == nil {
		return nil
	}
	return details.records[:min(details.count, details.capacity)]
}
