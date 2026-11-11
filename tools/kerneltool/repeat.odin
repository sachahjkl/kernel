package kerneltool

import "contract:blake3"
import module "contract:module"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"

// The command repeat: build one module again and again, with no machine,
// and compare each build with the first one: the module file, the LLVM IR
// that Odin wrote, and the object that llc made. One build must give one
// hash (property 11). On a difference, the first module stays beside the
// last one as <module>.first, and the tool names the part of the file where
// the first different byte is. The first IR that differs stays with the IR
// of build 1 (<module>.ll.first and <module>.ll.different).

run_repeat :: proc(args: []string) -> int {
	if len(args) != 2 {
		fmt.eprintln("kerneltool: repeat <module> <count>")
		return EXIT_USAGE
	}
	count, parsed := strconv.parse_int(args[1])
	build: Module_Build
	for item in module_builds {
		if item.name == args[0] {
			build = item
		}
	}
	if build.name == "" || !parsed || count < 2 {
		fmt.eprintfln("kerneltool: repeat: no module %s, or a count below 2", args[0])
		return EXIT_USAGE
	}
	// The paths stay for all the builds: the temporary memory is freed after each one.
	folder := fmt.aprintf("%s/%s", MODULE_BUILD_FOLDER, build.name)
	paths := [3]string{fmt.aprintf("%s/%s.module", MODULE_BUILD_FOLDER, build.name), fmt.aprintf("%s/%s.ll", folder, build.name), fmt.aprintf("%s/objects/%s.o", folder, build.name)}
	kinds := [3]string{"module", "LLVM IR", "object"}
	first: [3][]u8
	different: [3]int
	for number in 0 ..< count {
		if !build_module(build) {
			return EXIT_FAILURE
		}
		for path, index in paths {
			bytes, err := os.read_entire_file(path, context.allocator)
			if err != nil {
				fmt.eprintfln("kerneltool: cannot read %s: %v", path, err)
				return EXIT_FAILURE
			}
			if number == 0 {
				first[index] = bytes
				continue
			}
			if slice.equal(bytes, first[index]) {
				delete(bytes)
				continue
			}
			different[index] += 1
			if index == 1 && different[1] == 1 {
				// The IR files of the two builds, to compare them with diff.
				_ = os.write_entire_file(join(path, ".first"), first[1])
				_ = os.write_entire_file(join(path, ".different"), bytes)
				fmt.printfln("kerneltool: repeat: the LLVM IR of build %d of %s differs: %s.first and %s.different", number + 1, build.name, path, path)
			}
			if index == 0 && different[0] == 1 {
				kept := join(path, ".first")
				_ = os.write_entire_file(kept, first[0])
				at := 0
				for at < min(len(bytes), len(first[0])) && bytes[at] == first[0][at] {
					at += 1
				}
				fmt.printfln("kerneltool: repeat: build %d of %s differs from build 1 at byte %d, in %s (the first build is %s)", number + 1, build.name, at, part_of(first[0], u64(at)), kept)
			}
			delete(bytes)
		}
		free_all(context.temp_allocator)
	}
	hash := blake3.hash(first[0])
	for kind, index in kinds {
		fmt.printfln("kerneltool: repeat: %s of %s: %d of %d builds differ from build 1", kind, build.name, different[index], count - 1)
	}
	fmt.printfln("kerneltool: repeat: the hash of build 1 starts with %x", hash[:8])
	return different[0] == 0 ? 0 : EXIT_FAILURE
}

// part_of names the part of a module file that holds a byte: the header,
// the table directory, a table, or a segment.
part_of :: proc(file: []u8, at: u64) -> string {
	head, error := module.header(file)
	if error != .None {
		return "a file with no valid header"
	}
	if at < size_of(module.Header) {
		return "the header"
	}
	if at < u64(head.header_size) + u64(head.table_count) * size_of(module.Table_Entry) && at >= u64(head.header_size) {
		return "the table directory"
	}
	for kind in module.Table_Kind {
		entry := module.table(file, kind)
		if entry.count != 0 && at >= entry.offset && at < entry.offset + u64(entry.count) * u64(entry.record_size) {
			return fmt.tprintf("the table %v, record %d", kind, (at - entry.offset) / u64(max(entry.record_size, 1)))
		}
	}
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if at >= segment.file_offset && at < segment.file_offset + segment.file_size {
			return fmt.tprintf("segment %d (flags %v), memory offset %x", index, segment.flags, segment.memory_offset + (at - segment.file_offset))
		}
	}
	return "no table and no segment"
}
