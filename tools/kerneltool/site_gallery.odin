// The pictures of the screen on the site (docs/SITE.md, "The gallery").
// One table names each picture of
// docs/screenshots that the site shows: its group, its caption, its guide,
// and whether the home shows it. The gallery is the page of every picture
// of the table, in its groups; the carousel is the few pictures of the
// table that the home shows, one in view. A picture of the folder that is
// in no row and in no line of the excluded files stops the command and
// fails a host test: a new picture cannot be forgotten.
package kerneltool

import "core:fmt"
import "core:image/png"
import "core:strings"

// The folder of the pictures of the screen that the machine tests take.
SITE_SCREEN_PICTURE_FOLDER :: "docs/screenshots"
SITE_GALLERY_FOLDER :: "gallery"
// A picture of the screen is the whole screen of the system. The style
// sheet shows a picture of this width at one pixel for one pixel where the
// page has the room, so the table holds pictures of this size only.
SITE_SCREEN_PICTURE_WIDTH :: 1024
SITE_SCREEN_PICTURE_HEIGHT :: 768
// The folder of the site that holds the thumbnails of the gallery.
SITE_THUMBNAIL_FOLDER :: SITE_PICTURE_FOLDER + "/thumbnails"
// A thumbnail has one pixel for each square of this side of its picture:
// a whole divisor, so that each pixel of the thumbnail is the mean of
// whole pixels.
SITE_THUMBNAIL_DIVISOR :: 2
// The most pictures that the home shows.
SITE_HOME_PICTURE_LIMIT :: 8
// The most bytes of a caption. At 360 pixels of width a caption has a box
// of about 310 pixels, 43 characters a line at 14 pixels: a caption of
// this length takes four lines there.
SITE_GALLERY_CAPTION_LIMIT :: 160
// The script of the carousel of the home: the home is whole without it.
SITE_CAROUSEL_SCRIPT :: "carousel.js"
SITE_GALLERY_SOURCE_FILE :: "tools/kerneltool/site_gallery.odin"

// The groups of the gallery, in the order of the page.
Site_Gallery_Group :: enum {
	Desktop,
	Console,
	Mark,
	Rights,
	Modules,
	Memory,
	Developer_Tools,
	Interface,
	Network,
	Storage,
	Boot,
}

Site_Gallery_Group_Text :: struct {
	title: string,
	about: string, // One sentence under the heading of the group.
}

site_gallery_groups := [Site_Gallery_Group]Site_Gallery_Group_Text {
	.Desktop         = {"The desktop and the palette", "The windows, the bar with its two menus, the palette that the key super opens, and the pointer."},
	.Console         = {"The console and the terminal", "The console, where a command is a typed function, the terminal that draws the lines of a program, and the log."},
	.Mark            = {"The mark and the graphics", "The program that plays the animations of the heron of the mark, and a program for fun."},
	.Rights          = {"Rights, grants and faults", "Programs that show what a program reaches and what the kernel refuses: rights, revocation, isolation, budgets, faults and errors."},
	.Modules         = {"Modules", "One file in several roles, the replacement of an import, and the information that each module carries."},
	.Memory          = {"Memory, threads and time", "The address space of a program, its threads on several processors, the scheduling, and the paths that enter the kernel seldom."},
	.Developer_Tools = {"The developer tools", "The tool that inspects a program that runs or that stopped, and the call of an export from the host."},
	.Interface       = {"The interface and the fonts", "The elements of the interface package, the two fonts of the system, and the settings that change them while the programs run."},
	.Network         = {"The network, the cryptography and the randomness", "The network service and its endpoints, TCP and QUIC in programs, the cryptography module and the seed of the system."},
	.Storage         = {"The storage", "The block service, the storage service with its stores and its versions, and a program that keeps its data across a restart."},
	.Boot            = {"The boot and the trusted boot", "The boot display with the stages of the start, and the starts that the trusted boot refuses."},
}

// One picture of the table: a file of docs/screenshots, its group, a
// caption of one sentence that says what the picture shows, and the guide
// of its subject. The rows of one group follow each other on the page in
// the order of the table. A row with a film shows the film in the gallery,
// with the picture as its poster.
Site_Gallery_Row :: struct {
	file:    string, // The name of the file in SITE_SCREEN_PICTURE_FOLDER.
	group:   Site_Gallery_Group,
	caption: string, // One sentence of plain text, at most SITE_GALLERY_CAPTION_LIMIT bytes.
	guide:   string, // A document of docs/ that is a page of the site.
	home:    bool, // The carousel of the home shows it.
	film:    string, // A film of docs/films, or "".
}

