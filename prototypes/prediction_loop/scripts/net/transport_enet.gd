class_name TransportEnet
extends RefCounted
## ENet transport (C10 default, netcode D13): one ENetConnection host, ONE channel, every packet sent
## UNSEQUENCED and unreliable. Our own seq / ack logic does the rest. Raw bytes in, raw bytes out.
## Client side: connect_to(), send(bytes), poll() -> Array[PackedByteArray], close().
## Server side: listen(port), poll() -> Array of [peer_id, bytes], send(peer_id, bytes), events, close().

const CHANNEL := 0

var host: ENetConnection = null
var peer: ENetPacketPeer = null              # client side: the server
var peers: Dictionary = {}                   # server side: peer_id -> ENetPacketPeer
var _next_id := 1
var connected := false
var events: Array = []                       # server side: ["connect"/"disconnect", peer_id]
var sent_bytes := 0
var recv_bytes := 0


func connect_to(address: String, port: int) -> int:
	host = ENetConnection.new()
	var e := host.create_host(1, 1, 0, 0)
	if e != OK:
		return e
	peer = host.connect_to_host(address, port, 1)
	return OK if peer != null else ERR_CANT_CONNECT


## bind_addr defaults to loopback; "*" (all interfaces) only on request (--bind-all). ENet has its own connect handshake;
## the HELLO cookie on top is checked the same way for both transports.
func listen(port: int, bind_addr: String = "127.0.0.1", max_peers: int = 32) -> int:
	host = ENetConnection.new()
	return host.create_host_bound(bind_addr, port, max_peers, 1, 0, 0)


func peer_key(peer_id: int) -> String:
	var p: ENetPacketPeer = peers.get(peer_id)
	return "" if p == null else "%s:%d" % [p.get_remote_address(), p.get_remote_port()]


func verify(_peer_id: int) -> void:
	pass


func forget(peer_id: int) -> void:
	var p: ENetPacketPeer = peers.get(peer_id)
	if p != null and p.get_state() == ENetPacketPeer.STATE_CONNECTED:
		p.peer_disconnect_later(0)


func prune() -> int:
	return 0


func is_up() -> bool:
	return host != null


## Client side. Sends one datagram (unsequenced, unreliable). The caller has checked Packet.may_send.
func send(bytes: PackedByteArray) -> void:
	if peer != null and peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
		peer.send(CHANNEL, bytes, ENetPacketPeer.FLAG_UNSEQUENCED)
		host.flush()
		sent_bytes += bytes.size()


## Server side.
func send_to(peer_id: int, bytes: PackedByteArray) -> void:
	var p: ENetPacketPeer = peers.get(peer_id)
	if p != null and p.get_state() == ENetPacketPeer.STATE_CONNECTED:
		p.send(CHANNEL, bytes, ENetPacketPeer.FLAG_UNSEQUENCED)
		host.flush()
		sent_bytes += bytes.size()


## Client: array of PackedByteArray. Server: array of [peer_id, PackedByteArray] (events are appended to `events`).
func poll() -> Array:
	var out: Array = []
	if host == null:
		return out
	while true:
		var ev: Array = host.service(0)
		var kind: int = ev[0]
		if kind == ENetConnection.EVENT_NONE:
			break
		var p: ENetPacketPeer = ev[1]
		if kind == ENetConnection.EVENT_CONNECT:
			if peer != null:
				connected = true
			else:
				var id := _next_id
				_next_id += 1
				p.set_meta("id", id)
				peers[id] = p
				events.append(["connect", id])
		elif kind == ENetConnection.EVENT_DISCONNECT:
			if peer != null:
				connected = false
			else:
				var id2: int = p.get_meta("id", -1)
				peers.erase(id2)
				events.append(["disconnect", id2])
		elif kind == ENetConnection.EVENT_RECEIVE:
			var bytes: PackedByteArray = p.get_packet()
			recv_bytes += bytes.size()
			if peer != null:
				out.append(bytes)
			else:
				out.append([p.get_meta("id", -1), bytes])
		elif kind == ENetConnection.EVENT_ERROR:
			break
	return out


func close() -> void:
	if peer != null and peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
		peer.peer_disconnect_now(0)
	for id in peers:
		var p: ENetPacketPeer = peers[id]
		if p.get_state() == ENetPacketPeer.STATE_CONNECTED:
			p.peer_disconnect_now(0)
	if host != null:
		host.flush()
		host.destroy()
	host = null
	peer = null
	peers.clear()
	connected = false
