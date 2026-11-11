type: Fixed

**A thread with a short stack stops at its guard page**: the erasure of the stack after a cryptographic call writes from the top down, so no memory under the stack is written first; a thread that calls the module `cryptography` or draws random bytes needs 24 KiB of stack.
