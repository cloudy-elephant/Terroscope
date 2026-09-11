class_name SeededRng
extends RefCounted

## Park-Miller RNG. Its complete state is one JSON-safe positive integer.
const MODULUS: int = 2147483647
const MULTIPLIER: int = 48271

var state: int


func _init(seed_value: int = 1) -> void:
	state = posmod(seed_value, MODULUS - 1) + 1


func next_int() -> int:
	state = (state * MULTIPLIER) % MODULUS
	return state


func next_index(size: int) -> int:
	assert(size > 0, "Cannot choose from an empty collection")
	return next_int() % size


func shuffled(values: Array) -> Array:
	var result: Array = values.duplicate(true)
	for index in range(result.size() - 1, 0, -1):
		var swap_index: int = next_index(index + 1)
		var temporary: Variant = result[index]
		result[index] = result[swap_index]
		result[swap_index] = temporary
	return result


func snapshot() -> int:
	return state


func restore(saved_state: int) -> void:
	assert(saved_state > 0 and saved_state < MODULUS, "Invalid RNG state")
	state = saved_state
