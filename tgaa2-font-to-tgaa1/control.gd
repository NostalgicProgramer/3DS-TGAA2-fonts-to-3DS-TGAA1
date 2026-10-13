extends Control

const V_TGAA1 = 0x00010C06
const V_TGAA2 = 0x00010F06

@onready var status_label: Label = $StatusLabel
@onready var input_dialog: FileDialog = $InputFileDialog
@onready var output_dialog: FileDialog = $OutputFileDialog
@onready var like_dialog: FileDialog = $LikeFileDialog

var source_path: String = ""
var dest_path: String = ""
var like_path: String = ""

func _ready() -> void:
	$BtnInput.pressed.connect(func(): input_dialog.popup_centered(Vector2(600, 400)))
	$BtnOutput.pressed.connect(func(): output_dialog.popup_centered(Vector2(600, 400)))
	$BtnLike.pressed.connect(func(): like_dialog.popup_centered(Vector2(600, 400)))
	$BtnConvert.pressed.connect(_on_convert_pressed)
	
	input_dialog.file_selected.connect(func(path): source_path = path; status_label.text = "Entrada: " + path.get_file())
	output_dialog.file_selected.connect(func(path): dest_path = path; status_label.text = "Salida: " + path.get_file())
	like_dialog.file_selected.connect(func(path): like_path = path; status_label.text = "Referencia Like: " + path.get_file())

func _on_convert_pressed() -> void:
	if source_path.is_empty() or dest_path.is_empty():
		status_label.text = "Error: Selecciona los archivos de entrada y salida."
		return
	
	var err = convert_font_file(source_path, dest_path, like_path)
	if err == OK:
		status_label.text = "¡Conversión exitosa guardada en: " + dest_path.get_file() + "!"
	else:
		status_label.text = "Error durante la conversión (revisa la consola)."

func read_like_file(like_src: String) -> Dictionary:
	var file = FileAccess.open(like_src, FileAccess.READ)
	if not file:
		print("No se pudo abrir el archivo de referencia --like.")
		return {}
	
	var blob = file.get_buffer(file.get_length())
	file.close()
	
	var peer = StreamPeerBuffer.new()
	peer.data_array = blob
	peer.big_endian = false
	
	var magic_res = peer.get_data(4)
	if magic_res[0] != OK or magic_res[1] != PackedByteArray([0x47, 0x46, 0x44, 0x00]):
		print("El archivo --like no es un GFD válido.")
		return {}
	
	var version = peer.get_32()
	if version != V_TGAA1:
		print("El archivo --like debe ser un descriptor de fuente TGAA1 (0x00010C06).")
		return {}
	
	peer.seek(28)
	var count = peer.get_32()
	
	peer.seek(36)
	var f1 = peer.get_float()
	var f2 = peer.get_float()
	var f3 = peer.get_float()
	
	var first = blob.size() - count * 16
	var heights = {}
	
	for i in range(count):
		peer.seek(first + i * 16 + 8)
		var size_field = peer.get_32()
		var h = (size_field >> 20) & 0xFFF
		if heights.has(h):
			heights[h] += 1
		else:
			heights[h] = 1
	
	var max_h = -1
	var max_count = -1
	for h in heights.keys():
		if heights[h] > max_count:
			max_count = heights[h]
			max_h = h
			
	return {
		"floats": [f1, f2, f3],
		"max_height": max_h
	}

