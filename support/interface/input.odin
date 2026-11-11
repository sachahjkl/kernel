package interface

import "support:display"

KEY_CAPACITY :: 16 // The keys of one frame.
FOCUS_ORDER_CAPACITY :: 64 // The elements that can take the focus in one frame.
KEY_TAB :: 0x0F

// A number that names one element from one frame to the next.
Element_Identity :: distinct u64

// identity makes the identity of an element from a text: the 64-bit FNV-1a
// hash of its bytes. 0 is no element.
identity :: proc "contextless" (name: string) -> Element_Identity {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return Element_Identity(hash | 1)
}

// identity_with makes the identity of one of a set of elements: a line of a
// list, a button of a row.
identity_with :: proc "contextless" (base: Element_Identity, index: int) -> Element_Identity {
	hash := u64(base)
	for shift := uint(0); shift < 64; shift += 8 {
		hash = (hash ~ (u64(index) >> shift & 0xFF)) * 0x0000_0100_0000_01B3
	}
	return Element_Identity(hash | 1)
}

Key_Press :: struct {
	code:      u32,
	character: u8,
	modifiers: u32,
	taken:     bool, // An element took the key: no other element takes it.
}

// The input of one frame, filled from the display events of the frame.
Input :: struct {
	pointer_x, pointer_y: int,
	pointer_known:        bool, // The pointer is over the surface, or a button is held.
	pressed, released:    bool, // The left button went down, or up, in this frame.
	button_held:          bool, // The left button is down: the display gives the state, the input needs the change.
	keys:                 [KEY_CAPACITY]Key_Press,
	key_count:            int,
}

// input_add adds one display event to the input of a frame. It gives false
// for an event that it does not take (a key released).
input_add :: proc "contextless" (input: ^Input, event: display.Event) -> bool {
	#partial switch event.kind {
	case .Pointer:
		input.pointer_x, input.pointer_y = event.x, event.y
		input.pointer_known = true
		held := event.buttons & display.BUTTON_LEFT != 0
		input.pressed ||= held && !input.button_held
		input.released ||= !held && input.button_held
		input.button_held = held
		return true
	case .Key:
		if !event.pressed || input.key_count >= KEY_CAPACITY {
			return false
		}
		input.keys[input.key_count] = {code = event.code, character = event.character, modifiers = event.modifiers}
		input.key_count += 1
		return true
	}
	return false
}

// input_has_room says if the input of a frame can take one more key. When
// it cannot, the caller leaves the next events in the ring of the window for
// the next frame: no key is lost.
input_has_room :: proc "contextless" (input: ^Input) -> bool {
	return input.key_count < KEY_CAPACITY
}

// input_clear makes the input of the next frame: the pointer stays where it is.
input_clear :: proc "contextless" (input: ^Input) {
	input.pressed = false
	input.released = false
	input.key_count = 0
}

// What the package keeps between frames, in the memory of the program.
Interface_State :: struct {
	focus:         Element_Identity, // The element that takes the keys.
	under_pointer: Element_Identity, // The element under the pointer in the last frame.
	pressed:       Element_Identity, // The element where the left button went down, until it goes up.
	// The order of the elements that can take the focus, in the last frame:
	// Tab and Shift+Tab follow it.
	focus_order:   [FOCUS_ORDER_CAPACITY]Element_Identity,
	focus_count:   int,
}

// One frame: the table that it fills, the state, the input of the frame.
Frame :: struct {
	table:         ^Draw_Table,
	state:         ^Interface_State,
	input:         ^Input,
	under_pointer: Element_Identity,
	focus_order:   [FOCUS_ORDER_CAPACITY]Element_Identity,
	focus_count:   int,
}

// frame_begin clears the table and starts a frame. Tab and Shift+Tab move
// the focus here, in the order of the last frame.
frame_begin :: proc "contextless" (table: ^Draw_Table, state: ^Interface_State, input: ^Input) -> Frame {
	draw_table_clear(table)
	for &key in input.keys[:input.key_count] {
		if key.code != KEY_TAB || state.focus_count == 0 {
			continue
		}
		key.taken = true
		position := -1
		for item, index in state.focus_order[:state.focus_count] {
			if item == state.focus {
				position = index
			}
		}
		backward := key.modifiers & display.MODIFIER_SHIFT != 0
		if position < 0 {
			position = backward ? 0 : state.focus_count - 1
		}
		step := backward ? state.focus_count - 1 : 1
		state.focus = state.focus_order[(position + step) % state.focus_count]
	}
	return {table = table, state = state, input = input}
}

// frame_end keeps what the next frame needs.
frame_end :: proc "contextless" (frame: ^Frame) {
	state := frame.state
	state.under_pointer = frame.under_pointer
	state.focus_order = frame.focus_order
	state.focus_count = frame.focus_count
	if frame.input.released {
		state.pressed = 0
	}
}

// What the input did to one element in one frame.
Element_Result :: struct {
	activated:     bool, // Pressed and released on it, or Enter or Space with the focus.
	focused:       bool, // It has the focus.
	under_pointer: bool,
	changed:       bool, // A text input: the text changed. A list: the choice changed.
}

// The kinds of elements that take input. The kind says which keys activate it.
Element_Kind :: enum u8 {
	Button, // Enter and Space activate it.
	List, // Enter activates it; up and down move its choice.
	Text_Input, // Enter activates it, in the order of the keys; Space is a character.
}

// element_interact gives what the input did to an element in an area. Each
// such element can take the focus, and joins the order of Tab.
element_interact :: proc "contextless" (frame: ^Frame, element: Element_Identity, area: Area, kind: Element_Kind) -> (result: Element_Result) {
	state := frame.state
	input := frame.input
	if frame.focus_count < FOCUS_ORDER_CAPACITY {
		frame.focus_order[frame.focus_count] = element
		frame.focus_count += 1
	}
	if input.pointer_known && area_contains(area, input.pointer_x, input.pointer_y) {
		result.under_pointer = true
		frame.under_pointer = element
		if input.pressed {
			state.pressed = element
			state.focus = element
		}
		if input.released && state.pressed == element {
			result.activated = true
		}
	}
	result.focused = state.focus == element
	// A text input takes Enter in the order of its keys (text_input).
	if result.focused && kind != .Text_Input {
		for &key in input.keys[:input.key_count] {
			if !key.taken && (key.code == display.KEY_ENTER || kind == .Button && key.character == ' ') {
				key.taken = true
				result.activated = true
			}
		}
	}
	return
}

// key_take gives the next key of the frame that no element took, for an
// element with the focus.
key_take :: proc "contextless" (frame: ^Frame) -> (key: Key_Press, ok: bool) {
	for &item in frame.input.keys[:frame.input.key_count] {
		if !item.taken {
			item.taken = true
			return item, true
		}
	}
	return {}, false
}