site_gallery_rows := [?]Site_Gallery_Row {
	// The desktop and the palette.
	{file = "desktop.png", group = .Desktop, home = true, guide = "docs/INTERFACE.md", caption = "The desktop: the console, life, monitor and plasma in windows, under the bar with the mark, the two menus and the clock."},
	{file = "desktop_moved.png", group = .Desktop, guide = "docs/INTERFACE.md", caption = "Windows after a move with the pointer: plasma, paint, life and monitor on the grid of the desktop."},
	{file = "menu.png", group = .Desktop, guide = "docs/INTERFACE.md", caption = "The menu of the programs: the button of the bar opens it."},
	{file = "windows.png", group = .Desktop, guide = "docs/INTERFACE.md", caption = "The menu of the windows: a press on a line brings the window to the front."},
	{file = "palette.png", group = .Desktop, home = true, guide = "docs/DESIGN.md", film = "docs/films/palette.webm", caption = "The palette: the key super opens one list of the programs, the windows, the commands and the settings, which narrows at each typed key."},
	{file = "palette_open.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The palette with no letter typed: the windows first, then the programs, each with the icon of its kind."},
	{file = "palette_programs.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The letter p in the palette: windows, programs and commands in one ranking, with each matched letter marked."},
	{file = "palette_windows.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The letters mon in the palette: the window of monitor comes before the program of the same name, and Enter brings it to the front."},
	{file = "palette_commands.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The letters memo in the palette: the commands of the console that match, each with its signature."},
	{file = "palette_prefix.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "A prefix keeps one kind in the palette: the sign > lists the commands only."},
	{file = "palette_settings.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "A setting chosen in the palette: the font changes to Spleen through a line that runs in the console."},
	{file = "palette_arguments.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "A command with a parameter in the palette: start asks for a name, and the list gives the modules that match."},
	{file = "palette_arguments_two.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "A command with two parameters in the palette: revoke has the name plasma, and the list gives the grants of that program."},
	{file = "palette_confirm.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The palette asks for a second Enter before it stops a program and closes its window."},
	{file = "palette_confirm_command.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The palette asks for a second Enter before the command shutdown, which stops the machine."},
	{file = "palette_result.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "A command chosen in the palette runs as a line of the console: memory() is in the console behind the panel."},
	{file = "palette_empty.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The palette with letters that nothing matches: it says that nothing has them in its name."},
	{file = "palette_no_provider.png", group = .Desktop, guide = "docs/DESIGN.md", caption = "The palette after the console lost its grant palette: the count says that it has no commands, and shutdown is not found."},
	{file = "pointers_system.png", group = .Desktop, guide = "docs/POINTERS.md", caption = "The pointer pictures: each shape of the pointer theme of the system, at 24 and 48 pixels, with the lines of its hot spot."},
	{file = "pointer_text.png", group = .Desktop, guide = "docs/POINTERS.md", caption = "The pointer over the text of the console takes the shape of a text cursor."},

	// The console and the terminal.
	{file = "console.png", group = .Console, guide = "docs/CONSOLE.md", caption = "The console at the start of the machine, with the window of life that one of its lines started."},
	{file = "console_completion.png", group = .Console, home = true, guide = "docs/CONSOLE.md", caption = "The completion list of the console: mcnt matches monitor.count by a fuzzy match, with the matched letters lit and each signature."},
	{file = "console_history_search.png", group = .Console, guide = "docs/CONSOLE.md", caption = "The history search of the console: Control-R and a part of a line."},
	{file = "tools.png", group = .Console, guide = "docs/CONSOLE.md", caption = "Lines of the console: commands compose, an error says what to do, and the signature of the command shows under the line."},
	{file = "running.png", group = .Console, guide = "docs/CONSOLE.md", caption = "A line runs in the second thread of the console: the console keeps the keys, and Escape stops the call."},
	{file = "tables.png", group = .Console, guide = "docs/MODULE_CONTRACT.md", caption = "Tables as parameters: one description and three ways to call, a hostile caller, and the time of one call."},
	{file = "table_argument.png", group = .Console, guide = "docs/MODULE_CONTRACT.md", caption = "A table as a value of the console: a variable holds it, commands read and change it, and a wrong direction is an error."},
	{file = "terminal.png", group = .Console, guide = "docs/CONSOLE.md", caption = "A terminal with no escape sequence: flood writes millions of styled lines in one second, and the terminal draws only the view."},
	{file = "terminal_keys.png", group = .Console, guide = "docs/CONSOLE.md", caption = "A key is a record from the terminal to its program: flood stops its lines at the key Space, and shows it in its edit line."},
	{file = "terminal_held.png", group = .Console, guide = "docs/CONSOLE.md", caption = "The view of a terminal is held while the program continues to write."},
	{file = "terminal_stopped.png", group = .Console, guide = "docs/CONSOLE.md", caption = "The program stopped: its terminal stays, with the lines that the program wrote."},
	{file = "log.png", group = .Console, guide = "docs/TOOLS.md", caption = "The log: records with a time, a program, a channel and a level, and each value of a text in the color of its kind."},

	// The mark and the graphics.
	{file = "heron.png", group = .Mark, home = true, guide = "docs/DESIGN.md", caption = "The program heron: the heron of the mark held at a frame of its dash, in whole square cells, with the lines of the cells."},
	{file = "heron_free.png", group = .Mark, guide = "docs/DESIGN.md", caption = "The same frame in the free way of the program heron: the frame is stretched, and its cells become rectangles."},
	{file = "temple.png", group = .Mark, guide = "docs/INTERFACE.md", caption = "The temple of Jon: a portrait of Jonathan Blow that turns."},

	// Rights, grants and faults.
	{file = "rights.png", group = .Rights, home = true, guide = "docs/ARCHITECTURE.md", caption = "A program with a part of the rights of two handles: the kernel does four operations and refuses five."},
	{file = "origin.png", group = .Rights, guide = "docs/ARCHITECTURE.md", caption = "The origin of a handle: twelve cases of copies, gifts and revocations, with the answer of the kernel."},
	{file = "revocation.png", group = .Rights, guide = "docs/ARCHITECTURE.md", caption = "Revocation: the console takes back what it lent, and the root service ends the machine grant of a program that runs."},
	{file = "isolated.png", group = .Rights, guide = "docs/MODULE_CONTRACT.md", caption = "An isolated call: a module that faults or loops stops alone."},
	{file = "records.png", group = .Rights, guide = "docs/MODULE_CONTRACT.md", caption = "A record and a lent handle in an isolated call: the module has the rights of the description, for the time of the call."},
	{file = "budget.png", group = .Rights, guide = "docs/ARCHITECTURE.md", caption = "A budget pays for each page and each thread: the kernel refuses when it cannot pay, and each page returns."},
	{file = "limits.png", group = .Rights, guide = "docs/ARCHITECTURE.md", caption = "The limits of a budget: three threads use 5, 20 and 60 percent of one processor, and the kernel refuses 60 of 100 log records."},
	{file = "return_fault.png", group = .Rights, guide = "docs/ARCHITECTURE.md", caption = "The return to a program: the kernel stops each of five children whose thread the processor would refuse, and the machine goes on."},
	{file = "fault_ring.png", group = .Rights, guide = "docs/ARCHITECTURE.md", caption = "The fault ring: a fault of a thread becomes a record for a handler thread of its program, which repairs it or stops the program."},
	{file = "kernel_events.png", group = .Rights, guide = "docs/ARCHITECTURE.md", caption = "The kernel events: the kernel records its own work by a table of rules, and a program reads the records only with the right Events."},
	{file = "errors.png", group = .Rights, guide = "docs/MODULE_CONTRACT.md", caption = "Errors that diagnose: each case makes an error for real, and the line under it is the sentence of its error record."},
	{file = "errors_families.png", group = .Rights, guide = "docs/MODULE_CONTRACT.md", caption = "The second page of the program errors: refusals of Inspect, of a wrapper, of a ring and of an export, each with its sentence."},
	{file = "principals_unlock.png", group = .Rights, guide = "docs/PRINCIPALS.md", caption = "The window of unlock: the passphrase of a named principal, shown as dots."},

	// Modules.
	{file = "roles.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "One module in each role: the file of tally is a program, a service, a library in the console and a sandboxed program."},
	{file = "services.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "A service serves its own exports while it runs: the console draws in the window of paint with isolated calls."},
	{file = "imports.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "The replacement of an import: agenda imports calendar, which has a fault, and the loader gives calendar_fixed in its place."},
	{file = "replacement.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "The console sets a replacement through the root service, and program_modules() gives the replacements that the loader applied."},
	{file = "modules.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "The information of the modules: the manual shows the table of all the modules, with who imports each one and the programs that run it."},
	{file = "module_information.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "The page of one module in the manual: its file, its exports, who imports it, the programs that run it and its documentation."},
	{file = "manual.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "The manual shows the documentation that each module carries in its file."},
	{file = "manual_tables.png", group = .Modules, guide = "docs/MODULE_CONTRACT.md", caption = "The manual on the module sample: the exports that take and give tables, each with its signature and its text."},
	{file = "interface_module.png", group = .Modules, guide = "docs/INTERFACE.md", caption = "The interface package as a module: the same draw table as the package compiled in, and the time of one frame in each way."},

	// Memory, threads and time.
	{file = "pages.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "The page tables as the kernel reads them: the direct map, the kernel stacks between guard pages, the kernel module, the half of a program."},
	{file = "frames.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "Pages on first use and shared code: ten cases with the answer of the kernel, and the measures."},
	{file = "address_space.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "The address space of a program: reserve and commit, a sparse object, guard pages and large pages, each refusal with its error record."},
	{file = "threads.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "One program, five threads: each square is drawn by its own thread."},
	{file = "workers.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "One queue of tiles, one lock, four threads: each tile has the tint of the thread that computed it."},
	{file = "processors.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "Four processors run the threads of one program at the same time: the same picture with 1, 2 and 4 threads."},
	{file = "scheduler.png", group = .Memory, guide = "docs/SCHEDULING.md", caption = "The scheduling strategies: round robin, fair and EEVDF side by side, with the wakes, the delay of a wake and the shares of spinners."},
	{file = "locks.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "The locks of the kernel: kernel entries of 1, 2 and 4 programs, two threads that wake each other, and the waits of each lock."},
	{file = "extended_state.png", group = .Memory, guide = "docs/SIMD.md", caption = "The extended state of each thread: more threads than processors hold every vector register across kernel entries, one square for each."},
	{file = "extended_state_without_avx.png", group = .Memory, guide = "docs/SIMD.md", caption = "The extended state on a processor with no AVX: the kernel saves x87 and SSE only, and each thread keeps xmm0 to xmm15."},
	{file = "clock.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "The time is a page that each program reads: the reads of one second from the page and with a kernel entry."},
	{file = "flow.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "One ring between two threads: the records of one second and the kernel entries that they cost, for two capacities and two ways to wait."},
	{file = "crowd.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "One queue for several writers and several readers, with no lock: the records of one second, against a queue with a lock."},
	{file = "rings.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "Six programs pass records through six rings."},
	{file = "rings_stopped.png", group = .Memory, guide = "docs/ARCHITECTURE.md", caption = "A stopped program takes no record: the records wait in the ring."},

	// The developer tools.
	{file = "inspect.png", group = .Developer_Tools, home = true, guide = "docs/TOOLS.md", caption = "A developer tool: the address space of the console as a band scaled by pages, its mappings, its modules and its threads."},
	{file = "inspect_stopped.png", group = .Developer_Tools, guide = "docs/TOOLS.md", caption = "The developer tool on a program that stopped on a fault: each frame of the stack trace with its procedure and its source line."},
	{file = "inspect_hex.png", group = .Developer_Tools, guide = "docs/TOOLS.md", caption = "The bytes of a program in the developer tool: it reads only the pages that have a page frame."},
	{file = "remote.png", group = .Developer_Tools, guide = "docs/TOOLS.md", caption = "A call from the host: kerneltool call reaches the program remote on one QUIC stream, which makes the isolated call and writes the result back."},

	// The interface and the fonts.
	{file = "interface_elements.png", group = .Interface, guide = "docs/INTERFACE.md", caption = "The interface package: each element live, the draw table of the last frame, the damage by difference."},
	{file = "interface_damage.png", group = .Interface, guide = "docs/INTERFACE.md", caption = "The damage of a frame of the interface package: an outline shows the rectangle that the frame draws again."},
	{file = "interface_font.png", group = .Interface, guide = "docs/FONTS.md", caption = "The interface font, B612 Regular and Bold: proportional, with its pairs, at three positions in a pixel, and digits of one advance."},
	{file = "font_vector.png", group = .Interface, guide = "docs/FONTS.md", caption = "The text of the system is a vector font with subpixel bands: Paper Mono by default, changed to Spleen 8x16 and back while every window runs."},
	{file = "font_spleen.png", group = .Interface, guide = "docs/FONTS.md", caption = "The setting of the font on Spleen 8x16: every window draws its text again in the bitmap font."},
	{file = "font_without_grid_fit.png", group = .Interface, guide = "docs/FONTS.md", caption = "The setting of the grid fit turned off: the vector font drawn from its second glyph cache."},
	{file = "font_candidates.png", group = .Interface, guide = "docs/FONTS.md", caption = "Six candidate fonts beside Spleen 8x16, each from a glyph cache in fixed point, and a word of each enlarged."},
	{file = "settings.png", group = .Interface, guide = "docs/FONTS.md", caption = "The program settings: the font, the subpixel order, the pointer theme and the grid fit change while the programs run."},
	{file = "settings_kept.png", group = .Interface, guide = "docs/FONTS.md", caption = "A setting kept across a restart of the machine: the next start finds the font Spleen in the store of settings."},

	// The network, the cryptography and the randomness.
	{file = "network.png", group = .Network, guide = "docs/NETWORK.md", caption = "The network: a virtio network device in a program, a network service with ARP, IPv4, ICMP echo and UDP, and an endpoint with a grant of one remote."},
	{file = "fetch.png", group = .Network, guide = "docs/NETWORK.md", caption = "The program fetch: a TCP client with a grant of one remote, the refusals of the network service, and 1 MiB received and sent."},
	{file = "server.png", group = .Network, guide = "docs/NETWORK.md", caption = "TCP in the program: server holds a listen grant on the port 80 and serves one table of connections from one thread."},
	{file = "server_real.png", group = .Network, home = true, guide = "docs/NETWORK.md", caption = "A simple HTTP/1.1 server: keep-alive, pipelining, HEAD and each refusal status, with the connections and the last requests, live."},
	{file = "quic_echo.png", group = .Network, guide = "docs/QUIC.md", caption = "The program quic_echo: a QUIC server on the UDP port 4433 that writes back each stream, with the public key that a client pins."},
	{file = "quic_echo_openssl.png", group = .Network, guide = "docs/QUIC.md", caption = "The program quic_echo after the QUIC client of OpenSSL: one connection accepted after a Retry, 51 bytes in and 51 bytes out."},
	{file = "quic_echo_weak.png", group = .Network, guide = "docs/QUIC.md", caption = "The program quic_echo with a weak random seed: it makes no key and listens on nothing."},
	{file = "cryptography_vectors.png", group = .Network, guide = "docs/CRYPTOGRAPHY.md", caption = "The program cryptography_vectors: each primitive against its published test vectors."},
	{file = "randomness.png", group = .Network, guide = "docs/RANDOMNESS.md", caption = "The program randomness: the entropy report of the system and the speed of a draw."},
	{file = "randomness_weak.png", group = .Network, guide = "docs/RANDOMNESS.md", caption = "The program randomness on a machine with no rdseed and no rdrand: the seed of the system is weak, and the report says so."},

	// The storage.
	{file = "disk.png", group = .Storage, guide = "docs/STORAGE.md", caption = "The block service: a virtio disk in a program, a ring, and the data in the memory of the client."},
	{file = "storage.png", group = .Storage, guide = "docs/STORAGE.md", caption = "The storage service: the private store of the console, its limit of blocks, the stores that the principal sees, and a grant that the principal revokes."},
	{file = "storage_versions.png", group = .Storage, guide = "docs/STORAGE.md", caption = "The versions of an object: each commit keeps the state before it."},
	{file = "notes.png", group = .Storage, guide = "docs/STORAGE.md", caption = "A persistent program after a restart of the machine: notes finds its note and its count of 1000 commits in its private store."},
	{file = "notes_versions.png", group = .Storage, guide = "docs/STORAGE.md", caption = "The versions of a note: notes shows an older version with its generation and its time, and Enter restores it."},
	{file = "notes_damaged.png", group = .Storage, guide = "docs/STORAGE.md", caption = "A block of the note changed on the disk outside the storage service: the service serves the count, and notes says that the note is damaged."},
	{file = "power_loss.png", group = .Storage, guide = "docs/STORAGE.md", caption = "After a loss of power during the write of a root: the storage service takes the root before it, and notes finds its note and its count."},

	// The boot and the trusted boot.
	{file = "boot.png", group = .Boot, home = true, guide = "docs/DESIGN.md", caption = "The boot display: the stages of the start on a line of time, the memory, the machine, the boot image, the programs."},
	{file = "boot_measured.png", group = .Boot, guide = "docs/TRUSTED_BOOT.md", caption = "A measured start: the card of the boot image names the test key and the value of the PCR 11 of the TPM."},
	{file = "boot_secure_boot.png", group = .Boot, guide = "docs/TRUSTED_BOOT.md", caption = "A start with Secure Boot: the firmware verified the boot program, then the boot program verified the system."},
	{file = "boot_fails.png", group = .Boot, guide = "docs/TRUSTED_BOOT.md", caption = "A start that fails: the boot display stays, with the failure."},
	{file = "boot_fails_changed_module.png", group = .Boot, guide = "docs/TRUSTED_BOOT.md", caption = "A start that fails: the boot display names the changed file and its two hashes."},
	{file = "boot_fails_changed_kernel.png", group = .Boot, guide = "docs/TRUSTED_BOOT.md", caption = "A start that fails at the kernel module: its hash is not the hash that the system description expects."},
	{file = "boot_fails_wrong_signature.png", group = .Boot, guide = "docs/TRUSTED_BOOT.md", caption = "A start that fails at the boot image: the signature of the system description is wrong, and no file is verified."},
}

// A picture of docs/screenshots that the site does not show, with the
// reason. The list is short: a picture is in the table, or it has its
// reason here.
Site_Gallery_Excluded :: struct {
	file:   string,
	reason: string,
}

site_gallery_excluded := [?]Site_Gallery_Excluded {
	{"notes_crash.png", "The picture was taken while the window of notes drew its note: the text of the note is cut. The pictures notes and power_loss show the store after a restart."},
	{"vector_glyphs.png", "An older picture of the prototype of the vector font: its bar has the words of the system before the mark and the palette. The pictures font_candidates and font_vector show the font of today."},
}

// One picture of the table as the pages show it.
Site_Gallery_Picture :: struct {
	row:            Site_Gallery_Row,
	site_path:      string, // The picture at its full size, in the site.
	thumbnail_path: string, // Its thumbnail, in the site; "" for a row with a film.
	width:          int,
	height:         int,
	film:           Site_News, // The film of the row as the news shows a film; its field film is "" for a row with none.
}

// site_gallery_picture_id gives the id of a picture on a page: the gallery
// and the carousel of the home name a picture by it.
site_gallery_picture_id :: proc(file: string) -> string {
	return strings.concatenate({"picture-", site_slug(strings.trim_suffix(file, ".png"))}, context.temp_allocator)
}

// site_gallery_group_id gives the id of the heading of a group.
site_gallery_group_id :: proc(group: Site_Gallery_Group) -> string {
	return strings.concatenate({"group-", site_slug(site_gallery_groups[group].title)}, context.temp_allocator)
}

// site_gallery_caption_problem gives the fault of a caption, or "": a
// caption is one sentence of plain text that ends with a period, of at
// most SITE_GALLERY_CAPTION_LIMIT bytes. A caption is the alt text of its
// picture too, so it holds no mark of Markdown; the pages escape it.
site_gallery_caption_problem :: proc(caption: string) -> string {
	switch {
	case caption == "":
		return "no caption"
	case len(caption) > SITE_GALLERY_CAPTION_LIMIT:
		return fmt.tprintf("a caption of %d bytes; at most %d", len(caption), SITE_GALLERY_CAPTION_LIMIT)
	case !strings.has_suffix(caption, "."):
		return "a caption that does not end with a period"
	case site_first_sentence(caption) != caption:
		return "a caption of more than one sentence"
	case strings.contains_any(caption, "`*[]"):
		return "a caption with a mark of Markdown; a caption is plain text"
	}
	return ""
}

// site_gallery_table_problems checks the table against the names of the
// PNG files of the folder: each file is in one row or in one line of the
// excluded files, never in both and never twice; each row and each excluded
// line names a file of the folder; each caption has its form; each guide
// is a document of docs/; a film is a WebM file of docs/films; the home
// shows at least one picture and at most SITE_HOME_PICTURE_LIMIT.
site_gallery_table_problems :: proc(rows: []Site_Gallery_Row, excluded: []Site_Gallery_Excluded, folder_files: []string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	in_folder := make(map[string]bool, context.temp_allocator)
	for file in folder_files {
		in_folder[file] = true
	}
	named := make(map[string]bool, context.temp_allocator)
	home_count := 0
	for row in rows {
		if row.file in named {
			append(&problems, fmt.tprintf("%s: two rows of the table of the gallery", row.file))
		}
		named[row.file] = true
		if !strings.has_suffix(row.file, ".png") || strings.contains(row.file, "/") {
			append(&problems, fmt.tprintf("%s: a row names a PNG file of %s by its name", row.file, SITE_SCREEN_PICTURE_FOLDER))
		} else if row.file not_in in_folder {
			append(&problems, fmt.tprintf("%s: a row of the table of the gallery names no file of %s", row.file, SITE_SCREEN_PICTURE_FOLDER))
		}
		if problem := site_gallery_caption_problem(row.caption); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", row.file, problem))
		}
		if !strings.has_prefix(row.guide, "docs/") || !strings.has_suffix(row.guide, ".md") {
			append(&problems, fmt.tprintf("%s: the guide \"%s\" is not a document of docs/", row.file, row.guide))
		}
		if row.film != "" && (!strings.has_prefix(row.film, FILM_DOCUMENT_FOLDER + "/") || !strings.has_suffix(row.film, ".webm")) {
			append(&problems, fmt.tprintf("%s: the film \"%s\" is not a WebM file of %s", row.file, row.film, FILM_DOCUMENT_FOLDER))
		}
		home_count += row.home ? 1 : 0
	}
	excluded_names := make(map[string]bool, context.temp_allocator)
	for line in excluded {
		if line.file in excluded_names {
			append(&problems, fmt.tprintf("%s: two lines of the excluded files", line.file))
		}
		excluded_names[line.file] = true
		if line.file in named {
			append(&problems, fmt.tprintf("%s: in the table of the gallery and in the excluded files", line.file))
		}
		if line.file not_in in_folder {
			append(&problems, fmt.tprintf("%s: an excluded file that is not in %s", line.file, SITE_SCREEN_PICTURE_FOLDER))
		}
		if line.reason == "" {
			append(&problems, fmt.tprintf("%s: an excluded file with no reason", line.file))
		}
	}
	for file in folder_files {
		if file not_in named && file not_in excluded_names {
			append(&problems, fmt.tprintf("%s/%s: a picture that is in no row of the table of the gallery and not in the excluded files (%s)", SITE_SCREEN_PICTURE_FOLDER, file, SITE_GALLERY_SOURCE_FILE))
		}
	}
	if home_count == 0 || home_count > SITE_HOME_PICTURE_LIMIT {
		append(&problems, fmt.tprintf("the home shows %d pictures of the table of the gallery; at least 1 and at most %d", home_count, SITE_HOME_PICTURE_LIMIT))
	}
	return problems[:]
}

// site_gallery_folder_files gives the names of the PNG files of the folder
// of the pictures of the screen, in the order of their names.
site_gallery_folder_files :: proc() -> (names: []string, ok: bool) {
	paths := files_with_suffix(SITE_SCREEN_PICTURE_FOLDER, ".png") or_return
	list := make([]string, len(paths), context.temp_allocator)
	for path, index in paths {
		list[index] = site_file_name(path)
	}
	return list, true
}

// site_gallery_read checks the table against the folder and reads the size
// of each picture, before any page is written. Each picture of the table
// is copied to the site at its full size; its thumbnail is written after
// the copies (site_gallery_thumbnails_write).
site_gallery_read :: proc(site: ^Site) -> bool {
	folder_files := site_gallery_folder_files() or_return
	problems := site_gallery_table_problems(site_gallery_rows[:], site_gallery_excluded[:], folder_files)
	if len(problems) > 0 {
		for problem in problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		fmt.eprintfln("kerneltool: site: %d problems of the table of the gallery; no page is written", len(problems))
		return false
	}
	pictures := make([dynamic]Site_Gallery_Picture, context.temp_allocator)
	for row in site_gallery_rows {
		source := strings.concatenate({SITE_SCREEN_PICTURE_FOLDER, "/", row.file}, context.temp_allocator)
		if _, is_page := site.documents[row.guide]; !is_page {
			fmt.eprintfln("kerneltool: site: %s: the guide %s of its row of the table of the gallery is not a page of the site", source, row.guide)
			return false
		}
		data := read_file(source) or_return
		width, height, is_png := site_png_size(data)
		if !is_png || width != SITE_SCREEN_PICTURE_WIDTH || height != SITE_SCREEN_PICTURE_HEIGHT {
			fmt.eprintfln("kerneltool: site: %s is not a PNG file of %d by %d pixels, the screen of the system: the gallery shows pictures of the screen only", source, SITE_SCREEN_PICTURE_WIDTH, SITE_SCREEN_PICTURE_HEIGHT)
			return false
		}
		picture := Site_Gallery_Picture{row = row, width = width, height = height}
		picture.site_path = strings.concatenate({SITE_PICTURE_FOLDER, "/", row.file}, context.temp_allocator)
		site.copies[picture.site_path] = source
		if row.film == "" {
			picture.thumbnail_path = strings.concatenate({SITE_THUMBNAIL_FOLDER, "/", row.file}, context.temp_allocator)
		} else {
			// The site copies the film as it is, as the news does.
			film_data := read_file(row.film) or_return
			film_width, film_height, sized := film_document_picture_size(film_data)
			if !sized {
				fmt.eprintfln("kerneltool: site: the film %s states no width and no height of its pictures", row.film)
				return false
			}
			picture.film = Site_News{picture = picture.site_path, picture_width = width, picture_height = height, picture_alt = row.caption}
			picture.film.film = strings.concatenate({SITE_FILM_FOLDER, "/", site_file_name(row.film)}, context.temp_allocator)
			picture.film.film_width, picture.film.film_height, picture.film.film_bytes = film_width, film_height, len(film_data)
			site.copies[picture.film.film] = row.film
		}
		append(&pictures, picture)
	}
	site.gallery = pictures[:]
	return true
}

// site_thumbnail_pixels gives the pixels of a picture at one pixel for
// each square of SITE_THUMBNAIL_DIVISOR pixels: each channel of a pixel is
// the mean of that channel over the square, rounded to the nearest. A
// picture of the screen is text and lines of one pixel: the mean keeps a
// line and the form of a letter as a lighter tone, where one pixel taken
// from each square drops every second line and breaks the letters. The
// width and the height are multiples of the divisor, so each square is
// whole.
site_thumbnail_pixels :: proc(pixels: []u8, width, height, channels: int) -> (thumbnail: []u8, thumbnail_width, thumbnail_height: int, ok: bool) {
	if width <= 0 || height <= 0 || channels <= 0 || width % SITE_THUMBNAIL_DIVISOR != 0 || height % SITE_THUMBNAIL_DIVISOR != 0 || len(pixels) != width * height * channels {
		return nil, 0, 0, false
	}
	thumbnail_width = width / SITE_THUMBNAIL_DIVISOR
	thumbnail_height = height / SITE_THUMBNAIL_DIVISOR
	thumbnail = make([]u8, thumbnail_width * thumbnail_height * channels, context.temp_allocator)
	square :: SITE_THUMBNAIL_DIVISOR * SITE_THUMBNAIL_DIVISOR
	for y in 0 ..< thumbnail_height {
		for x in 0 ..< thumbnail_width {
			for channel in 0 ..< channels {
				sum := 0
				for row in 0 ..< SITE_THUMBNAIL_DIVISOR {
					for column in 0 ..< SITE_THUMBNAIL_DIVISOR {
						sum += int(pixels[((y * SITE_THUMBNAIL_DIVISOR + row) * width + x * SITE_THUMBNAIL_DIVISOR + column) * channels + channel])
					}
				}
				thumbnail[(y * thumbnail_width + x) * channels + channel] = u8((sum + square / 2) / square)
			}
		}
	}
	return thumbnail, thumbnail_width, thumbnail_height, true
}

// site_thumbnail_encode gives the PNG file of the thumbnail of a PNG file
// of 8 bits a channel. The encoder is the one of the pictures of the
// repository: the same pixels give the same bytes at each build.
site_thumbnail_encode :: proc(data: []u8) -> (file: []u8, ok: bool) {
	source, load_error := png.load_from_bytes(data, allocator = context.temp_allocator)
	if load_error != nil || source == nil || source.depth != 8 {
		return nil, false
	}
	pixels, width, height, halved := site_thumbnail_pixels(source.pixels[:], source.width, source.height, source.channels)
	if !halved {
		return nil, false
	}
	encoded, encode_error := png_encode(width, height, source.channels, pixels)
	if encode_error != nil {
		return nil, false
	}
	return encoded, true
}

// site_gallery_thumbnails_write writes the thumbnail of each picture of the
// gallery that has one, after the pictures themselves, and prints the bytes
// of the two forms: the measure of what the thumbnails save a reader of
// the gallery.
site_gallery_thumbnails_write :: proc(site: ^Site) -> bool {
	thumbnail_bytes, picture_bytes, count := 0, 0, 0
	for picture in site.gallery {
		if picture.thumbnail_path == "" {
			continue
		}
		source := site.copies[picture.site_path]
		data := read_file(source) or_return
		thumbnail, encoded := site_thumbnail_encode(data)
		if !encoded {
			fmt.eprintfln("kerneltool: site: cannot write the thumbnail of %s: a PNG file of 8 bits a channel whose width and height are multiples of %d", source, SITE_THUMBNAIL_DIVISOR)
			return false
		}
		site_write_file(site, picture.thumbnail_path, thumbnail) or_return
		thumbnail_bytes += len(thumbnail)
		picture_bytes += site.files[picture.site_path]
		count += 1
	}
	fmt.printfln("kerneltool: site: %d thumbnails of the gallery: %d bytes; the same pictures at full size: %d bytes", count, thumbnail_bytes, picture_bytes)
	return true
}

// site_gallery_guide_link writes the link to the guide of a picture, with
// the title of the guide.
site_gallery_guide_link :: proc(site: ^Site, b: ^strings.Builder, from_page, guide: string) {
	page, is_page := site.documents[guide]
	if !is_page {
		return
	}
	title := strings.trim_suffix(site_file_name(guide), ".md")
	for candidate in site.guides {
		if candidate.source == guide {
			title = candidate.title
		}
	}
	fmt.sbprintf(b, " <a class=\"gallery-guide\" href=\"%s\">Guide: ", site_page_link(site, from_page, page))
	site_escape(b, title)
	strings.write_string(b, "</a>")
}

// site_gallery_caption writes the caption of a picture: its place among
// the pictures of the carousel when it has one, its sentence, and the link
// to its guide. The sentence is the alt text of the picture too, so a
// screen reader reads it there once.
site_gallery_caption :: proc(site: ^Site, b: ^strings.Builder, from_page: string, picture: Site_Gallery_Picture, place: string) {
	strings.write_string(b, "<figcaption>")
	if place != "" {
		strings.write_string(b, "<span class=\"carousel-place\">")
		site_escape(b, place)
		strings.write_string(b, "</span> ")
	}
	strings.write_string(b, "<span aria-hidden=\"true\">")
	site_escape(b, picture.row.caption)
	strings.write_string(b, "</span>")
	site_gallery_guide_link(site, b, from_page, picture.row.guide)
	strings.write_string(b, "</figcaption>")
}

// site_gallery_figure writes one picture of the gallery: its thumbnail as
// a link to the picture at its full size, then its caption. A row with a
// film shows the film, by the procedure of the news, over the whole width
// of the group.
site_gallery_figure :: proc(site: ^Site, b: ^strings.Builder, from_page: string, picture: Site_Gallery_Picture) {
	id := site_gallery_picture_id(picture.row.file)
	if picture.film.film != "" {
		fmt.sbprintf(b, "<div class=\"gallery-film\" id=\"%s\">\n", id)
		site_news_film(b, from_page, picture.film)
		// The film has no alt text: its caption is read as it is.
		strings.write_string(b, "<p class=\"gallery-caption\">")
		site_escape(b, picture.row.caption)
		site_gallery_guide_link(site, b, from_page, picture.row.guide)
		strings.write_string(b, "</p>\n</div>\n")
		return
	}
	fmt.sbprintf(b, "<figure id=\"%s\"><a href=\"%s\"><img src=\"%s\" width=\"%d\" height=\"%d\" loading=\"lazy\" decoding=\"async\" alt=\"", id, site_relative(from_page, picture.site_path), site_relative(from_page, picture.thumbnail_path), picture.width / SITE_THUMBNAIL_DIVISOR, picture.height / SITE_THUMBNAIL_DIVISOR)
	site_escape(b, picture.row.caption)
	strings.write_string(b, "\"></a>")
	site_gallery_caption(site, b, from_page, picture, "")
	strings.write_string(b, "</figure>\n")
}

// site_gallery_group_count gives the count of the pictures of a group.
site_gallery_group_count :: proc(pictures: []Site_Gallery_Picture, group: Site_Gallery_Group) -> int {
	count := 0
	for picture in pictures {
		count += picture.row.group == group ? 1 : 0
	}
	return count
}

// site_gallery_group_html writes one group of the gallery: its heading,
// its sentence with the count of its pictures, and its pictures in the
// order of the table.
site_gallery_group_html :: proc(site: ^Site, b: ^strings.Builder, from_page: string, group: Site_Gallery_Group) {
	count := site_gallery_group_count(site.gallery, group)
	if count == 0 {
		return
	}
	id := site_gallery_group_id(group)
	text := site_gallery_groups[group]
	fmt.sbprintf(b, "<section aria-labelledby=\"%s\">\n<h2 id=\"%s\">", id, id)
	site_escape(b, text.title)
	strings.write_string(b, "</h2>\n<p>")
	site_escape(b, text.about)
	word: string = count == 1 ? "picture" : "pictures"
	fmt.sbprintf(b, " %d %s.</p>\n<div class=\"pictures gallery-pictures\">\n", count, word)
	for picture in site.gallery {
		if picture.row.group == group {
			site_gallery_figure(site, b, from_page, picture)
		}
	}
	strings.write_string(b, "</div>\n</section>\n")
}

// site_gallery_add writes the page of the gallery: every picture of the
// table, in its groups.
site_gallery_add :: proc(site: ^Site) {
	if len(site.gallery) == 0 {
		return
	}
	path := site_section_page(.Gallery)
	b := strings.builder_make(context.temp_allocator)
	group_count := 0
	for group in Site_Gallery_Group {
		group_count += site_gallery_group_count(site.gallery, group) > 0 ? 1 : 0
	}
	fmt.sbprintf(&b, "<h1>Gallery</h1>\n<p class=\"lead\">%d pictures of the screen of %s, in %d groups.</p>\n<p>The machine tests take each picture under QEMU, and the repository holds them. A picture of this page is at one half of its size, and opens at its full size: one pixel of the picture for one pixel of the screen of the system. Each caption says what the picture shows, and links to the guide of its subject.</p>\n", len(site.gallery), SITE_SYSTEM_NAME, group_count)
	strings.write_string(&b, "<nav class=\"gallery-groups\" aria-label=\"Groups of pictures\">\n<ul class=\"doors\">\n")
	for group in Site_Gallery_Group {
		if site_gallery_group_count(site.gallery, group) == 0 {
			continue
		}
		fmt.sbprintf(&b, "<li><a href=\"#%s\">", site_gallery_group_id(group))
		site_escape(&b, site_gallery_groups[group].title)
		strings.write_string(&b, "</a></li>\n")
	}
	strings.write_string(&b, "</ul>\n</nav>\n")
	for group in Site_Gallery_Group {
		site_gallery_group_html(site, &b, path, group)
	}
	site_source_line(site, &b, SITE_GALLERY_SOURCE_FILE, SITE_SCREEN_PICTURE_FOLDER)
	site_page_add(site, Site_Page{path = path, title = "Gallery", description = site_description_cut(fmt.tprintf("%d pictures of the screen of %s, in %d groups: what each picture shows, with the guide of its subject.", len(site.gallery), SITE_SYSTEM_NAME, group_count)), section = .Gallery, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = site_sources(SITE_GALLERY_SOURCE_FILE)})
}

// site_gallery_home_pictures gives the pictures that the home shows, in
// the order of the table.
site_gallery_home_pictures :: proc(pictures: []Site_Gallery_Picture) -> []Site_Gallery_Picture {
	shown := make([dynamic]Site_Gallery_Picture, context.temp_allocator)
	for picture in pictures {
		if picture.row.home {
			append(&shown, picture)
		}
	}
	return shown[:]
}

// site_carousel_write writes the carousel of the home: a row of pictures
// at their full size that scrolls sideways and stops at each picture, one
// in view, with a numbered link to each picture above it. Every picture is
// in the page, so a reader with no script reaches each one by its link, by
// the scroll bar of the row or by a swipe. Each picture has its width and
// its height, so the row has its room before a picture came. Nothing
// moves by itself.
site_carousel_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string) {
	shown := site_gallery_home_pictures(site.gallery)
	if len(shown) == 0 {
		return
	}
	strings.write_string(b, "<section class=\"carousel\" aria-labelledby=\"pictures\">\n<h2 id=\"pictures\">The machine</h2>\n<p class=\"source\">Pictures of the screen that the machine tests take under QEMU. A picture opens at its full size.</p>\n")
	strings.write_string(b, "<nav class=\"carousel-controls\" aria-label=\"Pictures of the machine\">\n<ol>\n")
	for picture, index in shown {
		fmt.sbprintf(b, "<li><a href=\"#%s\" data-slide=\"%d\" aria-label=\"Picture %d of %d: ", site_gallery_picture_id(picture.row.file), index, index + 1, len(shown))
		site_escape(b, picture.row.caption)
		fmt.sbprintf(b, "\">%d</a></li>\n", index + 1)
	}
	strings.write_string(b, "</ol>\n</nav>\n<div class=\"carousel-track\" role=\"region\" aria-label=\"Pictures of the machine, one in view\" tabindex=\"0\">\n")
	for picture, index in shown {
		link := site_relative(from_page, picture.site_path)
		fmt.sbprintf(b, "<figure class=\"carousel-slide\" id=\"%s\"><a href=\"%s\"><img src=\"%s\" width=\"%d\" height=\"%d\" loading=\"lazy\" decoding=\"async\" alt=\"", site_gallery_picture_id(picture.row.file), link, link, picture.width, picture.height)
		site_escape(b, picture.row.caption)
		strings.write_string(b, "\"></a>")
		site_gallery_caption(site, b, from_page, picture, fmt.tprintf("%d of %d", index + 1, len(shown)))
		strings.write_string(b, "</figure>\n")
	}
	strings.write_string(b, "</div>\n")
	if site_page_exists(site, site_section_page(.Gallery)) {
		fmt.sbprintf(b, "<p><a href=\"%s\">All %d pictures, in the gallery</a></p>\n", site_page_link(site, from_page, site_section_page(.Gallery)), len(site.gallery))
	}
	strings.write_string(b, "</section>\n")
}

// The rules of the gallery and of the carousel, with no color of their
// own. A picture is never shown wider than its pixels: a thumbnail at most
// at its width, a picture of the carousel at most at the width of the
// screen of the system. Its width is a share of its box and its height
// follows from the width and the height of its element, so the page keeps
// the room of a picture before it came. The row of the carousel has the
// height of its tallest picture and caption, so a change of picture moves
// nothing under it. A caption wraps in its box at every width.
SITE_GALLERY_RULES :: `
.gallery-groups { margin-bottom: 16px; }
.gallery-pictures figure:target { border-color: var(--line); }
.gallery-film { grid-column: 1 / -1; min-width: 0; }
.gallery-film .news-film { margin-top: 0; }
.gallery-caption { margin: 8px 0 0; color: var(--dim); font-size: 14px; }
.gallery-guide { font-size: 14px; }
.carousel-controls ol { list-style: none; margin: 0 0 8px; padding: 0; display: flex; flex-wrap: wrap; gap: 4px; }
.carousel-controls li { margin: 0; }
.carousel-controls a { display: block; width: 32px; height: 32px; line-height: 30px; text-align: center; font-family: var(--mono); font-size: 14px; text-decoration: none; background: var(--track); border: 1px solid var(--track); }
.carousel-controls a[aria-current="true"] { background: var(--card-top); border-color: var(--line); }
.carousel-track { display: flex; overflow-x: auto; scroll-snap-type: x mandatory; overscroll-behavior-x: contain; margin-bottom: 16px; }
.carousel-slide { flex: 0 0 100%; scroll-snap-align: start; scroll-margin-top: calc(var(--bar-height) + 56px); }
.carousel-slide img { margin: 0 auto; }
.carousel-place { margin-right: 8px; font-family: var(--mono); font-size: 12px; }
`

// site_gallery_rules gives the rules of the gallery and of the carousel
// for the style sheet. The two widths come from the size of a picture of
// the screen, which the table holds only.
site_gallery_rules :: proc() -> string {
	// The braces of a rule are not in a format: the formatter reads a brace
	// as the start of a value.
	thumbnail_width := fmt.tprintf("%d", SITE_SCREEN_PICTURE_WIDTH / SITE_THUMBNAIL_DIVISOR)
	picture_width := fmt.tprintf("%d", SITE_SCREEN_PICTURE_WIDTH)
	return strings.concatenate({SITE_GALLERY_RULES, ".gallery-pictures figure img { max-width: ", thumbnail_width, "px; }\n.carousel-slide img { max-width: ", picture_width, "px; }\n"}, context.temp_allocator)
}

// site_carousel_script gives the script of the carousel of the home. The
// home is whole without it: the numbered links and the scroll of the row
// reach each picture. The script adds three things. A numbered link shows
// its picture with no move of the page. The keys Left, Right, Home and End
// change the picture while the row has the focus. The link of the picture
// in view is marked. It starts no timer: a picture changes only when the
// reader asks, and it changes at once, with no movement.
site_carousel_script :: proc() -> string {
	return `// The carousel of the home: one picture in view. The page works with no
// script; this file adds the keys and the mark of the picture in view.
(function () {
  "use strict";
  var track = document.querySelector(".carousel-track");
  if (!track) {
    return;
  }
  var slides = track.querySelectorAll(".carousel-slide");
  var links = document.querySelectorAll(".carousel-controls a");
  if (slides.length === 0 || links.length !== slides.length) {
    return;
  }
  var current = 0;
  function bounded(index) {
    return Math.max(0, Math.min(slides.length - 1, index));
  }
  function mark(index) {
    current = index;
    for (var i = 0; i < links.length; i += 1) {
      if (i === index) {
        links[i].setAttribute("aria-current", "true");
      } else {
        links[i].removeAttribute("aria-current");
      }
    }
  }
  // Each picture takes the whole width of the row, so the place of the
  // scroll gives the picture in view.
  function inView() {
    var width = track.clientWidth;
    return width > 0 ? bounded(Math.round(track.scrollLeft / width)) : 0;
  }
  // At once: the row jumps to the picture, and nothing moves that the
  // reader did not ask for.
  function show(index) {
    var target = bounded(index);
    track.scrollLeft = target * track.clientWidth;
    mark(target);
  }
  function listen(link, index) {
    link.addEventListener("click", function (event) {
      if (event.button !== 0 || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) {
        return;
      }
      event.preventDefault();
      show(index);
    });
  }
  for (var i = 0; i < links.length; i += 1) {
    listen(links[i], i);
  }
  track.addEventListener("keydown", function (event) {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) {
      return;
    }
    var target = -1;
    if (event.key === "ArrowLeft") {
      target = current - 1;
    } else if (event.key === "ArrowRight") {
      target = current + 1;
    } else if (event.key === "Home") {
      target = 0;
    } else if (event.key === "End") {
      target = slides.length - 1;
    } else {
      return;
    }
    event.preventDefault();
    show(target);
  });
  track.addEventListener("scroll", function () {
    mark(inView());
  }, { passive: true });
  mark(inView());
})();
`
}
