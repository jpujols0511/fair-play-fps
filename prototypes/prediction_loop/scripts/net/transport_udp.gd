class_name TransportUdp
extends RefCounted
## Raw UDP transport (C10 alternative): PacketPeerUDP. Same two calls as the ENet one.
## Server side identifies a client by its (ip, port) and keeps a peer_id for it.

var sock := PacketPeerUDP.new()
var is_server := false
var client_connected := false
## Peer table hygiene: an address becomes an entry on its first datagram, but only a peer that passed the HELLO cookie
## check is `verify()`ed. Unverified entries are capped (MAX_UNVERIFIED) and pruned after UNVERIFIED_MS; verified ones
## are removed by `forget()` when the server drops the client.
const MAX_UNVERIFIED := 64
const UNVERIFIED_MS := 5000
var refused_peers := 0
var _verified: Dictionary = {}               # peer_id -> true
var _first_ms: Dictionary = {}               # peer_id -> ms of the first datagram
var _peers: Dictionary = {}                  # "ip:port" -> peer_id
var _addr: Dictionary = {}                   # peer_id -> [ip, port]
var _next_id := 1
var events: Array = []
var sent_bytes := 0
var recv_bytes := 0


func connect_to(address: String, port: int) -> int:
	is_server = false
	var e := sock.connect_to_host(address, port)
	client_connected = e == OK
	return e


## bind_addr defaults to loopback; "*" (all interfaces) only on request (--bind-all).
func listen(port: int, bind_addr: String = "127.0.0.1") -> int:
	is_server = true
	return sock.bind(port, bind_addr)


func peer_key(peer_id: int) -> String:
	var a: Array = _addr.get(peer_id, [])
	return "" if a.is_empty() else "%s:%d" % [a[0], a[1]]


func verify(peer_id: int) -> void:
	_verified[peer_id] = true


func forget(peer_id: int) -> void:
	var a: Array = _addr.get(peer_id, [])
	if not a.is_empty():
		_peers.erase("%s:%d" % [a[0], a[1]])
	_addr.erase(peer_id)
	_verified.erase(peer_id)
	_first_ms.erase(peer_id)


## Removes unverified peers older than UNVERIFIED_MS. Call about once a second.
func prune() -> int:
	var now := Time.get_ticks_msec()
	var gone: Array = []
	for id in _addr:
		if not _verified.has(id) and now - int(_first_ms.get(id, now)) > UNVERIFIED_MS:
			gone.append(id)
	for id in gone:
		forget(id)
	return gone.size()


func unverified_count() -> int:
	return _addr.size() - _verified.size()


func is_up() -> bool:
	return sock.is_bound() or client_connected


func send(bytes: PackedByteArray) -> void:
	sock.put_packet(bytes)
	sent_bytes += bytes.size()


func send_to(peer_id: int, bytes: PackedByteArray) -> void:
	var a: Array = _addr.get(peer_id, [])
	if a.is_empty():
		return
	sock.set_dest_address(a[0], a[1])
	sock.put_packet(bytes)
	sent_bytes += bytes.size()


func poll() -> Array:
	var out: Array = []
	while sock.get_available_packet_count() > 0:
		var b := sock.get_packet()
		recv_bytes += b.size()
		if is_server:
			var key := "%s:%d" % [sock.get_packet_ip(), sock.get_packet_port()]
			if not _peers.has(key):
				if unverified_count() >= MAX_UNVERIFIED:
					refused_peers += 1
					continue
				var id := _next_id
				_next_id += 1
				_peers[key] = id
				_addr[id] = [sock.get_packet_ip(), sock.get_packet_port()]
				_first_ms[id] = Time.get_ticks_msec()
				events.append(["connect", id])
			out.append([_peers[key], b])
		else:
			out.append(b)
	return out


func close() -> void:
	sock.close()
	client_connected = false
	_peers.clear()
	_addr.clear()
	_verified.clear()
	_first_ms.clear()
