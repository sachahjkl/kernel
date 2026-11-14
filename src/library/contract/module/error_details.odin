package module

// error_details_parameter gives the index, from 0, of the table of error
// details of an export (docs/MODULE_CONTRACT.md, section 8, "The table of
// error details"): its last parameter, when the export has an error record
// and that parameter is a Table with the direction Append whose record is
// equal to the error record. ok is false for an export with no table of
// error details.
error_details_parameter :: proc "contextless" (file: []u8, function: Function) -> (index: int, ok: bool) {
	function := function
	if function.error_record == 0 || function.parameter_count == 0 || int(function.parameter_count) > PARAMETER_CAPACITY {
		return 0, false
	}
	index = int(function.parameter_count) - 1
	if function.parameters[index] != .Table || function.parameter_directions[index] != .Append {
		return 0, false
	}
	if !records_equal(file, function.parameter_details[index], file, function.error_record) {
		return 0, false
	}
	return index, true
}
