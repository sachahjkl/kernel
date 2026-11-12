package kerneltool

import "core:strings"
import "core:testing"

@(private = "file")
GOOD_NEWS_NAME :: "2026-11-11-a-thing.md"

@(private = "file")
GOOD_NEWS :: `title: A thing a person can see
date: 2026-11-11
release: 0.58.0
picture: docs/screenshots/console.png
kind: Measured
guide: docs/CONSOLE.md

The first sentence. The second sentence with ` + "`code`" + `.
A line that continues it.
`

@(test)
news_of_a_good_entry :: proc(t: ^testing.T) {
	entry, problems := news_parse(GOOD_NEWS_NAME, GOOD_NEWS)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, entry.title, "A thing a person can see")
	testing.expect_value(t, entry.date, "2026-11-11")
	testing.expect_value(t, entry.subject, "a-thing")
	testing.expect_value(t, entry.release, "0.58.0")
	testing.expect_value(t, entry.picture, "docs/screenshots/console.png")
	testing.expect_value(t, entry.kind, News_Kind.Measured)
	testing.expect_value(t, entry.guide, "docs/CONSOLE.md")
	testing.expect_value(t, entry.text_line, 8)
	testing.expect(t, strings.has_prefix(entry.text, "The first sentence."))
	testing.expect(t, strings.has_suffix(entry.text, "A line that continues it."))
	testing.expect_value(t, site_news_lead(entry), "The first sentence.")
	testing.expect_value(t, site_news_anchor(entry), "news-2026-11-11-a-thing")
	// "next", "none" and the head in another order are well formed too.
	other := "kind: Fixed\nguide: none\npicture: none\nrelease: next\ndate: 2026-11-11\ntitle: Another\n\nText.\n"
	_, other_problems := news_parse(GOOD_NEWS_NAME, other)
	testing.expectf(t, len(other_problems) == 0, "problems: %v", other_problems)
}

@(test)
news_of_a_damaged_entry :: proc(t: ^testing.T) {
	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{"title: A thing a person can see\n", ""},
		{"title: A thing a person can see", "title:"},
		{"title: A thing a person can see", "title: A `thing`"},
		{"title: A thing a person can see", "title:  A thing"},
		{"title: A thing a person can see", strings.concatenate({"title: ", strings.repeat("a", NEWS_TITLE_LIMIT + 1, context.temp_allocator)}, context.temp_allocator)},
		{"date: 2026-11-11", "date: 2026-11-12"},
		{"date: 2026-11-11", "date: 2026-02-30"},
		{"release: 0.58.0", "release: 0.58"},
		{"release: 0.58.0", "release: soon"},
		{"picture: docs/screenshots/console.png", "picture: build/console.png"},
		{"picture: docs/screenshots/console.png", "picture: docs/screenshots/../../secret.png"},
		{"picture: docs/screenshots/console.png", "picture: docs/screenshots/console.jpg"},
		{"kind: Measured", "kind: Announced"},
		{"guide: docs/CONSOLE.md", "guide: docs/HANDOFF.md"},
		{"guide: docs/CONSOLE.md", "guide: CONSOLE.md"},
		{"guide: docs/CONSOLE.md", "guide: docs/research/a.md"},
		{"guide: docs/CONSOLE.md", "guide: docs/CONSOLE.md\ncolor: blue"},
		{"guide: docs/CONSOLE.md", "guide: docs/CONSOLE.md\nkind: Shown"},
		{"guide: docs/CONSOLE.md\n\n", "guide: docs/CONSOLE.md\n"},
		{"The first sentence.", "# A heading\nThe first sentence."},
		{"The first sentence.", "<p>The first sentence.</p>"},
		{"The first sentence.", "\tThe first sentence."},
		{"The first sentence. The second sentence with `code`.\nA line that continues it.\n", ""},
		{"The first sentence.", strings.repeat("A sentence. ", 120, context.temp_allocator)},
	}
	for damage in damages {
		damaged, changed := strings.replace_all(GOOD_NEWS, damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the good entry", damage.before)
		_, problems := news_parse(GOOD_NEWS_NAME, damaged)
		testing.expectf(t, len(problems) > 0, "no problem found after %q became %q", damage.before, damage.after)
	}
	names := []string{"2026-11-11.md", "2026-11-11-A-thing.md", "2026-13-01-a-thing.md", "20261111-a-thing.md", "2026-11-11-a-thing.txt", "2026-11-11--thing.md"}
	for name in names {
		_, problems := news_parse(name, GOOD_NEWS)
		testing.expectf(t, len(problems) > 0, "the name %q is accepted", name)
	}
	_, empty_problems := news_parse(GOOD_NEWS_NAME, "")
	testing.expect(t, len(empty_problems) > 0)
}

