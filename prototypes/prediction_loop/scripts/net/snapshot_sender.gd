class_name SnapshotSender
extends RefCounted
## Server side, one per client: builds the next snapshot, picks full or delta from the
## client's ack, and remembers what it sent (baseline ring, as sent).

var ring := BaselineRing.new()
var next_seq := 1
var ack_snap_seq := -1            # newest snapshot the client says it decoded (-1 = none yet)
var last_teleport_gen := 0
var scratch := Snapshot.new()

var full_sent := 0
var delta_sent := 0
var bytes_total := 0
var bytes_min := 1 << 30
var bytes_max := 0
var snapshots := 0
var acks_rejected := 0


## The client's packets carry ack_snap_seq; keep the newest (serial arithmetic). An ack for a sequence that was never
## sent, or that has left the 32-snapshot sent window, is dropped and counted (a forged ack must not pick the baseline).
func on_ack(seq: int) -> void:
	if seq == -1:
		return                                      # "no ack yet"
	if seq < 0 or ring.get_snap(seq) == null:
		acks_rejected += 1                          # negative (other than -1) or never sent / left the window
		return
	# serial arithmetic only orders seqs less than 32768 apart; if the current ack has left the sent window (the client was
	# silent for a long time) the next valid in-window ack replaces it: full snapshots in between, then recovery
	if ack_snap_seq < 0 or ring.get_snap(ack_snap_seq) == null or Snapshot.seq_newer(seq, ack_snap_seq):
		ack_snap_seq = seq


## STUB until Devin's recoil.gd plugs in (seam D3, spread_for_next_shot): AK first-shot spread
## by move state (stand / crouch 0.0055, run 0.0540, air 0.1200), no punch.
static func stub_hud(state: PlayerState) -> Array:
	var ms := Movement.move_state_for_hud(state)
	var acc := 0.0055
	if ms == 3:
		acc = 0.0540
	elif ms == 2:
		acc = 0.1200
	return [Quant.accuracy_to_q(acc), 0, 0, ms]


## Builds and encodes the snapshot for this client. `own` = the client's authoritative state after
## command ack_cmd_seq. `entities` is applied to the scratch snapshot by the caller beforehand
## (call scratch.clear_entities() / set_entity()); P2 sends none.
func build(tick: int, ack_cmd_seq: int, own_state: PlayerState, hud: Array) -> PackedByteArray:
	var s := scratch
	s.snap_seq = next_seq
	s.server_tick = tick
	s.ack_cmd_seq = ack_cmd_seq
	s.flags = 1 if own_state.teleport_gen != last_teleport_gen else 0
	last_teleport_gen = own_state.teleport_gen
	s.own = own_state.to_packed()
	s.hud_acc = hud[0]
	s.hud_pp = hud[1]
	s.hud_py = hud[2]
	s.hud_ms = hud[3]
	var baseline: Snapshot = null
	if ack_snap_seq >= 0:
		baseline = ring.get_snap(ack_snap_seq)
	var bytes := s.encode(baseline)
	s.kind = Snapshot.KIND_DELTA if baseline != null else Snapshot.KIND_FULL
	s.base_seq = baseline.snap_seq if baseline != null else s.snap_seq
	ring.store(s)
	next_seq = (next_seq + 1) & 0xFFFF
	if baseline != null:
		delta_sent += 1
	else:
		full_sent += 1
	snapshots += 1
	bytes_total += bytes.size()
	bytes_min = mini(bytes_min, bytes.size())
	bytes_max = maxi(bytes_max, bytes.size())
	return bytes
