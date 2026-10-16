# Licence summary

Status: **Review for Joan**, October 16, 2026. I am not a lawyer; this is a
plain-language reading of the project's own files, not legal advice. Before
the repository goes public, have someone qualified check the final texts.

## Summary (read this first)

- **Today the project is "all rights reserved."** The only licence file in the
  repository is `LICENSE.txt`, which says nobody may copy, change or share the
  project without Joan's written permission. That is the right setting while
  the repository is private.
- **The plan on paper** (in `docs/OPEN_SOURCE_READINESS.md` and `docs/STATUS.md`)
  is: code under **AGPL-3.0-only**, documents and original art under **CC BY-SA
  4.0**, and the name and logos kept as **reserved trademarks**. None of it is
  applied. No licence text for it exists yet.
- **The handout lists `LICENSE`, `LICENSE-ASSETS.md` and "related docs."**
  Those two files are not in the repository (checked on `main` and every
  branch). What exists: `LICENSE.txt`, `README.md`, `AGENTS.md`,
  `docs/OPEN_SOURCE_READINESS.md`, `docs/DESIGN.md`, `docs/THIRD_PARTY.md`,
  `docs/GODOT_ENGINE_GUIDE.md` and the two scripts that check the licence.
  If Joan's Game Builder wrote the drafts elsewhere, send them and I will
  review them.
- **Joan must make five decisions** (section 6) before the repository can go
  public. The most important: confirm AGPL for code, decide how outside
  contributions are accepted, and decide who may use the game's name.
- **The checking scripts will break** when the licence file changes, and one
  of them would pass an empty licence (section 5). Both are small fixes.

## 1. What each file says

| File | What it says, in plain words |
| --- | --- |
| `LICENSE.txt` | "Proprietary Software Notice." Copyright 2026 Joan Pujols, all rights reserved. Not open source. No one may copy, change, distribute, sell or make new works from the code, art, docs or design without written permission, except as the law allows. Having access to the repository does not give those rights. Other people's names and trademarks stay theirs, and mentioning them implies no connection. |
| `README.md` | The project is private pre-production work owned by Joan. It aims at an open-source release with "explicit code, asset, and trademark boundaries", and stays private until a licence replaces the proprietary notice and an audit passes. Points to `LICENSE.txt`. |
| `AGENTS.md` | The working rules. Keep the repository private until licence terms for code, assets, documents and trademark replace the notice and the public audit passes. No Valve or Counter-Strike code, maps, assets, names or sounds. Record where every asset came from before using it. |
| `docs/OPEN_SOURCE_READINESS.md` | The plan. A 15-file, 4-commit audit found no secrets, binaries or third-party game content. Recommends AGPL-3.0-only for code, CC BY-SA 4.0 for documents and distributable source assets, and reserved trademarks. Lists GPL-3.0-only and Apache-2.0 as alternatives. Defines a six-step gate before going public. |
| `docs/DESIGN.md` (open decisions table) | Joan's thesis says "open source, free, community-owned." It records the licence as still **open** and leaves `LICENSE.txt` unchanged until Joan chooses. |
| `docs/THIRD_PARTY.md` | Netfox (MIT, copyright 2023 Gálffy Tamás) is vendored under `godot/addons/`. Godot 4.4.1 (MIT) is downloaded, not stored. Nothing else third-party. |
| `docs/GODOT_ENGINE_GUIDE.md` | Godot's open licence does not license our code, art, audio or branding. Each part needs its own terms. |
| `docs/STATUS.md` | Says AGPL, CC BY-SA and a reserved trademark are "the selected direction" and that applying them is deferred by Joan. (The other docs call it a recommendation; see section 5.) |
| `scripts/audit_public_release.py`, `scripts/check_repo.py` | Check that no secrets or large files are tracked, that `LICENSE.txt` no longer says "not offered under an open-source license", and that the licence text names Joan Pujols. |

## 2. The three licences in the plan, in plain words

