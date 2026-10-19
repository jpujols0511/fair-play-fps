class_name ReviewQueue
extends RefCounted

const ParamsData = preload("res://anticheat/anticheat_params.gd")

const ALLOWED_STATUSES := ["NO_FLAG", "NEEDS_HUMAN_REVIEW"]
const REQUIRED_ACTION := "NONE"


static func validate(report: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	if str(report.get("auto_action", "")) != REQUIRED_ACTION:
		errors.append("auto_action")
	if not report.has("match_id") or not report.has("players") or not report.has("params"):
		errors.append("missing_required_field")
	for player in report.get("players", []):
		if not ALLOWED_STATUSES.has(str(player.get("status", ""))):
			errors.append("player_status")
	if typeof(report.get("evidence_chain_ok", false)) != TYPE_BOOL:
		errors.append("evidence_chain_ok_type")
	return {"ok": errors.is_empty(), "errors": errors}


static func write_report(
		path: String,
		report: Dictionary,
		config_overrides: Dictionary = {}
	) -> Dictionary:
	var config := ParamsData.with_overrides(config_overrides)
	if not bool(config["ENABLE_ANTICHEAT_REVIEW"]):
		return {"ok": false, "errors": ["review_disabled"]}
	var validation := validate(report)
	if not bool(validation["ok"]):
		return validation
	var parent_path := ProjectSettings.globalize_path(path.get_base_dir())
	var directory_result := DirAccess.make_dir_recursive_absolute(parent_path)
	if directory_result != OK:
		return {"ok": false, "errors": ["directory_create_failed"]}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "errors": ["open_failed"]}
	file.store_string(JSON.stringify(report, "\t", true, true) + "\n")
	file.flush()
	file.close()
	return {"ok": true, "errors": [], "path": path}
