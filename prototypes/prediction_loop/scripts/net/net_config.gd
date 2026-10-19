class_name NetConfig
extends RefCounted
## Every netcode switch in one place (mega handoff Section 6, C1-C12). Each default is the
## PROPOSAL; the DECISION FOR JOAN ones are marked. They are `static var`s so tests and the
## dedicated server can change them (the real game would load them from a server config).

## C1 DECISION FOR JOAN: interpolation delay in ticks. 4.0 = 31.25 ms (Joan, Oct 17: "4 until I decide 2 or 3"). Alternatives 2.0, 3.0.
static var INTERP_TICKS := 4.0
## C2 DECISION FOR JOAN: ticks of linear extrapolation when the interp buffer runs dry. 0.0 = none, hold the last pose (netcode D8).
static var EXTRAP_MAX_TICKS := 0.0
## C3 DECISION FOR JOAN: own-player precision in snapshots. "f64" (full). "q8" is reserved, not built.
static var OWN_STATE_PRECISION := "f64"
## C4 DECISION FOR JOAN: snapshot every N ticks. 2 = 64 per second (D4); 1 = 128 per second (LAN).
static var SNAPSHOT_EVERY_TICKS := 2
## C5: baseline ring size per client (netcode Section 4: 32). Must divide 65536.
static var BASELINE_RING := 32
## C6-C8 live in movement_proto/movement.gd (DUCK_TIME_S, DUCK_SPEED_FACTOR, AIR_DUCK_LIFTS_FEET).
## C9 (Phase 5, PROPOSED): visibility margin, lateral only, and look-ahead.
static var VIS_LATERAL_MARGIN := 8.0
static var VIS_VERTICAL_MARGIN := 0.0
## C10 (Phase 6): "enet" or "udp".
static var TRANSPORT := "enet"
## C11 (CURRENT_DECISIONS CD-r2): per-client command budget. Every executed command (a real one or a lost one filled in
## by repeating) costs 1.0; the budget refills CMD_REFILL per tick up to CMD_BURST. Excess is DROPPED and logged as RATE_ABUSE.
static var CMD_BURST := 8.0
static var CMD_REFILL := 1.0
## A command more than CMD_WINDOW ahead of the next expected seq is dropped (a forged far-future seq cannot buy ticks).
static var CMD_WINDOW := 64
## Sustained far-ahead arrivals with no progress for this many ticks re-sync the expected seq (a real outage, not an attack).
static var CMD_RESYNC_TICKS := 128
## C12 (Phase 5, PROPOSED): ticks of sent-mask history (5 s at 128).
static var SENT_MASK_HISTORY_TICKS := 640
