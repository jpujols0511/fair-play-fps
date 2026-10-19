# Hitbox spec v0.1

*Prepared for Game Builder. Public as of Oct 19 2026 (CD-r9).*

## 1. Philosophy

Boxes over capsules for v1.

- A box-ray test is just axis comparisons. A capsule adds closest-point math.
- At 128 tick, with 26 rewind frames and 11 enemies, that extra cost compounds.
- Boxes are conservative. They don't hug the model, so near-misses get logged instead of being silently wrong.

## 2. The shared table

### Standing

| Part | Radius | Length | Span |
|---|---|---|---|
| Head | 4 | 12 | Centered on the head bone |
| Chest | 8 | 20 | Spine base to sternum |
| Stomach | 7 | 16 | Sternum to pelvis |
| Upper arm | 4 | 28 | Shoulder to elbow |
| Forearm | 3.5 | 26 | Elbow to wrist |
| Thigh | 5.5 | 32 | Hip to knee |
| Shin | 4.5 | 34 | Knee to ankle |

The table is written as capsule dimensions (radius and length). For the v1 box shape, each part's box is derived from these same numbers.

### Crouch

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §crouch

- 15% height scale.
- The top of the head sits at standing chest height.

### Jump

- Head and chest translate up with the pelvis as a rigid offset.
- No scaling.

## 3. Implementation

- One canonical skeleton that both server and client import, from the same constants file.
- Server and client must match, or lag compensation lies.

## 4. Near-miss logging

- Every shot that comes within 1 unit of a box gets recorded with:
  - shooter angles
  - rewind amount
  - hit position
- Tune the radii from that data, not from guesses.

## 5. Anti-cheat tie-in

- If a player aims at enemies the server never sent them, that's a flag.
- Visibility culling starves wallhacks. Hitbox logging catches what slips through.

---

## Notes for review (added by Game Builder, not part of the spec)

- **Boxes vs. the table:** Section 1 picks boxes, but Section 2 gives capsule measurements (radius + length). One reading is that each box is built from those numbers: width and depth = 2 × radius, length along the bone = length. That gives head 8×8×12, chest 16×16×20, and so on. Worth confirming that's the intent.
- **26 rewind frames at 128 tick** is about 203 ms of rewind (26 ÷ 128 s).
- **Crouch:** "15% height scale" together with "head top at standing chest height" should be checked against each other once the skeleton heights are fixed. Is it a 15% reduction, or scaling to 15%? A 15% reduction seems to be the intent.