@(test)
news_new_entry_waits_for_its_title_and_text :: proc(t: ^testing.T) {
	_, problems := news_parse(GOOD_NEWS_NAME, news_text("2026-11-11"))
	// The title has no value, and the text is empty: two problems, and only those.
	testing.expectf(t, len(problems) == 2, "problems: %v", problems)
	for problem in problems {
		testing.expectf(t, strings.contains(problem, "title") || strings.contains(problem, "text"), "an unexpected problem: %s", problem)
	}
}

@(test)
news_names_present_files :: proc(t: ^testing.T) {
	changelog := Changelog {
		releases = []Changelog_Release{{number = {0, 58, 0}, date = "2026-11-11"}},
	}
	good, _ := news_parse(GOOD_NEWS_NAME, GOOD_NEWS)
	problems := make([dynamic]string, context.temp_allocator)
	news_files_problems([]News_Entry{good}, changelog, &problems)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)

	absent := good
	absent.release = "0.59.0"
	absent.picture = "docs/screenshots/no_picture_of_the_news_test.png"
	absent.guide = "docs/NO_GUIDE_OF_THE_NEWS_TEST.md"
	clear(&problems)
	news_files_problems([]News_Entry{absent}, changelog, &problems)
	testing.expectf(t, len(problems) == 3, "problems: %v", problems)

	twin := good
	twin.file_name = "2026-11-12-a-thing.md"
	clear(&problems)
	news_files_problems([]News_Entry{good, twin}, changelog, &problems)
	testing.expectf(t, len(problems) == 1, "two entries with one title: %v", problems)
}

@(test)
news_of_the_repository :: proc(t: ^testing.T) {
	entries, problems := news_all_read()
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect(t, len(entries) > 0, "news/ has no entry")
	for index in 1 ..< len(entries) {
		testing.expect(t, entries[index - 1].date >= entries[index].date, "the entries are not newest first")
	}
}

@(test)
news_feed_escapes_and_links :: proc(t: ^testing.T) {
	entry, _ := news_parse(GOOD_NEWS_NAME, GOOD_NEWS)
	site: Site
	site.news = []Site_News{{entry = entry, anchor = site_news_anchor(entry), body = "<p>x &amp; \"y\"</p>\n", picture = "pictures/console.png", picture_width = 1024, picture_height = 768, picture_alt = "A <b> & \"c\""}}
	feed := site_news_feed(&site)
	testing.expect(t, strings.has_prefix(feed, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">"))
	testing.expect(t, strings.contains(feed, "<title>A thing a person can see</title>"))
	testing.expect(t, strings.contains(feed, "<updated>2026-11-11T00:00:00Z</updated>"))
	testing.expect(t, strings.contains(feed, "<id>" + SITE_REPOSITORY_ADDRESS + "/blob/master/news/" + GOOD_NEWS_NAME + "</id>"))
	// With no address: relative links and no link "self".
	testing.expect(t, strings.contains(feed, "href=\"news.html#news-2026-11-11-a-thing\""))
	testing.expect(t, !strings.contains(feed, "rel=\"self\""))
	// The HTML of the content is escaped once more: no markup of it is markup of the feed.
	testing.expect(t, strings.contains(feed, "&lt;p&gt;x &amp;amp; &quot;y&quot;&lt;/p&gt;"))
	testing.expect(t, !strings.contains(feed, "<p>"))
	testing.expect(t, !strings.contains(feed, "<b>"))
	testing.expect(t, strings.contains(feed, "<summary>The first sentence.</summary>"))

	site.address = "https://example.org/modus"
	addressed := site_news_feed(&site)
	testing.expect(t, strings.contains(addressed, "href=\"https://example.org/modus/news.html#news-2026-11-11-a-thing\""))
	testing.expect(t, strings.contains(addressed, "<link rel=\"self\" type=\"application/atom+xml\" href=\"https://example.org/modus/news.xml\"/>"))
}
