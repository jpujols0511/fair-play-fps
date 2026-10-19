class_name FpevCrc32
extends RefCounted

const POLYNOMIAL := 0xEDB88320
static var _table := PackedInt64Array()


static func compute(data: PackedByteArray) -> int:
	_ensure_table()
	var crc := 0xFFFFFFFF
	for byte_value in data:
		var index := (crc ^ int(byte_value)) & 0xFF
		crc = (_table[index] ^ (crc >> 8)) & 0xFFFFFFFF
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


static func _ensure_table() -> void:
	if _table.size() == 256:
		return
	_table.resize(256)
	for index in range(256):
		var value := index
		for _bit in range(8):
			value = (value >> 1) ^ (POLYNOMIAL if (value & 1) != 0 else 0)
		_table[index] = value & 0xFFFFFFFF
