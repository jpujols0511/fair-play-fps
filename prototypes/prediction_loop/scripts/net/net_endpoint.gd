class_name NetEndpoint
extends RefCounted
## Client-side endpoint over a REAL transport (ENet or raw UDP, optionally behind a TransportShim).
## Same two calls as FakeEndpoint: send(payload) / poll(). The payload NetClient hands over is the
## input dictionary {"cmds": [...], "ack_snap_seq": n}; this turns it into an INPUT datagram.
## poll() returns the snapshot byte arrays found in SNAPSHOT datagrams; WELCOME and BYE are kept aside.

var transport                                  # TransportEnet / TransportUdp / TransportShim (client side)
var tick := 0                                  # set by the owner each client tick
var welcome: Dictionary = {}
var bye_seen := false
var cookie := 0                                # from the server's CHALLENGE; sent back in the next HELLO
var snapshots_in := 0
var _newest_arrival_tick := 0                  # tick the newest snapshot was handed over (for ack_delay_ticks)
var _newest_seq := -1


func _init(p_transport) -> void:
	transport = p_transport


func send_hello() -> void:
	var b := Packet.encode_hello(128, cookie)
	if Packet.may_send(b):
		transport.send(b)


func send(payload: Variant) -> void:
	var cmds: Array = payload["cmds"]
	var ack: int = payload["ack_snap_seq"]
	var delay := 0 if ack < 0 else tick - _newest_arrival_tick
	var b := Packet.encode_input(maxi(ack, 0), delay, cmds)
	if Packet.may_send(b):
		transport.send(b)


func send_bye() -> void:
	transport.send(Packet.encode_bye())


func poll() -> Array:
	var out: Array = []
	for raw in transport.poll():
		var m := Packet.parse(raw)
		if m.is_empty():
			continue
		match m["msg"]:
			Packet.MSG_SNAPSHOT:
				out.append(m["snapshot"])
				snapshots_in += 1
				var h := Snapshot.peek(m["snapshot"])
				if not h.is_empty() and (_newest_seq < 0 or Snapshot.seq_newer(h["snap_seq"], _newest_seq)):
					_newest_seq = h["snap_seq"]
					_newest_arrival_tick = tick
			Packet.MSG_CHALLENGE:
				cookie = m["cookie"]
			Packet.MSG_WELCOME:
				welcome = m
			Packet.MSG_BYE:
				bye_seen = true
	return out
