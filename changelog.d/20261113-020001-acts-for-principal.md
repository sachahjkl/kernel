type: Changed

**The grant person is acts_for_principal**: `revoke("remote", "acts_for_principal")` in place of `revoke("remote", "person")`; `isolated.CALLER_PERSON` is `CALLER_ACTS_FOR_PRINCIPAL`, and the grant of a connection carries the number of the principal of the caller in bits 48 to 62. A refusal says "to act for the principal". `flood` writes "flood: Space: ...", and the console "error: Escape stopped the call of ...".
