// The news on the site (docs/SITE.md, "The news"): the page of the news, the
// newest entries on the home, the Atom feed news.xml, the film of an entry
// that has one, and a link from each release to the entries that name it. The entries are the files of news/
// (tools/kerneltool/news.odin); the site adds no sentence to them.
package kerneltool

import "core:fmt"
import "core:strings"

SITE_NEWS_FEED :: "news.xml"
// The entries that the home shows.
SITE_NEWS_HOME_COUNT :: 3
// The folder of the site that holds the films of the news.
SITE_FILM_FOLDER :: "films"
// The type of a film of the site, for a browser and for a feed reader.
SITE_FILM_TYPE :: "video/webm"
// The codec of a film, as a browser reads it before it asks for the file:
// AV1, the main profile (0), the level 5.0 (12, the first level that holds
// a picture of 2048 by 1536, twice the screen of the system), the main
// tier (M), 8 bits a channel. A browser that does not play it never asks
// for the file.
SITE_FILM_CODEC :: "av01.0.12M.08"
// The attribute of the source of a film. Its value holds double quotes, so
// single quotes are around it.
SITE_FILM_SOURCE_TYPE :: "type='" + SITE_FILM_TYPE + "; codecs=\"" + SITE_FILM_CODEC + "\"'"

// The class of the accent of a kind: the colored mark of its card.
site_news_kind_classes := [News_Kind]string {
	.Shown    = "accent-program",
	.Measured = "accent-memory",
	.Decided  = "accent-kernel",
	.Fixed    = "accent-machine",
}

// One entry as the site shows it.
Site_News :: struct {
	entry:          News_Entry,
	anchor:         string, // Its id on the page of the news.
	body:           string, // The HTML of its text, rendered once for the page and the feed.
	picture:        string, // Its path in the site, or "".
	picture_width:  int,
	picture_height: int,
	picture_alt:    string,
	film:           string, // Its path in the site, or "". An entry with a film has a picture.
	film_width:     int, // The width and the height of the pictures of the film, in pixels.
	film_height:    int,
	film_bytes:     int,
}

// site_news_anchor gives the id of an entry on the page of the news: from its file
// name, which no other entry has.
site_news_anchor :: proc(entry: News_Entry) -> string {
	return strings.concatenate({"news-", site_slug(strings.trim_suffix(entry.file_name, ".md"))}, context.temp_allocator)
}

// site_news_read reads and checks the entries, before any page is written.
site_news_read :: proc(site: ^Site) -> bool {
	problems := make([dynamic]string, context.temp_allocator)
	entries := news_read(NEWS_FOLDER, &problems)
	news_files_problems(entries, site.changelog, &problems)
	if len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintln("kerneltool: site: the news does not have its form; `kerneltool news check` says the same")
		return false
	}
	news := make([dynamic]Site_News, context.temp_allocator)
	for entry in entries {
		item := Site_News{entry = entry, anchor = site_news_anchor(entry)}
		if entry.picture != NEWS_NONE {
			data := read_file(entry.picture) or_return
			item.picture_width, item.picture_height, _ = site_png_size(data)
			item.picture = strings.concatenate({SITE_PICTURE_FOLDER, "/", site_file_name(entry.picture)}, context.temp_allocator)
			site.copies[item.picture] = entry.picture
			// The alt text: the caption of the picture in README.md, the
			// description of the mark, or the title of the entry.
			if caption, has_caption := site.readme.captions[entry.picture]; has_caption && caption != "" {
				item.picture_alt = caption
			} else if strings.has_prefix(entry.picture, LOGO_FOLDER + "/") {
				item.picture_alt = site.readme.mark_description
			} else {
				item.picture_alt = entry.title
			}
		}
		if news_entry_has_film(entry) && item.picture != "" {
			// The site copies the file as it is: it needs no encoder.
			data := read_file(entry.film) or_return
			film_width, film_height, sized := film_document_picture_size(data)
			if !sized {
				fmt.eprintfln("kerneltool: site: the film %s states no width and no height of its pictures", entry.film)
				return false
			}
			item.film = strings.concatenate({SITE_FILM_FOLDER, "/", site_file_name(entry.film)}, context.temp_allocator)
			item.film_width, item.film_height, item.film_bytes = film_width, film_height, len(data)
			site.copies[item.film] = entry.film
		}
		append(&news, item)
	}
	site.news = news[:]
	return true
}

