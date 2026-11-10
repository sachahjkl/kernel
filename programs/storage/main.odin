// The storage service: it keeps the private store of each program on the data disk, through a block service. No program sees a shared tree of names.
//
// The root service decides who has a store: it names the store of each connection, and its limit of blocks. A program reaches its own store only: the exports take the name of an object, never the name of a store. The root service names a program that it starts again with the same name, and the program finds its data.
//
// A change is one commit, on the disk when the call returns: the system has no save action. The disk always has the state of the last commit, or of the one before: a stop of the machine during a commit never shows a part of it. The checks of the blocks show each change that the service did not make.
//
// The person sees all the stores with stores(), from a program that acts for the person: the console.
package storage_service

import "contract:block"
import "contract:isolated"
import "support:system"

// The store of the caller of the export that runs: the name and the limit
// that the root service gave to its connection.
caller_store :: proc "contextless" () -> (name: string, limit: u64, person: bool) {
	connection := system.service_caller()
	if connection == nil {
		return "", 0, false
	}
	return system.name_of(connection.caller[:]), connection.grant & isolated.CALLER_AMOUNT_MASK, connection.grant & isolated.CALLER_PERSON != 0
}

// write replaces the object with this name in the store of the caller, with the bytes of data, in one commit on the disk. The result is the generation of the commit, or a negative number: -1 no store, -2 over the limit of the store, -3 a wrong name, -4 too large, -5 no room, -6 a disk error.
@(export, link_name = "write")
write :: proc "c" (name: ^string, data: ^string) -> i64 {
	store, limit, _ := caller_store()
	return change(store, limit, name^, transmute([]u8)data^, false)
}

// read gives the bytes of the object with this name in the store of the caller. The text is empty when the store has no such object.
@(export, link_name = "read")
read_export :: proc "c" (name: ^string, result: ^[]u8) -> i64 {
	store, limit, _ := caller_store()
	if limit == 0 {
		return 0
	}
	if size := object_size(store, name^); size > i64(len(result)) {
		return size // The caller sees that the text did not fit.
	}
	return max(read(store, name^, result^), 0)
}

// size gives the count of bytes of the object with this name in the store of the caller, or -7 when it has no such object.
@(export, link_name = "size")
size :: proc "c" (name: ^string) -> i64 {
	store, limit, _ := caller_store()
	if limit == 0 {
		return ERROR_NO_STORE
	}
	return object_size(store, name^)
}

// remove removes the object with this name from the store of the caller, in one commit. The result is the generation of the commit, or a negative number: -7 no such object.
@(export, link_name = "remove")
remove :: proc "c" (name: ^string) -> i64 {
	store, limit, _ := caller_store()
	return change(store, limit, name^, nil, true)
}

// objects gives the objects of the store of the caller: the name, the bytes and the generation of the last change of each one.
@(export, link_name = "objects")
objects :: proc "c" (result: ^[]u8) -> i64 {
	store, limit, _ := caller_store()
	writer := system.Writer{buffer = result^}
	if limit == 0 {
		system.write_part(&writer, "no store")
		return i64(writer.count)
	}
	index := store_find(store)
	count := 0
	if index >= 0 {
		for &object in tables[index].objects {
			if object.name[0] == 0 {
				continue
			}
			if count != 0 {
				system.write_part(&writer, "; ")
			}
			parts := [?]system.Part{system.name_of(object.name[:]), " ", object.size, " bytes, generation ", object.generation}
			for part in parts {
				system.write_part(&writer, part)
			}
			count += 1
		}
	}
	if count == 0 {
		system.write_part(&writer, "no object")
	}
	return i64(writer.count)
}

// stores gives each store of the disk, with its objects, its blocks and its limit, and the count of connections that hold its grant now. Only a caller that acts for the person sees them.
@(export, link_name = "stores")
stores :: proc "c" (result: ^[]u8) -> i64 {
	_, _, person := caller_store()
	writer := system.Writer{buffer = result^}
	if !person {
		system.write_part(&writer, "no grant to see the stores")
		return i64(writer.count)
	}
	parts := [?]system.Part{"generation ", root.generation, ", ", in_use_count, " of ", root.disk_blocks, " blocks in use"}
	for part in parts {
		system.write_part(&writer, part)
	}
	for &store, index in root.stores {
		if store.name[0] == 0 {
			continue
		}
		object_count: u64
		for &object in tables[index].objects {
			if object.name[0] != 0 {
				object_count += 1
			}
		}
		holders: u64
		for &connection in service.connections {
			if connection.calls.head != nil && system.name_of(connection.caller[:]) == system.name_of(store.name[:]) && connection.grant & isolated.CALLER_AMOUNT_MASK != 0 {
				holders += 1
			}
		}
		line := [?]system.Part{"; ", system.name_of(store.name[:]), ": ", object_count, " objects, ", store.used, " of ", store.limit, " blocks, ", holders, holders == 1 ? " connection" : " connections"}
		for part in line {
			system.write_part(&writer, part)
		}
	}
	return i64(writer.count)
}

object_size :: proc "contextless" (store: string, name: string) -> i64 {
	index := store_find(store)
	if index < 0 {
		return ERROR_ABSENT
	}
	object := object_find(&tables[index], name)
	if object < 0 {
		return ERROR_ABSENT
	}
	return i64(tables[index].objects[object].size)
}

service: system.Service

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ok: bool
	if service, ok = system.service_open(ctx); !ok {
		system.log_in("storage", .Error, "storage: no service ring")
		system.stop(1)
	}
	ring_memory := ctx.handles[block.GRANT_RING]
	status: system.Status
	if blocks, status = system.ring_open(ring_memory); status != .Ok {
		system.log_in("storage", .Error, "storage: no block ring")
		system.stop(1)
	}
	memory, memory_status := system.memory_create(REGION_BLOCKS, 0, {.Contiguous}) // The device reads and writes it.
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		system.log_in("storage", .Error, "storage: no data region")
		system.stop(1)
	}
	region = ([^]u8)(address)
	// The block service maps the ring when it starts.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for attempt := 0; attempt < 2000 && give_status != .Ok; attempt += 1 {
		if given, give_status = system.give(ring_memory, memory, {.Read, .Write}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok || block.Status(command(.Attach, {0 = u64(given)}).kind) != .Ok {
		system.log_in("storage", .Error, "storage: the block service refused the data region")
		system.stop(1)
	}
	info := command(.Info)
	start := system.time()
	mounted := mount(info.values[0])
	elapsed := system.time() - start
	switch {
	case mounted.failed:
		system.log_in("storage", .Error, "storage: no valid root on the disk: the service keeps the disk as it is, and serves nothing")
		system.stop(1)
	case mounted.formatted:
		system.log("storage: ok, a new disk: generation 1, ", root.disk_blocks, " blocks")
	case:
		if mounted.older {
			system.log_in("storage", .Warning, "storage: the newest root names a block with a wrong check: the root before it is used")
		}
		system.log("storage: ok, generation ", mounted.generation, ": ", mounted.stores, " stores, ", mounted.objects, " objects, ", in_use_count, " blocks in use, ", mounted.checked, " blocks checked, ", mounted.wrong, " wrong, in ", elapsed, " ms")
	}
	for {
		wait: system.Wait
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
	}
}
