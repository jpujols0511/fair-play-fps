# Community-hosted servers

How anyone can host a fair match. Status: first runner, tested on one Linux
machine with local test clients. Not tested across the internet.

## The rule

Operators own the community surface: maps, modes, weapons, rotation,
schedules. They never own the kernel. `godot/kernel/` is the fairness kernel
and its SHA-256 is published in `godot/kernel/KERNEL_SHA256`. Every match
result records the hash of the kernel the server actually ran, and the runner
refuses to publish a match whose kernel does not match. `scripts/check_repo.py`
fails if the kernel changes without the published hash changing in the same
commit, so a kernel change is always a deliberate, reviewable act.

## Run a match

```sh
python3 scripts/run_dedicated_server.py --godot /path/to/Godot_v4.4.1-stable_linux.x86_64 \
    --players alice,bob --ticks 640 --out matches/my-first-match
```

1. Gives each player a random access token in `<out>/tokens.json` (mode
   0600). Send each player only their own token. Never publish the file.
2. Starts the headless server: ENet with DTLS and Netfox clock sync
   (`--transport dtls` selects the earlier raw DTLS path), 64 Hz,
   server-authoritative, listening on `--bind` (default `127.0.0.1`; use
   `0.0.0.0` to accept other machines, which is not tested yet), with a
   per-player jitter buffer of `--jitter-ticks` (default 3, about 47 ms) so
   honest late or reordered packets are not discarded (decision 0002,
   proposed).
3. Writes `demo.json` (every input the kernel received, in order) and
   `result.json` (digest, kernel hash, evidence counts, buffer counts).
4. After the match, runs detection as a separate process and writes
   `detection.json`. Detection never runs inside the live server.

Add `--demo-clients` to start one honest and one controlled attacker test
client on the same machine as a smoke test.

## What operators send upstream

Flags and demos, not punishments. A flag goes to blind community review; only
a final consensus signed off by a moderator reaches the banned database
(`detection/bans.py`). Context such as population, hour and live moderation
coverage changes only how soon a case is reviewed.

## Open

- Token issuing is local to the runner. A shared account service, token
  expiry and revocation are not built.
- The certificate is self-signed per match. Clients trust it by file. A real
  deployment needs certificate distribution or pinning per server.
- Internet hosting, NAT traversal and server discovery are not built.