// site_news_lead gives the first sentence of the first paragraph of an
// entry: its line on the home and its summary in the feed.
site_news_lead :: proc(entry: News_Entry) -> string {
	paragraphs := site_paragraphs(site_lines(entry.text))
	if len(paragraphs) == 0 {
		return entry.title
	}
	return site_first_sentence(paragraphs[0])
}

// site_news_meta writes the line under the title of an entry: its kind, its
// date, its release and its guide.
site_news_meta :: proc(site: ^Site, b: ^strings.Builder, from_page: string, entry: News_Entry, with_links: bool) {
	fmt.sbprintf(b, "<p class=\"news-meta\"><span class=\"news-kind\">%s</span> <time datetime=\"%s\">%s</time>", news_kind_names[entry.kind], entry.date, entry.date)
	if !with_links {
		strings.write_string(b, "</p>\n")
		return
	}
	if entry.release == NEWS_NEXT_RELEASE {
		strings.write_string(b, " - in the next release")
	} else {
		fmt.sbprintf(b, " - <a href=\"%s#%s\">release %s</a>", site_page_link(site, from_page, site_section_page(.Releases)), site_release_id(entry.release), entry.release)
	}
	if entry.guide != NEWS_NONE {
		if page, is_page := site.documents[entry.guide]; is_page {
			title := entry.guide
			for guide in site.guides {
				if guide.source == entry.guide {
					title = guide.title
				}
			}
			fmt.sbprintf(b, " - the guide <a href=\"%s\">", site_page_link(site, from_page, page))
			site_escape(b, title)
			strings.write_string(b, "</a>")
		}
	}
	strings.write_string(b, "</p>\n")
}

// site_news_picture writes the picture of an entry, as a link to its file.
site_news_picture :: proc(b: ^strings.Builder, from_page: string, item: Site_News, class: string) {
	if item.picture == "" {
		return
	}
	link := site_relative(from_page, item.picture)
	fmt.sbprintf(b, "<figure class=\"%s\"><a href=\"%s\"><img src=\"%s\" width=\"%d\" height=\"%d\" loading=\"lazy\" decoding=\"async\" alt=\"", class, link, link, item.picture_width, item.picture_height)
	site_plain(b, item.picture_alt)
	strings.write_string(b, "\"></a></figure>\n")
}

// site_film_size_text gives the size of a film for a reader, who chooses
// with it whether to load the film on a slow link.
site_film_size_text :: proc(bytes: int) -> string {
	return fmt.tprintf("%.1f MiB", f64(bytes) / (1024 * 1024))
}

// site_news_film writes the film of an entry on the page of the news. The
// film plays only when the reader starts it, and a browser loads only its
// head before that: the picture of the entry stands in its place. The
// width and the height of the film keep its room on the page before any
// byte of it came. The picture inside the element is for a browser with no
// video element, and the caption links to the file for each reader.
site_news_film :: proc(b: ^strings.Builder, from_page: string, item: Site_News) {
	if item.film == "" {
		return
	}
	film_link := site_relative(from_page, item.film)
	picture_link := site_relative(from_page, item.picture)
	fmt.sbprintf(b, "<figure class=\"news-film\"><video controls preload=\"metadata\" playsinline muted loop poster=\"%s\" width=\"%d\" height=\"%d\">", picture_link, item.film_width, item.film_height)
	fmt.sbprintf(b, "<source src=\"%s\" %s>", film_link, SITE_FILM_SOURCE_TYPE)
	fmt.sbprintf(b, "<a href=\"%s\"><img src=\"%s\" width=\"%d\" height=\"%d\" loading=\"lazy\" decoding=\"async\" alt=\"", film_link, picture_link, item.picture_width, item.picture_height)
	site_plain(b, item.picture_alt)
	fmt.sbprintf(b, "\"></a></video><figcaption>Film: <a href=\"%s\">%s</a>, WebM with AV1, %s.</figcaption></figure>\n", film_link, site_file_name(item.film), site_film_size_text(item.film_bytes))
}

