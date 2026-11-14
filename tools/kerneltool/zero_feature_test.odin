package kerneltool

import "core:os"
import "core:strings"
import "core:testing"
import "modus:support/vector_font"

// source_font_path gives the path of a source font from VECTOR_FONT_SOURCES,
// which the development shell and the check of the flake set.
@(private = "file")
source_font_path :: proc(name: string) -> (path: string, ok: bool) {
	sources := os.get_env(VECTOR_FONT_SOURCES_VARIABLE, context.temp_allocator)
	rest := sources
	prefix := strings.concatenate({name, "="}, context.temp_allocator)
	for item in strings.split_iterator(&rest, ";") {
		if strings.has_prefix(item, prefix) {
			return item[len(prefix):], true
		}
	}
	return "", false
}

// The pinned files of Paper Mono, Regular and SemiBold, give the slashed
// zero by the feature "zero" of their table GSUB: a single substitution
// (lookup 158, type 1, format 1) from the glyph 294 of '0' to the glyph 304
// ("zero.zero" in the table post). The default zero has 2 contours (24
// points in Regular, 26 in SemiBold), like the capital O; the slashed zero
// has 3 contours and 32 points: the stroke at an angle inside it.
@(test)
the_zero_feature_of_paper_mono :: proc(t: ^testing.T) {
	Expected :: struct {
		name:           string,
		default_points: int,
	}
	fonts := [2]Expected{{"paper_mono", 24}, {"paper_mono_semibold", 26}}
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	outline := vector_font.Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for expected in fonts {
		path, found := source_font_path(expected.name)
		testing.expectf(t, found, "%s names %s: run the tests in the development shell or in the check of the flake", VECTOR_FONT_SOURCES_VARIABLE, expected.name)
		if !found {
			continue
		}
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, read_error == nil, "%s can be read", path)
		font, problem := vector_font.font_open(bytes)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		zero, zero_problem := vector_font.glyph_of(&font, '0')
		testing.expect_value(t, zero_problem, vector_font.Font_Problem.None)
		testing.expect_value(t, zero, 294)
		slashed, substitution_problem := vector_font.single_substitution(&font, ZERO_FEATURE, zero)
		testing.expect_value(t, substitution_problem, vector_font.Font_Problem.None)
		testing.expect_value(t, slashed, 304)
		testing.expect_value(t, vector_font.glyph_outline(&font, zero, &outline), vector_font.Font_Problem.None)
		testing.expect_value(t, outline.contour_count, 2)
		testing.expect_value(t, outline.point_count, expected.default_points)
		default_advance := outline.advance
		testing.expect_value(t, vector_font.glyph_outline(&font, slashed, &outline), vector_font.Font_Problem.None)
		testing.expect_value(t, outline.contour_count, 3)
		testing.expect_value(t, outline.point_count, 32)
		testing.expect_value(t, outline.advance, default_advance) // The subset stays monospace.
		// No other feature is taken for "zero": the capital O has no substitution.
		capital, _ := vector_font.glyph_of(&font, 'O')
		_, capital_problem := vector_font.single_substitution(&font, ZERO_FEATURE, capital)
		testing.expect_value(t, capital_problem, vector_font.Font_Problem.No_Feature)
	}
}
