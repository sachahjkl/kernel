// The release number of the system (docs/GLOSSARY.md, "Release number"):
// the newest release of CHANGELOG.md. The merge of step N on master is the
// release 0.N.0; a correction between two steps is 0.N.1, 0.N.2.
//
// `kerneltool changelog release <number>` writes the line below; nothing
// else changes it. `kerneltool changelog check` fails when it is not the
// newest release of CHANGELOG.md.
package release

RELEASE_NUMBER :: "0.75.0"