### AGPL-3.0-only (proposed for code)

- Anyone may **use, study, change and share** the code, including selling
  copies.
- If they share a changed version, or **run a changed version as a network
  service that other people use** (a game server), they must offer those
  users the changed source under the same AGPL.
- The "only" means version 3 only, with no later versions chosen
  automatically.
- **Fits the project:** community servers can run the kernel freely, and a
  host who changes the rules of fairness must publish the change. This
  matches `docs/COMMUNITY_SERVERS.md`.
- **Trade-offs:** strongest "give back" rule of the common licences, so some
  companies avoid it. It limits what can be linked with the code: libraries
  must be under AGPL-compatible licences. MIT (Netfox, Godot) is compatible.

### CC BY-SA 4.0 (proposed for documents and original art)

- Anyone may share and adapt the work, including commercially, if they **give
  credit**, **say what they changed** and **license their version the same
  way**.
- Good for text, images and sounds. Creative Commons itself does not advise
  using it for software, which is why code is AGPL.
- **Share-alike** means a studio cannot take the art, close it, and sell it.
  That matches "community-owned" and also means the art cannot be used in any
  closed game.

### Reserved trademarks (the name and logos)

- Copyright licences do not give anyone the right to use the **name**. A
  reserved trademark says: you may use the code, but you may not call your
  game "Fair Play FPS" or use the logo in a way that suggests it is ours.
- **Important for fairness:** the kernel hash in `godot/kernel/KERNEL_SHA256`
  only says "this server runs these exact rules." It cannot stop someone
  legally running a *changed* kernel and publishing their own hash. What stops
  them calling that an official or fair game is the trademark policy. See
  decision D4 below.
- "Temporary project name" (README): trademark terms should wait for the real
  name.

## 3. Third-party parts

| Component | Licence | What it needs from us |
| --- | --- | --- |
| Netfox (vendored) | MIT | Keep the copyright and licence notice (present in `godot/addons/netfox/LICENSE` and `netfox.internals/LICENSE`). Confirm its icons and other non-code files are covered by the same licence. |
| Godot 4.4.1 | MIT | Not stored in the repo. A built game that includes Godot must ship Godot's licence and its bundled third-party notices; Godot's documentation says what to include. Check before the first public build. |
| Python standard library | Python Software Foundation licence | Only used to run scripts; nothing is redistributed. |

No art, audio, fonts or maps are tracked in the repository (checked with
`git ls-files`). The "no Valve or Counter-Strike material" rule is met for
the files that exist today.

## 4. Who owns what, and one open question

- Joan is the named copyright owner. The history has 14 commits by Joan and 9
  by "Claude" (AI-assisted work).
- Who owns the copyright in AI-written text and code, and how that affects a
  licence, differs between countries and is unsettled in many. It does not
  block going public, but it is a reason for a lawyer to look at the final
  setup. **DECISION FOR JOAN:** D5 below.
- Outside contributors will own the copyright in what they write. Without an
  agreement, Joan could not later change the code's licence or dual-license it
  without asking every contributor. `docs/OPEN_SOURCE_READINESS.md` notes that
  contribution terms are needed but does not choose them.

## 5. Problems I found in the drafts and scripts

1. **The licence file name is hard-coded.** `scripts/check_repo.py` requires
   `LICENSE.txt` and checks that it names "Joan Pujols". The audit script reads
   the same file. A standard `LICENSE` file (the form GitHub detects) would
   fail the checks, and the AGPL's standard text does not contain "Joan
   Pujols". Plan for a copyright line in a separate `NOTICE` or file header and
   update both scripts together.
2. **The audit can pass with no licence.** It fails only while the phrase "not
   offered under an open-source license" is present. Deleting that sentence
   passes the gate. It should also require a recognised licence text.
3. **"Selected" versus "recommended."** `docs/STATUS.md` calls AGPL/CC BY-SA
   "the selected direction." `docs/OPEN_SOURCE_READINESS.md` and
   `docs/DESIGN.md` say Joan has not yet chosen. This should say one thing.
