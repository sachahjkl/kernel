# Changelog

All the changes of the system that a reader notices. The format is [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

The project has steps, not separate releases. The merge of step N on `master` is the release `0.N.0`, with the date of that merge. A correction between two steps is `0.N.1`, `0.N.2`. The release `0.0.0` is the first milestone, before step 1. The number of the newest release is `RELEASE_NUMBER` in `contract/release/release.odin`; `kerneltool release_number` prints it.

What is not in a release yet is in `changelog.d/`, one fragment for each change. `kerneltool changelog release` writes a release from the fragments. Nobody edits this file by hand.
