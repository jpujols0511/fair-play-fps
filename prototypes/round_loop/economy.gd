extends RefCounted
## Round economy as pure functions (round loop spec v0.1 Section 2). Server-side only.
## All money is float (house rule). Counts (loss streak) are int indices, never money.

const START_CASH := 800.0
const KILL_REWARD := 300.0
const PLANT_PLANTER := 200.0
const PLANT_TEAM := 300.0
const DEFUSE_DEFUSER := 300.0
const DEFUSE_TEAM_SPLIT := 600.0
const LOSS_LADDER := [1400.0, 1900.0, 2400.0, 2900.0, 3400.0]  # 1st..5th+ consecutive loss
const WIN_BONUS := 3000.0
const ARMOR_VEST := 650.0      # Joan Oct 17 2026 (03:22 UTC): vest only
const ARMOR_HELMET := 1000.0   # Joan Oct 17 2026 (03:22 UTC): vest + helmet (replaces the earlier $455)
const MAX_CASH := 16000.0          # PROPOSED (CS), DECISION FOR JOAN
const TEAMKILL_REWARD := 0.0       # PROPOSED (1.6 fines 3300), DECISION FOR JOAN

enum BuyResult { OK, UNKNOWN_ITEM, WRONG_TEAM, NOT_BUY_TIME, INSUFFICIENT_FUNDS, DEAD }


static func credit(cash: float, amount: float, cap: float = MAX_CASH) -> float:
	return minf(cash + amount, cap)


static func kill_reward(killer_team: String, victim_team: String) -> float:
	if killer_team == victim_team:
		return TEAMKILL_REWARD
	return KILL_REWARD


## consecutive_losses counts this loss (first loss = 1). 5 and beyond = top step.
static func loss_bonus(consecutive_losses: int) -> float:
	var idx := clampi(consecutive_losses - 1, 0, LOSS_LADDER.size() - 1)
	return LOSS_LADDER[idx]


static func win_bonus() -> float:
	return WIN_BONUS


## New loss streak after a round. mode "reset" (1.6: a win clears it) or "decrement" (CS:GO).
static func next_loss_streak(streak: int, won: bool, mode: String = "reset") -> int:
	if not won:
		return streak + 1
	if mode == "decrement":
		return maxi(streak - 1, 0)
	return 0


## Plant: planter gets PLANT_PLANTER; team bonus "each" = PLANT_TEAM to every T (planter too),
## "split" = PLANT_TEAM divided evenly across the T team. Returns {slot: amount}.
static func plant_rewards(planter: int, team_slots: Array, mode: String = "each") -> Dictionary:
	var out := {}
	var share := PLANT_TEAM
	if mode == "split" and team_slots.size() > 0:
		share = PLANT_TEAM / float(team_slots.size())
	for s in team_slots:
		out[s] = share
	out[planter] = out.get(planter, 0.0) + PLANT_PLANTER
	return out


## Defuse: defuser gets DEFUSE_DEFUSER; DEFUSE_TEAM_SPLIT divided evenly across the whole CT team
## (mode "team") or only CTs alive at the defuse (mode "alive"). Returns {slot: amount}.
static func defuse_rewards(defuser: int, team_slots: Array, alive_slots: Array, mode: String = "team") -> Dictionary:
	var out := {}
	var pool: Array = alive_slots if mode == "alive" else team_slots
	if pool.size() > 0:
		var share := DEFUSE_TEAM_SPLIT / float(pool.size())
		for s in pool:
			out[s] = share
	out[defuser] = out.get(defuser, 0.0) + DEFUSE_DEFUSER
	return out


## Server-side buy check. The request carries only an item id; price and team come from the
## server's table. Returns {result: BuyResult, new_cash: float}.
static func validate_buy(cash: float, item: Dictionary, team: String, buy_open: bool, alive: bool = true) -> Dictionary:
	if item.is_empty():
		return {"result": BuyResult.UNKNOWN_ITEM, "new_cash": cash}
	if not alive:
		return {"result": BuyResult.DEAD, "new_cash": cash}
	if not buy_open:
		return {"result": BuyResult.NOT_BUY_TIME, "new_cash": cash}
	if item["team"] != "BOTH" and item["team"] != team:
		return {"result": BuyResult.WRONG_TEAM, "new_cash": cash}
	var price: float = item["price"]
	if cash < price:
		return {"result": BuyResult.INSUFFICIENT_FUNDS, "new_cash": cash}
	return {"result": BuyResult.OK, "new_cash": cash - price}
