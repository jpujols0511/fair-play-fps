extends RefCounted
## Buy-menu item table. Round loop spec v0.1 Section 3 (categories, AK T only, M4 CT only).
## Prices are PROPOSED (CS 1.6 values, spec review note (e)) except armor (Joan, Oct 17 2026: vest $650, vest + helmet $1000).
## team: "T", "CT" or "BOTH". Prices are floats (house rule).

const ITEMS := {
	# Pistols
	"glock": {"category": "pistols", "price": 400.0, "team": "BOTH"},
	"usp": {"category": "pistols", "price": 500.0, "team": "BOTH"},
	"p228": {"category": "pistols", "price": 600.0, "team": "BOTH"},
	"deagle": {"category": "pistols", "price": 650.0, "team": "BOTH"},
	"elites": {"category": "pistols", "price": 800.0, "team": "T"},
	"fiveseven": {"category": "pistols", "price": 750.0, "team": "CT"},
	# Shotguns
	"m3": {"category": "shotguns", "price": 1700.0, "team": "BOTH"},
	"xm1014": {"category": "shotguns", "price": 3000.0, "team": "BOTH"},
	# SMGs
	"mac10": {"category": "smgs", "price": 1400.0, "team": "T"},
	"tmp": {"category": "smgs", "price": 1250.0, "team": "CT"},
	"mp5": {"category": "smgs", "price": 1500.0, "team": "BOTH"},
	"ump45": {"category": "smgs", "price": 1700.0, "team": "BOTH"},
	"p90": {"category": "smgs", "price": 2350.0, "team": "BOTH"},
	# Rifles
	"galil": {"category": "rifles", "price": 2000.0, "team": "T"},
	"famas": {"category": "rifles", "price": 2250.0, "team": "CT"},
	"ak47": {"category": "rifles", "price": 2500.0, "team": "T"},     # T only: Joan, locked
	"m4a1": {"category": "rifles", "price": 3100.0, "team": "CT"},    # CT only: Joan, locked
	"sg552": {"category": "rifles", "price": 3500.0, "team": "T"},
	"aug": {"category": "rifles", "price": 3500.0, "team": "CT"},
	# Snipers
	"scout": {"category": "snipers", "price": 2750.0, "team": "BOTH"},
	"awp": {"category": "snipers", "price": 4750.0, "team": "BOTH"},
	"g3sg1": {"category": "snipers", "price": 5000.0, "team": "T"},
	"sg550": {"category": "snipers", "price": 4200.0, "team": "CT"},
	# Heavies
	"m249": {"category": "heavies", "price": 5750.0, "team": "BOTH"},
	# Grenades
	"hegrenade": {"category": "grenades", "price": 300.0, "team": "BOTH"},
	"flashbang": {"category": "grenades", "price": 200.0, "team": "BOTH"},
	"smoke": {"category": "grenades", "price": 300.0, "team": "BOTH"},
	# Armor (Joan, Oct 17 2026: vest $650, vest + helmet $1000)
	"armor_vest": {"category": "armor", "price": 650.0, "team": "BOTH"},
	"armor_helmet": {"category": "armor", "price": 1000.0, "team": "BOTH"},
	# Defuse kit
	"defuse_kit": {"category": "defuse_kit", "price": 200.0, "team": "CT"},
}

const CATEGORIES := ["pistols", "heavies", "smgs", "rifles", "shotguns", "snipers", "grenades", "armor", "defuse_kit"]


static func get_item(item_id: String) -> Dictionary:
	return ITEMS.get(item_id, {})
