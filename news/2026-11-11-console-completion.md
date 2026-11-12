title: The console completes names with a fuzzy match
date: 2026-11-11
release: 0.73.0
picture: docs/screenshots/console_completion.png
kind: Shown
guide: docs/CONSOLE.md

While a person types in the console, a list under the line shows the names that match: the commands, the exports, the services, the variables and the modules. The match is fuzzy: the typed characters appear in the name in their order, so `mcnt` finds `monitor.count`. The list lights the matched characters and gives the signature of each name at its right. Tab or Enter takes a name. The history of the console keeps 256 lines, and Control-R searches them with the same match. One key reads at most 4096 names, with at most 320 steps for each name. The time of one key is not measured in this release.
