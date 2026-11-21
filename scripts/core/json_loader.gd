class_name JsonConfigLoader
extends RefCounted

const MAX_STRING_LENGTH: int = 2048

static func load_dictionary(resource_path: String) -> Dictionary:
	var parsed: Variant = _read_and_parse(resource_path)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Expected JSON Dictionary in file: %s" % resource_path)
		return {}
	return _sanitize_dictionary(parsed as Dictionary)

static func load_array(resource_path: String) -> Array:
	var parsed: Variant = _read_and_parse(resource_path)
	if typeof(parsed) != TYPE_ARRAY:
		push_error("Expected JSON Array in file: %s" % resource_path)
		return []
	return _sanitize_array(parsed as Array)

static func _read_and_parse(resource_path: String) -> Variant:
	var clean_path: String = resource_path.strip_edges()
	if clean_path.is_empty() or not clean_path.begins_with("res://"):
		push_error("Invalid resource path requested: %s" % resource_path)
		return null
	if not FileAccess.file_exists(clean_path):
		if ResourceLoader.exists(clean_path):
			var jres: Resource = ResourceLoader.load(clean_path)
			if jres is JSON:
				return (jres as JSON).data
		push_error("Configuration file does not exist: %s" % clean_path)
		return null
	var file: FileAccess = FileAccess.open(clean_path, FileAccess.READ)
	if file == null:
		var err_code: Error = FileAccess.get_open_error()
		push_error("Failed opening %s with error code %d" % [clean_path, err_code])
		return null
	var raw_text: String = file.get_as_text()
	file.close()
	if raw_text.is_empty():
		push_error("Configuration file is empty: %s" % clean_path)
		return null
	var parser: JSON = JSON.new()
	var parse_err: Error = parser.parse(raw_text)
	if parse_err != OK:
		push_error("JSON parse error in %s at line %d: %s" % [clean_path, parser.get_error_line(), parser.get_error_message()])
		return null
	return parser.data

static func _sanitize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_STRING:
			var text: String = (value as String).strip_edges()
			if text.length() > MAX_STRING_LENGTH:
				return text.substr(0, MAX_STRING_LENGTH)
			return text
		TYPE_FLOAT:
			var num: float = value as float
			if is_nan(num) or is_inf(num):
				push_error("Invalid float value encountered in JSON configuration")
				return 0.0
			return num
		TYPE_INT, TYPE_BOOL:
			return value
		TYPE_DICTIONARY:
			return _sanitize_dictionary(value as Dictionary)
		TYPE_ARRAY:
			return _sanitize_array(value as Array)
		_:
			return value

static func _sanitize_dictionary(source: Dictionary) -> Dictionary:
	var cleaned: Dictionary = {}
	for raw_key: Variant in source.keys():
		var key_str: String = str(raw_key).strip_edges()
		if key_str.is_empty():
			continue
		cleaned[key_str] = _sanitize_value(source[raw_key])
	return cleaned

static func _sanitize_array(source: Array) -> Array:
	var cleaned: Array = []
	for item: Variant in source:
		cleaned.append(_sanitize_value(item))
	return cleaned

static func to_vec3(raw_value: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if typeof(raw_value) != TYPE_ARRAY:
		return fallback
	var arr: Array = raw_value as Array
	if arr.size() < 3:
		return fallback
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))

static func to_vec2(raw_value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if typeof(raw_value) != TYPE_ARRAY:
		return fallback
	var arr: Array = raw_value as Array
	if arr.size() < 2:
		return fallback
	return Vector2(float(arr[0]), float(arr[1]))

static func to_color(raw_value: Variant, fallback: Color = Color.WHITE) -> Color:
	if typeof(raw_value) != TYPE_ARRAY:
		return fallback
	var arr: Array = raw_value as Array
	if arr.size() == 3:
		return Color(clampf(float(arr[0]), 0.0, 1.0), clampf(float(arr[1]), 0.0, 1.0), clampf(float(arr[2]), 0.0, 1.0), 1.0)
	if arr.size() >= 4:
		return Color(clampf(float(arr[0]), 0.0, 1.0), clampf(float(arr[1]), 0.0, 1.0), clampf(float(arr[2]), 0.0, 1.0), clampf(float(arr[3]), 0.0, 1.0))
	return fallback
