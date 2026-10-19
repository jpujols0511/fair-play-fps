class_name FakeEndpoint
extends RefCounted
## Client-side transport over FakeNet, the "tiny interface" NetClient talks to:
##   send(payload)  and  poll() -> Array
## The real UDP transport (Phase 6) has the same two calls. Payloads are Variants here (a
## Dictionary for client input, PackedByteArray for snapshots); Phase 6 turns the input
## packet into bytes as well. The owner of the tick moves due packets into `inbox` (tick
## order step 1) and sets `now_ms` before the client sends (step 3).

var net: FakeNet
var now_ms := 0.0
var inbox: Array = []


func _init(p_net: FakeNet) -> void:
	net = p_net


func send(payload: Variant) -> void:
	net.send(FakeNet.C2S, payload, now_ms)


func poll() -> Array:
	var out := inbox
	inbox = []
	return out
