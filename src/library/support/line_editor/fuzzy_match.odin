package line_editor

// The fuzzy match: the characters of the query appear in the name in their
// order, not always side by side ("mcnt" matches "monitor.count"). A score
// orders the names that match. Lower and upper case are equal.
//
// The work for one name is bounded, whatever another program wrote in its
// descriptions:
//   the match     the first NAME_SCAN_LIMIT bytes of the name, two times
//                 (a pass forward and a pass back), then at most
//                 QUERY_LIMIT places: at most 2 * 128 + 64 = 320 steps.
//   the place     a binary search in the kept names: at most 7 orders of
//                 two names, each one at most NAME_COMPARE_LIMIT bytes, so
//                 1792 bytes; then a move of at most 64 kept records.
//   equal names   only for a search that skips them (a history): at most
//                 64 kept names of NAME_COMPARE_LIMIT bytes, 16 384 bytes.
// The ranking reads at most CANDIDATE_SCAN_LIMIT names. So one key costs
// at most 4096 * (320 + 1792 + 64), about 8.9 million steps; a search that
// skips equal names reads at most 256 lines of a history, so at most
// 256 * (320 + 1792 + 64 + 16 384), about 4.8 million.

NAME_SCAN_LIMIT :: 128 // The bytes of a name that the match reads. A longer name matches only in its start.
QUERY_LIMIT :: 64 // A longer query matches no name.
CANDIDATE_SCAN_LIMIT :: 4096 // The names that one ranking reads; the names after them are not read.
RANKED_CAPACITY :: 64 // The best names that a ranking keeps.
// The bytes of two names that their order reads: after them, the shorter
// name comes first, and two names of one length are equal. It holds a whole
// line of a history, so that two lines that differ only at their end stay
// two lines.
NAME_COMPARE_LIMIT :: 256
#assert(NAME_COMPARE_LIMIT >= LINE_CAPACITY)

// The places of the characters of a name that the query matched: bit n is
// the byte n of the name.
Match_Places :: bit_set[0 ..< NAME_SCAN_LIMIT; u128]

// The scoring rules. Each one has its reason:
SCORE_MATCH :: 16 // Each matched character: a longer query that matches says more.
SCORE_START :: 32 // A match at the first byte of the name: the input types names from their start.
SCORE_SEGMENT :: 24 // A match right after '.' or '_': the start of a part of the name ("mc" for monitor.count).
SCORE_SIDE_BY_SIDE :: 16 // A match right after the match before: a typed run that the name holds as one run.
SCORE_GAP_OPEN :: 3 // Taken for each gap between two matches: a spread match is less likely what the input means.
SCORE_GAP_BYTE :: 1 // Taken for each byte of a gap after its first: a long gap more than a short one.
// After the score, a tie goes to the smaller tie order (the caller's
// order: 0 is the newest line of a history), then to the shorter name
// (fewer bytes to read past the query), then to the name first in the
// order of the bytes (a stable order).

// lower gives the lower case of an ASCII letter, and each other byte as it
// is: the match does not tell the cases apart.
lower :: proc "contextless" (character: u8) -> u8 {
	return character >= 'A' && character <= 'Z' ? character + ('a' - 'A') : character
}

// fuzzy_match matches a query against a name. matched is false when a
// character of the query is missing, or the query is longer than
// QUERY_LIMIT. places gets the places that gave the score. An empty query
// matches each name with the score 0 and no place.
fuzzy_match :: proc "contextless" (query: string, name: string) -> (score: int, places: Match_Places, matched: bool) {
	if len(query) > QUERY_LIMIT {
		return 0, {}, false
	}
	if len(query) == 0 {
		return 0, {}, true
	}
	scanned := name[:min(len(name), NAME_SCAN_LIMIT)]
	// Forward: the first place where the whole query has matched.
	next := 0
	end := -1
	for index in 0 ..< len(scanned) {
		if lower(scanned[index]) == lower(query[next]) {
			next += 1
			if next == len(query) {
				end = index
				break
			}
		}
	}
	if end < 0 {
		return 0, {}, false
	}
	// Back from that place: the latest start, so the shortest window that
	// holds the query, and its places.
	positions: [QUERY_LIMIT]int
	wanted := len(query) - 1
	for index := end; index >= 0 && wanted >= 0; index -= 1 {
		if lower(scanned[index]) == lower(query[wanted]) {
			positions[wanted] = index
			wanted -= 1
		}
	}
	for number in 0 ..< len(query) {
		place := positions[number]
		places += {place}
		score += SCORE_MATCH
		if place == 0 {
			score += SCORE_START
		} else if scanned[place - 1] == '.' || scanned[place - 1] == '_' {
			score += SCORE_SEGMENT
		}
		if number > 0 {
			gap := place - positions[number - 1] - 1
			if gap == 0 {
				score += SCORE_SIDE_BY_SIDE
			} else {
				score -= SCORE_GAP_OPEN + (gap - 1) * SCORE_GAP_BYTE
			}
		}
	}
	return score, places, true
}