// site_news_film_card_picture writes the picture of an entry with a film
// on a card of the home. A card is a third of the width of the page: a
// film of the whole screen is not readable there, and three players on
// the first page would each ask for a part of their file. So the card
// shows the picture, with a mark that says in a word that the entry has a
// film, and the picture links to the entry, where the film is.
site_news_film_card_picture :: proc(b: ^strings.Builder, from_page: string, item: Site_News, entry_link: string) {
	fmt.sbprintf(b, "<figure class=\"news-card-picture\"><a class=\"film-link\" href=\"%s\"><img src=\"%s\" width=\"%d\" height=\"%d\" loading=\"lazy\" decoding=\"async\" alt=\"", entry_link, site_relative(from_page, item.picture), item.picture_width, item.picture_height)
	site_plain(b, item.picture_alt)
	strings.write_string(b, "\"><span class=\"film-mark\">film</span></a></figure>\n")
}

// site_news_add writes the page of the news: every entry, newest first.
site_news_add :: proc(site: ^Site) {
	if len(site.news) == 0 {
		return
	}
	path := site_section_page(.News)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>News</h1>\n<p>What a reader can now see or use in %s, newest first: %d entries. Each entry is one file of <code>%s/</code>, written in the step that made the thing, and never moved or merged. The technical list of the changes of each release is on the page <a href=\"%s\">Releases</a>. The same entries as a feed: <a href=\"%s\">%s</a> (Atom).</p>\n<p>Each entry has a kind, which its color shows: <strong>Shown</strong>, a new thing runs in the system; <strong>Measured</strong>, a number about a thing that exists, with its conditions; <strong>Decided</strong>, a choice that a reader sees, as a name, a mark or a font; <strong>Fixed</strong>, a thing that failed now works. An entry links to its release and to the guide that explains the thing.</p>\n", SITE_SYSTEM_NAME, len(site.news), NEWS_FOLDER, site_page_link(site, path, site_section_page(.Releases)), site_relative(path, SITE_NEWS_FEED), SITE_NEWS_FEED)
	strings.write_string(&b, "<p class=\"source\">The kinds: <span class=\"news-kind accent-program\">Shown</span> a reader can now see or use a new thing; <span class=\"news-kind accent-memory\">Measured</span> a number about a thing that exists, with its conditions; <span class=\"news-kind accent-kernel\">Decided</span> a choice of design that a reader sees; <span class=\"news-kind accent-machine\">Fixed</span> a thing that a reader saw fail now works.</p>\n")
	// One renderer for the page: the ids of the page stay unique, and each
	// term of the glossary links once.
	renderer := site_renderer_make(site, path, NEWS_FOLDER + "/" + NEWS_FOLDER_GUIDE)
	sources := make([dynamic]string, context.temp_allocator)
	append(&sources, NEWS_FOLDER + "/" + NEWS_FOLDER_GUIDE)
	// The anchors of the entries first: an id that the text makes cannot take one.
	for item in site.news {
		renderer.ids[item.anchor] = true
	}
	for &item in site.news {
		entry := item.entry
		renderer.source = strings.concatenate({NEWS_FOLDER, "/", entry.file_name}, context.temp_allocator)
		strings.builder_reset(&renderer.builder)
		site_render_markdown(&renderer, entry.text, entry.text_line)
		item.body = strings.clone(strings.to_string(renderer.builder), context.temp_allocator)

		fmt.sbprintf(&b, "<article class=\"card news-entry %s\" id=\"%s\">\n<h2>", site_news_kind_classes[entry.kind], item.anchor)
		site_escape(&b, entry.title)
		strings.write_string(&b, "</h2>\n")
		site_news_meta(site, &b, path, entry, true)
		// A picture stands beside the text. A film stands under it, over
		// the width of the card: in the column of a picture it is too
		// small to read.
		switch {
		case item.film != "":
			strings.write_string(&b, "<div class=\"news-body with-film\">\n<div class=\"prose\">\n")
		case item.picture != "":
			strings.write_string(&b, "<div class=\"news-body with-picture\">\n<div class=\"prose\">\n")
		case:
			strings.write_string(&b, "<div class=\"news-body\">\n<div class=\"prose\">\n")
		}
		strings.write_string(&b, item.body)
		strings.write_string(&b, "</div>\n")
		if item.film != "" {
			site_news_film(&b, path, item)
		} else {
			site_news_picture(&b, path, item, "news-picture")
		}
		fmt.sbprintf(&b, "</div>\n<p class=\"source\">From <a href=\"%s\"><code>%s/%s</code></a>.</p>\n</article>\n", site_repository_file(site, renderer.source), NEWS_FOLDER, entry.file_name)
	}
	newest := site.news[0].entry
	site_page_add(site, Site_Page{path = path, title = "News", description = site_description_cut(fmt.tprintf("What a reader can now see or use in %s, newest first: %d dated reports, the newest on %s.", SITE_SYSTEM_NAME, len(site.news), newest.date)), section = .News, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = sources[:]})
}