4. **Many files must change together** when the licence changes: `LICENSE.txt`,
   `README.md` (three lines), `AGENTS.md`, `docs/DESIGN.md` table,
   `docs/OPEN_SOURCE_READINESS.md`, `docs/STATUS.md` and both scripts.
5. **No policy files yet:** contribution terms, a security-reporting policy,
   a code of conduct and a trademark policy. The readiness doc requires the
   first two "before outside changes."
6. **Splitting by folder is not described.** Documents and source art would be
   CC BY-SA but live beside AGPL code in one repository. The files or folders
   that fall under each licence should be listed in one place.
7. **Mod licence is undefined.** `docs/DESIGN.md` makes maps, modes and weapons
   community-owned "content." Whether a mod must use the same licence is not
   said.

## 6. Decisions still open for Joan

**D1. DECISION FOR JOAN: code licence.**
AGPL-3.0-only (recommended in the plan), GPL-3.0-only (the simpler, less
network-specific copyleft), or Apache-2.0/MIT (anyone may close and sell
modified versions). The thesis words "owned by everyone" and the fairness
goal both point at copyleft; the cost is fewer commercial adopters.

**D2. DECISION FOR JOAN: documents and art licence.**
CC BY-SA 4.0 (proposed), CC BY 4.0 (credit only, art may be used in closed
games), or CC0 (anything goes).

**D3. DECISION FOR JOAN: how outside contributions are accepted.**
(a) Developer Certificate of Origin: each contributor signs off that they have
the right to submit; Joan cannot relicense without them. (b) Contributor
licence agreement: contributors grant Joan extra rights; keeps flexibility but
asks more of contributors and sits badly with "community-owned." (c) Neither
(no outside code yet).

**D4. DECISION FOR JOAN: the name and "official" status.**
Who may use "Fair Play FPS" (or the final name), and for what? Options: only
Joan; any server that runs the unmodified, hash-matching kernel; or a written
certification process. This is the only thing that can separate "the real fair
game" from a modified copy.

**D5. DECISION FOR JOAN: AI-written contributions.**
Keep as-is and record authorship in each commit; or ask a lawyer before
release. Also decide whether to state in the repository which parts were
AI-assisted.

**D6. DECISION FOR JOAN: community content.**
Must maps, modes and weapons shared on community servers use an open licence,
or may creators keep them closed? Closed content cannot weaken the kernel,
but it affects the "community-owned" promise.

**D7. DECISION FOR JOAN: timing.**
Apply the licence while the repository is still private (as the plan
recommends) and make it public later, or switch both at once. The readiness
doc says the licence commit comes first.

## 7. A checklist for the public-release gate

From `docs/OPEN_SOURCE_READINESS.md`, with what is still missing:

- [ ] Licence texts for code, docs/art and trademark (**not written**)
- [ ] Contribution and security policies (**not written**)
- [ ] Fix `check_repo.py` and `audit_public_release.py` for the new file layout
- [ ] Run repository, unit, syntax and audit checks
- [ ] Review every tracked file and historical blob again
- [ ] Add Godot and Netfox notices to the first build
- [ ] Change visibility; verify anonymous read access; keep a private backup

## 8. Notes for anti-cheat design later (not designed here)

- An open-source client and kernel mean cheat makers can read everything. The
  threat model already says "security through client secrecy alone" is an
  anti-goal, so this is consistent, but it must be stated as a design
  premise: **assume attackers have the source.**
- Detection thresholds and policies published under an open licence become
  public. Decide which parts of the detection pipeline (feature lists, flag
  thresholds) are published and which operational settings are not, and say
  so in the licence boundary. `docs/THREAT_MODEL.md` already lists
  "publishing bypass techniques" as an anti-goal.
- Data licences differ from code licences. Demos, the banned database and
  reviewer data are personal data. They are not covered by AGPL or CC BY-SA
  and need their own privacy and retention rules.
