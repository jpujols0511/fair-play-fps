# Third-party components

Record every external component before integration (AGENTS.md). Nothing here
may hold game rules or authority; the fairness kernel in `godot/kernel/` is
original project code.

| Component | Source | Version | Licence | Vendored at | Used for |
| --- | --- | --- | --- | --- | --- |
| netfox | https://github.com/foxssake/netfox | commit `cf5189d18e98766022c8c1c5e637a6a30c4c3703` (2026-09-26), plugin 1.49.4 | MIT, copyright 2023 Gálffy Tamás (`godot/addons/netfox/LICENSE`) | `godot/addons/netfox/`, `godot/addons/netfox.internals/` | Tick timing today; clock sync, prediction and rollback plumbing next. Never game rules. |
| Godot Engine | https://github.com/godotengine/godot | 4.4.1-stable, official Linux x86_64 build `49a5bc7b6`, zip SHA-256 `d6e382fb531019f85630c1f485a561a0d20c4a2344b6c3847735cfee7da812aa` | MIT | Not vendored; downloaded binary | Engine, headless server, DTLS transport |

Updating a vendored component: replace the folder from a pinned upstream
commit, update this table, rerun every test with `FAIRPLAY_GODOT` set.