// site_news_home writes the newest entries on the home: the door to the
// page of the news.
site_news_home :: proc(site: ^Site, b: ^strings.Builder) {
	if len(site.news) == 0 {
		return
	}
	home := site_section_page(.Home)
	news_link := site_page_link(site, home, site_section_page(.News))
	strings.write_string(b, "<section aria-labelledby=\"news\">\n<h2 id=\"news\">News</h2>\n<div class=\"news-cards\">\n")
	for item in site.news[:min(len(site.news), SITE_NEWS_HOME_COUNT)] {
		entry := item.entry
		fmt.sbprintf(b, "<article class=\"card news-card %s\">\n<h3><a href=\"%s#%s\">", site_news_kind_classes[entry.kind], news_link, item.anchor)
		site_escape(b, entry.title)
		strings.write_string(b, "</a></h3>\n")
		site_news_meta(site, b, home, entry, false)
		if item.film != "" {
			site_news_film_card_picture(b, home, item, fmt.tprintf("%s#%s", news_link, item.anchor))
		} else {
			site_news_picture(b, home, item, "news-card-picture")
		}
		strings.write_string(b, "<p>")
		site_inline(b, site_news_lead(entry))
		strings.write_string(b, "</p>\n</article>\n")
	}
	fmt.sbprintf(b, "</div>\n<p><a href=\"%s\">Every news entry</a> - <a href=\"%s\">the feed</a></p>\n</section>\n", news_link, site_relative(home, SITE_NEWS_FEED))
}

// site_news_of_release writes, under a release on the page of the
// releases, the entries that name it.
site_news_of_release :: proc(site: ^Site, b: ^strings.Builder, from_page, release_number: string) {
	count := 0
	for item in site.news {
		if item.entry.release != release_number {
			continue
		}
		strings.write_string(b, count == 0 ? "<p class=\"news-links\">News: " : ", ")
		fmt.sbprintf(b, "<a href=\"%s#%s\">", site_page_link(site, from_page, site_section_page(.News)), item.anchor)
		site_escape(b, item.entry.title)
		strings.write_string(b, "</a>")
		count += 1
	}
	if count > 0 {
		strings.write_string(b, "</p>\n")
	}
}

// site_feed_address gives the address of a file of the site that is not a
// page, for a file at the root of the site that another program reads (a
// feed): absolute when the site has an address, else relative to the root.
// A reader resolves a relative address against the address that it
// fetched the file from.
site_feed_address :: proc(site: ^Site, path: string) -> string {
	if site.address == "" {
		return path
	}
	return site_file_address(site.address, path)
}

// site_feed_page_address gives the address of a page (its file, with an
// anchor or none) for a file at the root of the site that another program
// reads (a feed, llms.txt): with a site address the absolute address of
// its folder, else the link from the root, which names its index.html.
site_feed_page_address :: proc(site: ^Site, target: string) -> string {
	if site.address == "" {
		return site_page_link(site, SITE_PAGE, target)
	}
	page_path, anchor := target, ""
	if hash := strings.index_byte(target, '#'); hash >= 0 {
		page_path, anchor = target[:hash], target[hash:]
	}
	return strings.concatenate({site_page_address(site.address, page_path), anchor}, context.temp_allocator)
}

// site_xml_escape writes a text for XML: the five characters of markup.
site_xml_escape :: proc(b: ^strings.Builder, text: string) {
	site_escape(b, text)
}

