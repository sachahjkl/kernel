type: Fixed

A build in an empty folder could fail: two module processes of the parallel build made the same folder at the same time, and one of them stopped with "cannot create ... Exist".
