extends SceneTree
## Dev helper (needs a display, e.g. xvfb-run): drives main.tscn with a bot and saves a PNG.
##   xvfb-run -a godot --path . --script res://tests/screenshot.gd -- /tmp/shot.png

func _init() -> void:
	var out := "/tmp/shot.png"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.chase = true
	main.yaw = 0.3
	main.session.server.teleport(1400.0, 0.0, -1300.0, true)   # near the circle remote, for the picture
	for t in 700:
		var i := Bots.input("bhop", t, main.session.client.predicted)
		main.session.tick_once(i[0], i[1], i[2])
	main.session.server.teleport(main.session.server.state.pos_x + 30.0, 0.0, main.session.server.state.pos_z, false, true)
	for t in 25:
		var i2 := Bots.input("bhop", 700 + t, main.session.client.predicted)
		main.session.tick_once(i2[0], i2[1], i2[2])
	for f in 3:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	quit()
