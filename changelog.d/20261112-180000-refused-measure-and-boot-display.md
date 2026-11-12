type: Fixed

**A refused measure is said, and the boot display shows whole names**: when the TPM refuses to measure the system description, the boot program tries 4 times, then the boot display says "TPM refused the measure" in red and the root service writes a warning, where before the display said "not measured" as for a machine with no TPM. The tiles of the boot image show the whole name of each module or no name, never a cut name, and the trust record takes one line under them. No text of the boot program lies over the boot display any more.