// What a name is, for the reader: the list shows it at the right of the name.
Candidate_Kind :: enum u8 {
	Command      = 0, // A command of the program itself.
	Export       = 1, // An export of a module or of a service.
	Record       = 2, // A command that makes a record from its fields.
	Service      = 3, // A service that the program is connected to.
	Module       = 4, // A module of the boot image.
	Program      = 5, // A program that runs.
	Variable     = 6, // A variable of the program.
	History_Line = 7, // A line of the history.
}

// A name that can complete what the input typed. The caller fills a
// table of them; the names stay in the memory of the caller.
Candidate :: struct {
	name:      string, // The name, in the memory of the caller.
	kind:      Candidate_Kind, // What the name is.
	tie_order: u32, // Equal scores: the smaller first. A history gives the age of the line (0: the newest).
	number:    u32, // For the caller: the index of the thing in its own table.
}

// One name that matched, in the order of the ranking.
Ranked :: struct {
	candidate: int, // The index in the table of candidates.
	score:     int, // The score of the match: higher is better.
	places:    Match_Places, // The bytes of the name that matched.
}

// ranked_before says if a comes before b in the list: the rules after the
// score are in the comment of the scoring rules.
ranked_before :: proc "contextless" (a: Ranked, a_name: string, a_tie: u32, b: Ranked, b_name: string, b_tie: u32) -> bool {
	if a.score != b.score {
		return a.score > b.score
	}
	if a_tie != b_tie {
		return a_tie < b_tie
	}
	if len(a_name) != len(b_name) {
		return len(a_name) < len(b_name)
	}
	for index in 0 ..< min(len(a_name), NAME_COMPARE_LIMIT) {
		if a_name[index] != b_name[index] {
			return a_name[index] < b_name[index]
		}
	}
	return false
}

// names_equal says if two names are equal in their length and in their
// first NAME_COMPARE_LIMIT bytes.
names_equal :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for index in 0 ..< min(len(a), NAME_COMPARE_LIMIT) {
		if a[index] != b[index] {
			return false
		}
	}
	return true
}

// rank_candidates matches the query against each candidate (at most
// CANDIDATE_SCAN_LIMIT of them), and keeps the best ones in ranked, the
// best first (at most len(ranked)). kept: the count in ranked. matched:
// the count of the candidates that matched, kept or not. skip_equal_names:
// a name equal to a name already kept with the same score is not kept (a
// history holds the same line several times; the newest stays).
rank_candidates :: proc "contextless" (query: string, candidates: []Candidate, ranked: []Ranked, skip_equal_names := false) -> (kept: int, matched: int) {
	read := candidates[:min(len(candidates), CANDIDATE_SCAN_LIMIT)]
	for &candidate, index in read {
		score, places, ok := fuzzy_match(query, candidate.name)
		if !ok {
			continue
		}
		matched += 1
		entry := Ranked {
			candidate = index,
			score     = score,
			places    = places,
		}
		// The place of the new one: before the first kept one that it
		// comes before, found by a binary search (the kept ones are in
		// order). An equal one goes after the kept ones: the order of the
		// table decides between equals.
		low, high := 0, kept
		for low < high {
			middle := (low + high) / 2
			other := ranked[middle]
			other_candidate := &read[other.candidate]
			if ranked_before(entry, candidate.name, candidate.tie_order, other, other_candidate.name, other_candidate.tie_order) {
				high = middle
			} else {
				low = middle + 1
			}
		}
		place := low
		if skip_equal_names && equal_name_with_score(read, ranked[:kept], score, candidate.name) {
			continue
		}
		if place >= len(ranked) {
			continue // Worse than each kept one, and no room.
		}
		last := min(kept, len(ranked) - 1)
		copy(ranked[place + 1:last + 1], ranked[place:last])
		ranked[place] = entry
		kept = min(kept + 1, len(ranked))
	}
	return kept, matched
}

// equal_name_with_score says if a kept name with this score is equal to
// name. The kept names of one score are side by side, so the search stops
// at the first lower score: its cost stays small when the scores differ.
@(private)
equal_name_with_score :: proc "contextless" (candidates: []Candidate, kept: []Ranked, score: int, name: string) -> bool {
	for item in kept {
		if item.score < score {
			break
		}
		if item.score == score && names_equal(candidates[item.candidate].name, name) {
			return true
		}
	}
	return false
}
