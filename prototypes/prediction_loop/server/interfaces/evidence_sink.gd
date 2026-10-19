class_name EvidenceSink
extends RefCounted
## Seam D5: where the server reports evidence-shaped events. v0 is IN MEMORY ONLY: no file is
## ever written here (handout 0.1 rule 5: the .fpev writer belongs to the Rust layer, later).
## Field names match specs/evidence_logging_spec.md (VIS record Section 2.4, INPUT_REJECT 2.5).
## Devin's analyzers read these lists in tests; the Rust layer will consume the same fields.

const REJECT_CLAIMED_TIME := 1     # Devin's (hit registration)
const REJECT_VIEW_CHANGE := 2      # Devin's
const REJECT_RATE_ABUSE := 3       # CD-r2 command budget: excess / far-future commands dropped (logged, never kicks)
const REJECT_INPUT_RATE := 3       # older name of the same code
const REJECT_MALFORMED := 4        # Phase 6/7: bad packet
const MAX_STORED_REJECTS := 4096   # the list is capped; reject_totals keeps counting

var vis_changes: Array = []        # {tick, viewer_slot, sent_mask, sound_only_mask, keyframe}
var input_rejects: Array = []      # {tick, slot, cmd_seq, reason, detail}
var reject_totals: Dictionary = {} # reason -> count, never capped
var rejects_not_stored := 0


func vis_change(tick: int, viewer_slot: int, sent_mask: int, sound_only_mask: int, keyframe: bool) -> void:
	vis_changes.append({"tick": tick, "viewer_slot": viewer_slot, "sent_mask": sent_mask, "sound_only_mask": sound_only_mask, "keyframe": keyframe})


func input_reject(tick: int, slot: int, cmd_seq: int, reason: int, detail: Dictionary) -> void:
	reject_totals[reason] = reject_totals.get(reason, 0) + 1
	if input_rejects.size() >= MAX_STORED_REJECTS:
		rejects_not_stored += 1
		return
	input_rejects.append({"tick": tick, "slot": slot, "cmd_seq": cmd_seq, "reason": reason, "detail": detail})


func count_rejects(reason: int) -> int:
	return int(reject_totals.get(reason, 0))
