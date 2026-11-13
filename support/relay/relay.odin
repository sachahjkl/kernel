// The relay: what the programs of the `rings` demonstration agree on.
//
// The demonstration has one program per node, and one ring from each node to
// the next. A node takes a record from the ring before it, keeps it for some
// time, and puts it in the ring after it. The `rings` program starts the
// nodes and shows them. It reads the same memory as the nodes: it shows the
// real content of each ring.
package relay

NODE_COUNT :: 6 // The nodes of the demonstration.

// The roles of the context of a node.
GRANT_BEFORE :: 0 // Memory: the ring from the node before. This node reads its command queue.
GRANT_AFTER :: 1 // Memory: the ring to the node after. This node writes its command queue.
GRANT_CONTROL :: 2 // Memory: the ring from the `rings` program.
GRANT_STATE :: 3 // Memory: one State record. This node writes it.
VALUE_WORK_TIME :: 0 // Milliseconds that the node keeps a record.

// The kind of a record in a ring between two nodes, or in a control ring.
// values[0] is the color of the record; values[1] counts the nodes that it passed.
RECORD :: 1

// What a node says about itself, in shared memory. No ring carries it.
State :: struct {
	holding: u32, // 1: the node has a record.
	blocked: u32, // 1: the ring after the node is full.
	color:   u32, // The color of the record that the node holds.
	since:   u64, // When the node took the record.
	release: u64, // When the node gives the record.
	passed:  u64, // Records that the node gave to the ring after it.
}
