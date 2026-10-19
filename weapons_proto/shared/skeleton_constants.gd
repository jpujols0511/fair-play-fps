# GENERATED from specs/skeleton_constants.json by tools/gen_skeleton_constants.py. Do not edit.
class_name SkeletonConstants
extends RefCounted

const SKELETON_SHA256 := "56db86a8d12c400f5149f7cfcbf17ec79dd662c93cc6a3d5f18d4d0c288f7aa0"
const VERSION := "0.2"
const STAND_HEIGHT := 72.0
const EYE_STAND := 64.0
const CROUCH_SCALE := 0.5
const MAX_REWIND_TICKS_128 := 25
const NEAR_MISS_UNITS := 1.0
const BOXES := [
	{ "id": 0, "part": "head", "size": [8.0, 8.0, 12.0], "center_stand": [0.0, 0.0, 66.0], "anchor": "head", "fixed_size_in_crouch": true },
	{ "id": 1, "part": "chest", "size": [16.0, 16.0, 11.0], "center_stand": [0.0, 0.0, 54.5], "anchor": "sternum_top", "fixed_size_in_crouch": false },
	{ "id": 2, "part": "stomach", "size": [14.0, 14.0, 9.0], "center_stand": [0.0, 0.0, 44.5], "anchor": "pelvis", "fixed_size_in_crouch": false },
	{ "id": 3, "part": "upper_arm_l", "size": [8.0, 8.0, 16.0], "center_stand": [0.0, 12.0, 50.0], "anchor": "shoulder_l", "fixed_size_in_crouch": false },
	{ "id": 4, "part": "upper_arm_r", "size": [8.0, 8.0, 16.0], "center_stand": [0.0, -12.0, 50.0], "anchor": "shoulder_r", "fixed_size_in_crouch": false },
	{ "id": 5, "part": "forearm_l", "size": [7.0, 7.0, 15.0], "center_stand": [0.0, 12.0, 34.5], "anchor": "elbow_l", "fixed_size_in_crouch": false },
	{ "id": 6, "part": "forearm_r", "size": [7.0, 7.0, 15.0], "center_stand": [0.0, -12.0, 34.5], "anchor": "elbow_r", "fixed_size_in_crouch": false },
	{ "id": 7, "part": "thigh_l", "size": [11.0, 11.0, 19.0], "center_stand": [0.0, 4.0, 30.5], "anchor": "hip_l", "fixed_size_in_crouch": false },
	{ "id": 8, "part": "thigh_r", "size": [11.0, 11.0, 19.0], "center_stand": [0.0, -4.0, 30.5], "anchor": "hip_r", "fixed_size_in_crouch": false },
	{ "id": 9, "part": "shin_l", "size": [9.0, 9.0, 19.0], "center_stand": [0.0, 4.0, 11.5], "anchor": "knee_l", "fixed_size_in_crouch": false },
	{ "id": 10, "part": "shin_r", "size": [9.0, 9.0, 19.0], "center_stand": [0.0, -4.0, 11.5], "anchor": "knee_r", "fixed_size_in_crouch": false },
]