// site_news_feed gives the Atom feed of the news (RFC 4287). The id of
// the feed and of each entry is the address of its file in the repository,
// on master: an entry file is never moved, so its id never changes, also
// when the site gets an address.
site_news_feed :: proc(site: ^Site) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">\n")
	fmt.sbprintf(&b, "<title>News of %s</title>\n<subtitle>What a reader can now see or use in %s, newest first.</subtitle>\n", SITE_SYSTEM_NAME, SITE_SYSTEM_NAME)
	fmt.sbprintf(&b, "<id>%s/tree/master/%s</id>\n", SITE_REPOSITORY_ADDRESS, NEWS_FOLDER)
	fmt.sbprintf(&b, "<updated>%sT00:00:00Z</updated>\n", site.news[0].entry.date)
	site_feed_author(site, &b)
	strings.write_string(&b, "<link rel=\"alternate\" type=\"text/html\" href=\"")
	site_xml_escape(&b, site_feed_page_address(site, site_section_page(.News)))
	strings.write_string(&b, "\"/>\n")
	if site.address != "" {
		strings.write_string(&b, "<link rel=\"self\" type=\"application/atom+xml\" href=\"")
		site_xml_escape(&b, site_feed_address(site, SITE_NEWS_FEED))
		strings.write_string(&b, "\"/>\n")
	}
	fmt.sbprintf(&b, "<icon>%s</icon>\n", site_feed_address(site, SITE_PICTURE_FOLDER + "/" + SITE_ICON_192))
	for item in site.news {
		entry := item.entry
		strings.write_string(&b, "<entry>\n<title>")
		site_xml_escape(&b, entry.title)
		fmt.sbprintf(&b, "</title>\n<id>%s/blob/master/%s/%s</id>\n", SITE_REPOSITORY_ADDRESS, NEWS_FOLDER, entry.file_name)
		strings.write_string(&b, "<link rel=\"alternate\" type=\"text/html\" href=\"")
		site_xml_escape(&b, site_feed_page_address(site, strings.concatenate({site_section_page(.News), "#", item.anchor}, context.temp_allocator)))
		strings.write_string(&b, "\"/>\n")
		if item.film != "" {
			// The film as a file that goes with the entry: a feed reader
			// offers it, and knows its type and its size before it asks.
			strings.write_string(&b, "<link rel=\"enclosure\" type=\"" + SITE_FILM_TYPE + "\" href=\"")
			site_xml_escape(&b, site_feed_address(site, item.film))
			fmt.sbprintf(&b, "\" length=\"%d\"/>\n", item.film_bytes)
		}
		fmt.sbprintf(&b, "<published>%sT00:00:00Z</published>\n<updated>%sT00:00:00Z</updated>\n", entry.date, entry.date)
		fmt.sbprintf(&b, "<category term=\"%s\"/>\n<summary>", news_kind_names[entry.kind])
		plain := strings.builder_make(context.temp_allocator)
		site_plain(&plain, site_news_lead(entry))
		// The summary is text: site_plain escaped it for HTML, which is
		// also an escape for XML.
		strings.write_string(&b, strings.to_string(plain))
		strings.write_string(&b, "</summary>\n<content type=\"html\">")
		// The content is HTML in a text: its markup is escaped once more.
		html := strings.builder_make(context.temp_allocator)
		strings.write_string(&html, item.body)
		if item.picture != "" {
			fmt.sbprintf(&html, "<p><img src=\"%s\" width=\"%d\" height=\"%d\" alt=\"", site_feed_address(site, item.picture), item.picture_width, item.picture_height)
			site_plain(&html, item.picture_alt)
			strings.write_string(&html, "\"></p>")
		}
		if item.film != "" {
			// A link, not a video element: many feed readers remove one.
			fmt.sbprintf(&html, "<p><a href=\"%s\">Film</a> (WebM with AV1, %s)</p>", site_feed_address(site, item.film), site_film_size_text(item.film_bytes))
		}
		site_xml_escape(&b, strings.to_string(html))
		strings.write_string(&b, "</content>\n</entry>\n")
	}
	strings.write_string(&b, "</feed>\n")
	return strings.to_string(b)
}
