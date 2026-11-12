type: Fixed

**An export that fails in a sandboxed program or a service no longer changes a table of the console**: the console copied back the rows that a failed export wrote in a Change table; it now copies back only the table of error details, as the contract says.
