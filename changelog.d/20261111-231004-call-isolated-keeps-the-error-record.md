type: Fixed

**A failed isolated call keeps the reason of its failure**: when the table of error details came back wrong, the error record of the export was replaced by a record about the table; it now stays, and a separate status says that the details are missing.
