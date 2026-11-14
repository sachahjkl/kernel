# The network service and the data path

The kernel is off the data path, and the network stack is a library in the program. One network device with one pair of queues still needs a multiplexer in user space: the network service. This file records what that service is allowed to do to the bytes of a packet, why one copy stays, and the layers that take the service off the data path (`docs/DECISIONS.md`, D-235).

What the service does today is in [`docs/NETWORK.md`](../../../docs/NETWORK.md), "Property 5 as it is built". The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Data path".

## Two terms

The property is about the kernel. It does not define the data path for a service. Two terms make the question exact.

- **Data path**: the code that reads or writes the bytes of the data of a packet.
- **Control path of a packet**: the code that reads the headers of a packet and decides where it goes.

A service on the control path of each packet is not a breach of the letter of the property: its cost line names the multiplexer. What was wrong was work of the transport done outside the program, and more passes over the data than the constraint needs.

## The irreducible constraints

1. **One reader of the receive queue.** The device fills the next buffer, whatever the flow. So a buffer cannot belong to one program in advance, or a program reads frames of another program.
2. **A party that the program cannot change must filter.** A program that writes raw frames forges any source address and port. A program that reads raw frames reads the frames of others.
3. **No kernel entry for each packet**, and a small kernel.
4. **Send has no such constraint.** A send descriptor can name any physical memory. Only the header must be in memory that the program cannot change after the check.

From 1 and 2: on receive, one program outside the receiver reads the headers of each frame, and the frame then moves to the receiver. One copy by a third party stays. No honest design removes it without steering in the device or a kernel entry for each frame.

From 4: on send, nothing is irreducible.

## The layers

| Layer | What changes | Passes of the service over the data |
|---|---|---|
| Before | The service checked the transport checksum on receive, and wrote the UDP header and its checksum on send | Receive 2; send 1 for TCP and 2 for UDP |
| The checksum moves to the program | The program checks the checksum of what it receives. It reads those bytes in any case | Receive 1 |
| One form of endpoint for UDP and TCP | The program writes the whole datagram with its header. The service checks the ports in its copy | Send 1 |
| Send with no copy of the data | A frame has two parts: the headers in memory of the service, the data read by the device from the region of the program | Send 0 |
| A receive queue for each endpoint | The device steers by destination port; the service leaves the receive path of an endpoint | Receive 0 |

The first two layers are built. The last two are not.

## The reasons of each layer

- **UDP is corrected with TCP.** The decision named TCP. But UDP had more of the service on its path than TCP, and the two share the code of the copy and of the check. With only TCP corrected, the service has two send paths and two receive paths. One path is less code than two.
- **The checksum after the demultiplexing.** A frame whose port the wire damaged, and whose Ethernet check passed, can now reach the wrong program before that program refuses it. This was accepted: the check of the link is the guard against damage. The grant, not the checksum, is the guard against a hostile sender, and a hostile sender writes a correct checksum.
- **QUIC does not check the UDP checksum on receive.** It authenticates each packet, which is more. It writes a real checksum on send, because a remote can require it.
- **Send with no copy.** The service copies and checks a private copy of the headers only. The program can change the data after the check: it damages only its own checksum. No new trust: with no IOMMU the frame service can already make the device read any memory.

## The refused forms

- **Pages move, bytes do not, on receive.** The service gives the page of a frame to the program. This is one change of a mapping for each frame: a kernel entry for each packet, or a new batch operation. The service also needs a handle on the program to map into it, an authority that it must not hold. Each unmap needs a message to each processor of the program. A copy of 1460 bytes costs less.
- **A shared pool of frames mapped read-only in each program.** Each program then reads the frames of the others.
- **The frame service reads the headers and copies to the program.** It removes one wake, not the copy. The code that reads hostile frames then holds the right to physical memory. Today that right is in a program that reads no frame.
- **A test machine with several queues.** The two network back ends of the test machine refuse several queues. The others need a right on the host that the tests do not have.
- **Batching as the correction.** It is a mitigation: it lowers the cost of each packet and changes nothing about who reads the bytes.
- **The note of the property deleted.** A deleted note says what the code does not do. The property now has one sentence "as built" that agrees with its cost line.

## The subtle points

- **The correction is of structure, not of speed.** The checksum of a full frame costs under a microsecond, and a round trip costs 60 to 200 microseconds, spent in three programs that wake each other. The tests assert no change of throughput. They wait for a structural fact that the service writes on the log: how many times it read each payload byte, and that it computed no checksum.
- **A segment with a wrong checksum now reaches the library.** A program must release the remote of a dropped segment only when no connection has that remote. Else a damaged segment of a live connection makes the service forget the connection.
- **A SYN with a wrong checksum takes a place** of the admitted remotes of a listen grant until the program releases it or the place goes idle.
- **IPv4, ARP and ICMP echo stay in the service.** They are the shared identity of the machine. The rule for a shared network identity is open.
- **For the layer "send with no copy"**: the region of an endpoint must be contiguous in physical memory, and its frames must stay while a send is in flight. A send then completes when the device used the frame, not after the copy. The rules of the kernel for a region that a device reads while its program stops must be read first.
- **For the layer "a queue for each endpoint"**: the table of admitted remotes of a listen grant has no home. The program then needs its own budgets for unknown remotes, as the QUIC library has. The send path still needs the header check in a service, unless the device filters the source.

## The condition under which the exception ends

A network device with at least one receive queue for each endpoint, and an exact filter by destination port that only the frame service programs. For send, also a filter of the source in the device.

## Not explained by this design

One fetch program sends much slower than it receives. The cause is unknown.