func convert_font_file(src: String, dst: String, like_src: String) -> int:
	var file = FileAccess.open(src, FileAccess.READ)
	if not file:
		print("No se pudo abrir el archivo de entrada.")
		return FAILED
	
	var blob = file.get_buffer(file.get_length())
	file.close()
	
	# Usamos StreamPeerBuffer para parsear bytes al igual que struct en Python
	var peer = StreamPeerBuffer.new()
	peer.data_array = blob
	peer.big_endian = false
	
	# Leer cabecera mágica y versión utilizando PackedByteArray para evitar problemas de escape[cite: 1]
	var magic_res = peer.get_data(4)
	if magic_res[0] != OK:
		print("Error al leer la cabecera mágica.")
		return FAILED
	var magic = magic_res[1]
	var version = peer.get_32()
	
	var expected_magic = PackedByteArray([0x47, 0x46, 0x44, 0x00]) # "GFD\0"
	
	if magic != expected_magic or version != V_TGAA2:
		print("El archivo no es un GFD válido de TGAA2 (versión esperada 0x%08X, se obtuvo 0x%08X)" % [V_TGAA2, version])
		return FAILED
	
	# Leer los 8 enteros de la cabecera[cite: 1]
	peer.seek(8)
	var ints = []
	for i in range(8):
		ints.append(peer.get_32())
	
	var count = ints[5]
	var extra_floats = ints[7]
	
	# Leer floats de la cabecera[cite: 1]
	peer.seek(40)
	var floats = []
	for i in range(4):
		floats.append(peer.get_float())
	
	for i in range(extra_floats):
		floats.append(peer.get_float())
	
	var name_at = 56 + extra_floats * 4
	peer.seek(name_at)
	var name_len = peer.get_32()
	var name_bytes_res = peer.get_data(name_len)
	if name_bytes_res[0] != OK:
		print("Error al leer el nombre de la fuente.")
		return FAILED
	var name_bytes = name_bytes_res[1]
	
	var first = name_at + 4 + name_len + 1
	
	if first + count * 20 != blob.size():
		print("Tamaño de archivo inesperado: %d glifos no coinciden con el final del archivo." % count)
		return FAILED
	
	# Leer registros de glifos[cite: 1]
	peer.seek(first)
	var records = []
	for i in range(count):
		var cp = peer.get_32()
		var pos = peer.get_32()
		var size = peer.get_32()
		var adv_word = peer.get_32()
		var extra = peer.get_32()
		records.append({"cp": cp, "pos": pos, "size": size, "adv_word": adv_word, "extra": extra})
	
	if floats.size() < 5:
		print("Se esperaban al menos 5 floats en la cabecera, se encontraron %d." % floats.size())
		return FAILED
	
	# Manejar la configuración de referencia `--like` si fue seleccionada
	var header_floats = [floats[2], floats[3], floats[4]]
	var max_height = null
	
	if not like_src.is_empty():
		var like_data = read_like_file(like_src)
		if not like_data.is_empty():
			header_floats = like_data["floats"]
			max_height = like_data["max_height"]
			print("Usando configuración vertical de referencia: altura de celda %d" % max_height)
	
	# Construir archivo de salida TGAA1[cite: 1]
	var out_peer = StreamPeerBuffer.new()
	out_peer.big_endian = false
	
	out_peer.put_data(expected_magic) # GFD\0
	out_peer.put_32(V_TGAA1)
	out_peer.put_32(0)
	out_peer.put_32(ints[1])
	out_peer.put_32(ints[2])
	out_peer.put_32(ints[3])
	out_peer.put_32(ints[4])
	out_peer.put_32(records.size())
	out_peer.put_32(1)
	out_peer.put_float(header_floats[0])
	out_peer.put_float(header_floats[1])
	out_peer.put_float(header_floats[2])
	
	out_peer.put_32(name_bytes.size())
	out_peer.put_data(name_bytes)
	out_peer.put_u8(0) # Null terminator
	
	for rec in records:
		var width = rec["size"] & 0xFFF
		var height = (rec["size"] >> 12) & 0xFFF
		
		if max_height != null:
			# Mantiene la parte superior (línea base) y recorta al alto anterior si excede
			height = min(height, max_height)
			
		var advance = rec["adv_word"] & 0xFFF
		
		# Byte con signo para el desplazamiento izquierdo[cite: 1]
		var extra_byte = rec["extra"] & 0xFF
		var signed_left = extra_byte if extra_byte < 128 else extra_byte - 256
		
		if signed_left > 0:
			print("U+%04X desplaza a la derecha (%d); TGAA1 no lo soporta." % [rec["cp"], signed_left])
		
		var left = -signed_left
		var size_field = left | (width << 8) | (height << 20)
		
		out_peer.put_32(rec["cp"])
		out_peer.put_32(rec["pos"])
		out_peer.put_32(size_field)
		out_peer.put_32(advance)
	
	var out_file = FileAccess.open(dst, FileAccess.WRITE)
	if not out_file:
		print("No se pudo crear el archivo de salida en: ", dst)
		return FAILED
		
	out_file.store_buffer(out_peer.data_array)
	out_file.close()
	
	print("Escrito con éxito: %s (%d glifos, %d bytes)" % [dst.get_file(), records.size(), out_peer.data_array.size()])
	return OK
