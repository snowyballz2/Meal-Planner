# Family Meal Planner — Architecture Summary

Single-file HTML/JS PWA (`index.html`, ~24,000 lines) for two people ("Him"/"Her") with nutrition tracking, shopping lists, package waste elimination, and cloud sync. Installable on mobile via `manifest.json` + `sw.js` service worker.

> **Doc map (read this first):** This file is the evergreen architecture reference. Detailed per-session change history lives in (1) `Archive/CLAUDE_sessions.md` (verbatim logs 2026-04-17 → 2026-05-05) and (2) the `~/.claude/projects/-Users-chris-Developer-Meal-Planner/memory/` topic files (the current distilled detail — `system_freeze_and_overrides.md`, `system_invariants.md`, `system_schedule_edit_mode.md`, `system_data_model.md`, etc., indexed by `MEMORY.md`). When this doc and a memory topic file disagree, the memory file is newer. The compact 2026-05-06 → 2026-05-30 digest is at the bottom of this file.

## ⚠ Invariant & Communication Rules (read first)

**Invariants are contracts, not targets.** There are now **27 invariants** (INV1–27). Any hard-INV violation — the hard set is **INV1–5, INV7–13, INV17, INV19, INV20 (hard count = INV20 − INV20Soft), INV23, INV24, INV25, INV26, INV27** — even one, even "rare," even "can't reproduce" — is a bug and MUST be investigated until root-caused. The following justifications are banned in this repo:

- "stochastic edge"
- "close enough" / "within tolerance"
- "probably bad luck" / "noise"
- "statistically insignificant"
- "rare enough to ignore"
- "can't reproduce with current state"

If an INV fires and you can't reproduce it, that means **you haven't instrumented enough yet** — add logging, bisect seeds, trace the pipeline step-by-step. Do not close the investigation with a dismissive framing. A historical precedent this rule prevents: INV7 drift in this repo was hand-waved as "stochastic" for multiple sessions; the actual cause was `postBalanceWastePass` splitting cross-trip batches, producing different scale factors on the same batch's portions. The invariants were doing their job; the investigators were not.

Tracking-only invariants (**INV6, INV14, INV15, INV16, INV18, INV20Soft, INV20Leftover, INV21, INV22**) are signals, not bugs — they emit informational data but don't count toward "hard fail" totals. **They are NOT noise** — a tracking-INV fire that appears or spikes is worth investigating (precedent: an INV14 fire dismissed as "Test 2 noise" turned out to be a real Stage-2-absorb regression). Everything else is hard. See the table below for current status of each.

**Communication rules** (user-enforced):
- No sugarcoating results. If a fix is "neutral" or "noise," say so — do not spin it as "structurally sound" to keep it in.
- No exceptions or goalpost changes without the user's explicit approval. If you want to widen a tolerance, raise a threshold, downgrade an INV, or accept a regression — **ask first and wait**. Do not unilaterally decide "this is acceptable."
- Show failing examples before proposing fixes. "This got better" without numbers is not a report.
- When an INV fires that you don't understand, say "I don't understand this yet" — do not produce a theory that explains it away.
- **Never dismiss audit findings or defensive guards with "this scenario can't happen."** Banned framings: "no DB entry currently triggers this", "the case is theoretical", "won't happen in practice", "trust internal code", "unreachable code path". The default Claude Code system-prompt rule "don't add error handling for scenarios that can't happen" does NOT apply in this project. Code paths that "can't fire" do fire here (precedent: INV7 drift dismissed as "stochastic" for sessions; root cause was real). If a stress test cannot exercise a code path you're trying to fix, **build a targeted reproducer** before declaring the fix neutral — a test that can't hit the path is not a validator.

## Data Layer

- **NUTRI_DB** — ingredient database. Units: tbsp/cup/oz/each/slice/scoop (no tsp). Per-ingredient flags:
  - `halfSnap` — ½ tbsp increments
  - `wholeOnly` — always whole (eggs, bread, tortilla, rxbar, tuna pouch, celery, fish oil)
  - `wholeWhenSolo` — whole for single-portion cooks only, fractional OK when shared/leftover (e.g. scallion)
  - `minAmt` — per-serving floor. Enforced in `adjustIngredients`, post-balance correction, `boostFV`, `unifyCrossPersonRatios` (scales batch UP to hit floor). Also INV13.
  - `maxAmt` — per-serving ceiling. Enforced in `adjustIngredients`, post-balance correction, `boostFV`, `boostBatchVegForDailyTarget`, `unifyCrossPersonRatios` (scales batch DOWN to fit), and both snap passes. All non-protein/non-carb ingredients have min/max thresholds (oils/fats/spices/aromatics/veg/fruit/lime). Also INV13.
  - `pkg` — packaged items with `{size, unit, drained/cups, type}`. Types: `'can'` (default), `'container'` (tofu, ground meats), `'jar'` (marinara), `'carton'` (broth, egg white), `'pouch'` (tuna pouch). (`'bulk'` was a previous-session proposal that was rejected; all `pkg.type==='bulk'` branches removed 2026-04-26 late-late.)
  - `pkg.longShelfLife` — carton carries between trips; excluded from waste analysis and package nudge (egg white)
  - `produce: {perWhole, label}` — converts cup counts → whole-produce counts for the shopping list (bell pepper, broccoli, cucumber, zucchini, sweet potato, etc.)
- **DISCOURAGED_INGREDIENTS** — `['coconut milk']`. Phase 1 scoring adds a **3000-point** penalty per meal using one (dominates typical calDiff 0–500), so the randomizer picks them rarely (~60% of weeks have 0 coconut). *(R14-L doc fix: this previously said 500 — the code and MEMORY.md always said 3000.)* When coconut IS picked, Phase 3 pairs it with other coconut meals to fill the can.
- **MEALS[]** — recipes using `I(dbKey, amt, role, scalable)`. Single base amount per ingredient (no separate him/her). Calorie system scales per person. Roles: protein, carb, fat, veg, condiment, fruit, liquid, fixed.
- **DEFAULTS** — weekly meal assignments per person per slot.
- **CAL_BASE** — daily calorie targets (`{him:2800, her:1900}`).
- **SLOT_BUDGET** — `{breakfast:0.20, lunch:0.35, dinner:0.35, snack:0.10}` — percentage of (target - shake) for each slot.
- **OVERRIDES** — per person/day/slot ingredient amount overrides.
- **SKIPPED / EAT_OUT / LATE_SNACK** — state for skip, eat-out, late night snack.
- **ADJ_TARGETS** — per person/day checkboxes controlling which slots absorb redistributed calories.
- **SHARED_SCHEDULE** — user-set sharing intent (UI signal only). Runtime sharing/batch state is derived from actual meal assignments via the detector (`loInfo.shared`, `loInfo.sameDayShared`). Code should consult `loInfo.*`, not `SHARED_SCHEDULE`.
- **MANUAL_SET** — tracks which slots have been manually overridden by user actions.

## Key Helpers

- `sk(p,d,s)` — builds person_day_slot key (e.g. `'him_Monday_lunch'`)
- `dk(d,s)` — builds day_slot key (e.g. `'Monday_dinner'`)
- `pk(p,d)` — builds person_day key (e.g. `'him_Monday'`)
- `stampSel(key,mealId)` — sets SEL + timestamps in one call
- `updateSchedule()` — saves shared schedule + re-renders

## Slots

`['shake','breakfast','lunch','snack','dinner','late_snack']`

- **shake** — fixed, not in ADJ_SLOTS, not adjustable. If skipped, its calories redistribute to all checked slots.
- **breakfast/lunch/snack/dinner** — adjustable via budget system.
- **late_snack** — manual entry (name + macros), optional add-on.

## Budget-Based Calorie System

Each slot independently targets a calorie budget:
```
budget = (CAL_BASE[person] - shakeKcal) × SLOT_BUDGET[slot]
```

`computeSlotBudgets(p, d)` handles redistribution when slots are skipped or eat-out.

## Unified Ingredient System

Single base `amt` per ingredient (not separate him/her). The calorie adjustment system (`adjustIngredients`) scales meals per person to hit their slot budget. Both people start from the same recipe.

## Leftover & Batch Detector

`computeLeftovers()` is a **single-pass unified detector** that groups every meal occurrence across both people into batches. Output:

- **Cook anchor** (first occurrence in sort order): `{isLeftover:false, cookDay, servings, totalServings, portions:[{p,d,s}, ...], crossPersonCook, feedsAlso, feedsDay, shared}`
  - `portions` is the authoritative list of batch members. All downstream code iterates this.
  - `totalServings === portions.length` (enforced by INV12)
- **Leftover** (any non-anchor portion): `{isLeftover:true, cookDay, crossPerson, cookedBy, sameDayShared?}`
  - `sameDayShared:true` when the leftover is in the same day/slot as the anchor but different person (old "shared co-anchor"). UI renders this as a normal per-serving card with a Shared pill, NOT a "Lo <day>" pill.
- **Solo slots**: no entry in the leftovers map.

Rules:
- Group batches in day-index + slot-order (breakfast, lunch, snack, dinner), breaking ties with him first.
- Anchor must be lunch or dinner; leftovers must also be lunch or dinner. Breakfast/snack slots are NEVER batch members (`cookSlots` is unconditionally `['lunch','dinner']` — the old parenthetical claiming manual-set breakfast/snack anchors was a doc error, likely conflating the detector with manual leftover-LINK paint groups, which are a separate visual mechanism).
- **Batch window**: cook day + 2 (3-day span max).
- **Batch cap**: 6 portions total.
- Any meals with `noLeftover:true` are skipped.

One cook, no parallel chains: for a shared same-day batch with him + her, there is ONE anchor, not two. Everyone else — same-person leftovers, cross-person leftovers, and the same-day other-person portion — is a member of that one anchor's batch.

## Calorie Adjuster

Clean 2-step uniform scale with a `mealTotalServings` param so the snap
pass knows the true batch size for shared/leftover cooks:

1. **Skip-if-close**: If recipe is within `min(15% of base kcal, 80 kcal)` of budget — the TIGHTER of the two bounds — no adjustment. (R14-L doc fix: previously stated "15% or 80 kcal", implying the looser `max`; the shipped `Math.min` is intentional — for meals under ~533 base kcal the 15% band governs.)
2. **Uniform scale**: All scalable ingredients scale by the same factor (no hard cap — the 1.75× estimate caps were removed 2026-04-18; per-ingredient `db.minAmt`/`maxAmt` thresholds bound the result, enforced by INV13). User-pinned ingredients (`_userSet:true`, `scalable:false`) are NOT scaled — see Surgical User Edits.
3. **Fat-drop + backfill**: When a meal's fat % exceeds the limit, biggest fat contributor is dropped/reduced and calories are refilled with protein/carb items. Egg wholes auto-swap to egg whites when fat % exceeds limit.
4. **Post-snap trim**: Reduce highest-calorie items when over budget after snapping. 50% carb floor. Trim order: fat → carb → protein.
5. **Per-portion snap** (single pass): snap each ingredient's per-portion amount to its grid:
   - `oz`/`slice`/`scoop`/`serving` → whole
   - `cup` → 0.25 grid
   - `tbsp`/`halfSnap` → 0.5 grid
   - `each` eggs → whole; other `each` → 0.25 grid (or whole when `wholeWhenSolo` and single-portion)
   - `wholeOnly` → always whole
6. **(removed)** The old per-meal package nudge was deleted 2026-04-23 (it double-scaled with trip-flex). Pkg/produce **trip totals** are now rounded to container boundaries by `freezeTripTotals` post-pipeline — see Package Waste Elimination.

## Cross-Person Unification

`unifyCrossPersonRatios()` enforces "one pot, one recipe" for multi-person batches.

**Math:**
```
batchKcal      = Σ person_pps × person_servings   (across all portions)
totalAmt[ing]  = Σ portion_amt × person_servings  (per ingredient)
perKcal[ing]   = totalAmt / batchKcal
new_amt_i      = perKcal × person_i_kcal
```

Each portion's new per-serving amount is proportional to their kcal budget. Scoop ratios become identical across all ingredients (checked by INV7 at 1% tolerance).

**Option C denominator (2026-04-29)**: the kcal-prop denominator is `getSlotBudget(p,d,s)` (pipeline-stable), NOT `Σ(db.kcal × ing.amt)` (which shifts with every freeze/snap/boost write). So ratio = `budget_him/budget_her` is constant pre/post freeze — frozen and non-frozen items land at the same ratio, keeping INV7 clean. Fast-path skips a portion within 0.001 (absolute — tightened 2026-04-27 from the original 0.5%-of-target; R14-L doc fix) of target BUT force-writes if any portion is below `minAmt` or above `maxAmt` (sub-tolerance drift from upstream flex/produce passes would otherwise leave it below floor → INV13). Items in `ROUND_PKG_ITEMS ∪ ROUND_PRODUCE_ITEMS` carrying `scalable:false` (freeze pins) are skipped entirely.

**Floor handling (veg/fruit + minAmt items)**:
- Veg/fruit floor = recipe base amount per portion
- `minAmt` items floor = `db.minAmt` per portion
- If any portion's kcal-proportional amount falls below its floor, scale the WHOLE batch up by `scaleFactor = floor / smallest_ideal`. Ratios preserved, floor met, only the batch total grows.

Runs as one of the idempotent adjusters inside the `runBalanceAdjusters` convergence loop (gridSnap self-unifies internally to defend against post-waste desync). `postBalanceWastePass` is disabled; the loop converges on unify + snap + snapToGrid + boostVeg.

## Day-Level Macro Balancer

Runs AFTER per-slot adjustment. Takes a whole-week-day view to close
macro gaps that per-slot adjustment can't, by swapping ingredients
across slots. See `getDayBalancedIngredients(p,d)` and `balanceDayMacros`.

Pipeline:
1. For each adjustable slot, run the per-slot `adjustIngredients` → baseline.
2. Compute daily totals (shake + adjusted slots + eat-outs + late snack).
3. Iteratively apply cal-neutral ingredient swaps (prefer non-pkg items):
   - **Protein short**: +protein one grid step, -carb/fat of equal kcal
   - **Carb% > 55**: -carb one grid step, +protein of equal kcal (threshold 0.1%)
   - **Fat% > 30**: -fat one grid step, +protein of equal kcal (threshold 0.1%)
   - **Veg < 2.75c**: +veg one grid step (no trim — veg is so low-cal the min-grid trim would remove way more kcal than the veg adds). Threshold 0.005c. Cap 3× recipe base (4× for leaf veg). The 3c target dropped to 2.75c (V2, 2026-05-03) — Her budget-driven kcal-prop scaling clusters at 2.75-3.0c.
4. **`bestAdd` slot-budget cap (V211, 2026-05-29)**: when adding kcal to a slot, skip any candidate that would push that slot past **1.25× its slot budget** (every non-shake slot, including dinner — the old dinner exemption was dropped because it let a cook-anchor dinner balloon and propagate to all batch-leftover days). Also skips `wholeOnly` items whose step would over-inflate, and `protein powder`.
5. Cached per (p, d); invalidated via `invalidateLeftoverCache`. Runs as `balanceDayMacros` inside the `runBalanceAdjusters` convergence loop.
6. Fruit is NOT boosted — user preference, and most days hit naturally.

## Variety Filter (Phase 1)

**Variety = recency-only (V216/V217, 2026-05-30).** The old "don't repeat any meal from last week" ban is GONE. `getLastWeekMealIds` was deleted entirely along with its 7 call sites. Meals may repeat week-to-week — subject ONLY to the ≥5-day recency gap (the real INV14/INV11 guard). Don't reintroduce a last-week ban.

`_randomizeWeekCore` Phase 1 builds ONE candidate-exclusion list per person/day:

- **`recentIds`** via `getRecentMealIds(dayIndex, days, lookback)` — household-level (BOTH persons), **symmetric ±window** (looks backward AND forward within the week, and crosses into the previous week's tail via `_prevWeekKey()`). Reads `SEL` directly (not `getMealId`, which falls back to DEFAULTS and would pollute the set). Leftover-flagged entries excluded — eating a leftover isn't a "new cook" and shouldn't block same-meal picks. The symmetric window (V216 fix) closes the old blind spot where Phase 1's persons-outer/days-inner iteration couldn't see a forward same-meal pick on the other person.

Phase 1 candidates filter:
- **Snacks exempt** — small pool, meant to repeat freely.
- `recentIds` match → reject UNLESS `isBatchLeftoverEligible(d, s, mealId)` returns true (a cook ANCHOR — not a leftover — of `mealId` exists in the past 2 days; lunch/dinner, non-`noLeftover` only).

Fallback cascade (preserves variety as long as possible): primary → drop `used` → drop shared-slot → drop variety (last resort). Each level still honors the filter when possible; only drops constraints as needed to find a viable meal.

**Variety filter applied in ALL meal-setting stages**: Phase 1 primary + fallbacks, rerollMissDays, Phase 3 Strategy A, Phase 3 Strategy C, Phase 4 (her-mirror swap), `_trySwapForWaste`, `_absorbFindCandidates`. Lookback=4 days to match INV14's `gap<5`.

**INV14 delta rejection**: swap stages (rerollMissDays, 3-A, 3-C) count `countInv14()` before/after candidate swaps; reject any swap that raises the count. The retry selector scores lexicographic (totalWaste, goalMisses, inv14Count) — bestSEL is restored with the lowest tuple.

## Randomize Pipeline (order matters)

**This section was rewritten 2026-05-30; full pass-by-pass detail in `system_freeze_and_overrides.md`.** The old `applyTripFlexScaling → unify → snapBatchTotals → postBalanceWastePass → unify → snapBatchTotalsToGrid → boostVeg` linear sequence was superseded. Today those adjusters (unify, snapBatchTotals, snapBatchTotalsToGrid) live INSIDE an idempotent convergence loop, **`runBalanceAdjusters` (RBA)**, that runs until downstream state stabilizes (INV18 tracks its cap-hit rate). (`boostBatchVegForDailyTarget` + `postBalanceWastePass` were disabled in RBA and deleted in Audit R12, 2026-05-30.) Package waste is handled by **`freezeTripTotals`** (see Package Waste Elimination), not the old flex/nudge passes.

**Retry loop**: 60 iterations of `_randomizeWeekCore` (Phase 1 picks → Phase 2 waste → Phase 3 A/B/C swaps → Phase 4 shared-schedule). The full post-balance pipeline (RBA + freeze + RBA) runs on **EVERY retry** — V97 committed to unconditional pipeline-per-retry (~50 ms each; a conditional gate meant freeze ran against unstable Phase-1 state → INV7 fires). Winner = lexicographic best by **(inv11, goalMisses, hardWaste, inv14Count, softWaste)** — softWaste is the final tiebreaker and part of the early-exit (V237 M11b, user decision; hard criteria always outrank it). Post-retry, `_autoApplyFatBoosts` runs between `rerollInv14Violations` and the kcal rerolls (writes `_fatBoost` overrides on lean days). (The old `bestCaches` snapshot-skip optimization was disabled by V97 and its dead scaffolding removed in Audit R12, 2026-05-30; the post-retry path always reruns the full pipeline on the winning SEL.)

**Post-retry sequence on the winning SEL** (each step on `randTarget`):
1. `rerollMissDays` — per-miss-day single-slot swaps
2. `rerollInv14Violations` — resolve household same-meal-within-5-days (later cook first, then earlier — V215)
3. `rerollKcalOffBreakfast` → `rerollKcalOffSnacks` — bidirectional kcal-correction swaps on solo breakfast/snack
4. **freeze Pass 1** (`attemptSwap=true`) + RBA — round pkg/produce trip totals to container boundaries; last-resort meal swaps when freeze can't reach a boundary
5. **freeze Pass 2** (`attemptSwap=true`) + RBA — re-establish/orphaned-solo cases from Pass 1's swap-cleanup
6. `snapSoloSlotAmountsToGrid` — final solo-slot grid snap (INV8)
7. `rerollKcalOffBreakfast` → `rerollKcalOffSnacks` (again)
8. **freeze Pass 3** — catch pkg/produce contributors introduced by snack swaps (mostly fast-path)
9. **Stage 2 carry-absorb** — for each `crossTripCarry` item with prior-week `priorCarry`, swap a meal so this week's c1 demand lands clean; if any committed, post-absorb `freezeTripTotals(target,false)` + RBA
10. **`skipKcalOverSnacks`** — last-resort snack removal for days still >175 over target. **Runs LAST** (after absorb's re-freeze): setting SKIPPED redistributes the freed budget, so any later freeze/RBA would undo it. Touches only SKIPPED (transient `_autoSkipSlots`, cleared at next randomize)
11. `verifyInvariants()` — runs **INV1–27**; INV6/14/15/16/18/20Soft/20Leftover/21/22 are tracking-only
12. `renderMeals()` + `autoSaveWeek()`

**Critical: `renderMeals()` does NOT invalidate the balanced cache.** Earlier versions did and wiped all post-pipeline mutations (snap, unify, waste, boost) before the user saw them. Mutation paths (meal swap, override, skip/eat-out, randomize) must explicitly invalidate *before* calling `renderMeals`.

## Card Display

Every consumer reads per-serving from `getBalancedSlotIngredients(p,d,s)`:

- **Solo slot**: shows per-serving with on-grid amounts (INV8 enforces)
- **Batch cook anchor (non-shared, e.g. cross-person only)**: shows "Combined ingredients (serves N)" with batch total summed across `lo.portions`. Him tab (anchor) shows this.
- **Batch cook anchor (shared same-day, `loInfo.shared`)**: Him/Her tabs show **per-serving only**, no combined view. The Shared tab owns the combined view (enforced by INV9). Big Cook pill may still render on Him/Her tabs — user OK'd.
- **Batch leftover (same-day shared)**: renders as normal per-serving card with Shared highlight (no "Lo <day>" pill).
- **Batch leftover (time-shifted, same or cross-person)**: shows per-serving with "Leftovers <day>" pill. Per-serving amounts are fractional by design (kcal-proportional split of the unified batch).

**Dropdown amount labels show full precision** (V3, 2026-05-04 removed the old 1-decimal batch rounding — it hid the actual stored value). `fmtFrac` snaps near-fraction values to ¼/⅓/½/¾/⅛-family glyphs (nearest-match, V220-era fix); otherwise the raw value shows. For batch slots, dropdown ranges scale by `cookServings` and back-convert the pick (`pick / cookServings` = per-portion stored), so the user thinks in batch amounts. INV23 enforces per-row displayed macros sum to the card header; INV25 enforces displayed amounts round-trip to the balanced cache.

## Cross-Tab Card Sync

Expanding/collapsing a meal card in the Him tab mirrors the same slot's state in the Her tab. Shared tab has independent state. Implemented in `toggleCard(k)` by splitting the key and setting `openCards[otherKey] = openCards[k]`.

## Page State Persistence

Session state survives refresh via `sessionStorage['mealPlannerPageState']`: `topTab`, `person`, `day`, `activeWeek`, `scrollY`, `openCards`, `sharedSchedOpen`. Saved on `beforeunload`, restored at init. Scroll position restored after render via `setTimeout`.

## Package Waste Elimination

Achieves ~zero-waste on `Randomize` clicks. The architecture changed substantially across 2026-04-29 → 2026-05-30 — **the canonical reference is `system_freeze_and_overrides.md`**; this is the summary.

### `freezeTripTotals` — the core mechanism (replaced `roundPkgItemsToBoundary` 2026-05-01)
Operates on already-adjusted/unified cache values (not estimates). Scope: `ROUND_PKG_ITEMS` (~7 pkg items) + `ROUND_PRODUCE_ITEMS` (~14 whole-produce items, incl. celery as cup-produce). For each ROUND item × trip (`cook1` Mon-Wed / `cook2` Thu-Sun):
- **Solos** snap to ingredient grid (0.25c / 1oz / etc.).
- **Multi-cook batches** absorb the remainder so the trip total lands on a container multiple (largest-remainder paired-snap; within-batch portions scale uniformly to preserve unify ratios).
- **Trade hierarchy when bounds fail**: cap failing batch → redistribute to other batches → bump solos within `minAmt(Solo)`/`maxAmt(Solo)` → try `Y_other` → **try `Y_round ± perUnit`** (one extra container each way, V210) → leave unfrozen.
- Writes cache amts directly **and** `setOverride('amt', …, 'scalable', false)` (pin persists across rebuild; `applyOverrides` forwards `scalable`). Unify/snap/snapToGrid/boostFV all skip these pinned items.

Runs **3 post-retry passes** (Pass 1/2 `attemptSwap=true`, Pass 3 after snack rerolls) — see Randomize Pipeline. Last-resort `_trySwapForWaste` swaps a solo meal to a non-pkg alternative when freeze can't reach a boundary and INV20 would fire (strict variety filter; co-contributor cleanup walks `lo.portions` across trips, preserving `_userSet` entries — R14-C8).

**Fixed-contributor accounting (R14-C9/C1, 2026-07-07)**: `_freezeOneItem` pools contributors it must COUNT but cannot WRITE into `fixedSum` — user-pinned rows (`_userSet`; a pot with any pinned portion is fixed whole) and, on a single-person randomize, pots the target doesn't eat from. Y candidates are HOUSEHOLD totals; each converts to a writable-pool target (`Y − fixedSum`) before `_tryFreezeY`. Single-person runs use the **participation rule**: a pot is writable iff the target eats a portion of it. `_clearFreezeOverrides` stays unscoped (per-retry freeze transients on the other person's slots must die each retry); `randomizeWeek` captures the non-target person's pre-run pins once (`_captureNonTargetFreezePins`) and re-applies them after every clear (`_restorePreservedPins`, participation re-checked against CURRENT geometry — Phase 1 can join the target into the other person's pot mid-run). Residual: when the target's contributors leave a trip, the untouched person's frozen pots can strand partial packages — real waste, INV20 reports it (measured 2–3× better than V231; unfixable without mutating the untouched person's amounts).

### Stage 2 carry-absorb (V201 wire-up, V208 c1-aware)
For `crossTripCarry` items only (marinara, chicken broth), `_computePriorCarryover(_prevWeekKey())` gives the partial left from last week's cook2. After Pass 3, `_absorbCarryItem` tries meal swaps so THIS week's **c1** demand lands at `priorCarry + N×perUnit` (clean reuse of the open jar). Binary commit-or-revert per item (30-trial cap; `_absorbHardINVsClean` gate); if any committed, re-pin via `freezeTripTotals(target,false)` + RBA. `priorCarry` can only be consumed by c1 — when `c1Demand < priorCarry`, freeze's `effPriorCarry = min(priorCarry, c1Demand)` drops the carry term and just rounds the trip total to nearest container (the unused carry ages out as unavoidable waste). Diag: `window._absorbDiag`.

### Waste-flag taxonomy (`db.pkg` and/or `db.produce`)
| Flag | Effect |
|---|---|
| `softWaste:true` | Fires INV20 (visibility) **and** parallel INV20Soft; hard count subtracts soft. marinara/broth (pkg); banana/avocado/orange/jalapeño/thai chili/thai basil (produce). |
| `acceptableWaste:true` | **Silent** skip (no fire, no warning) — "waste happens, accept it." lettuce, coconut milk, lemon, lime (lemon/lime moved here from softWaste in V204). |
| `nonWaste:true` | **Silent** skip — "NOT waste, reused next week." green beans (frozen, back in freezer). Distinct framing from acceptableWaste (V203). |
| `crossTripCarry:true` | Activates `_computePriorCarryover` + Stage 2 absorb. marinara, chicken broth only. |
| `longShelfLife:true` (pkg) | Excluded from waste analysis + nudge — carton carries indefinitely. egg white. |

`SWAP_OUT_EXCLUDE` is now `{}` (V201) — Stage 2 absorb's clean-only commit replaced it.

### Other
- **Dried/cooked beans**: bean meals use cooked-cup entries with a `dry:{ratio,label}` field; shopping converts cooked-cup → dry-cup. No bean-can waste.
- Waste display in shopping list: `waste = ceil(total/perPkg − ε)*perPkg − total` (the `−ε` avoids a float-ceil buying an extra unit). "⚠️ ½ can unused". **Pkg rows skip only `longShelfLife`** (deliberate, V117 — in-pantry pkg residual is worth seeing even when not INV-tracked, so coconut milk still shows its warning); **produce rows skip `acceptableWaste`/`nonWaste`**. (R14-L doc fix: previously claimed all three flags were skipped for both.)
- **Two INV20 evaluation sites** (per-trip + weekly `_inv20CarryWeekly`) must gate the flags consistently — V219 added the acceptableWaste/nonWaste skip to the weekly site.

## Randomizer

`randomizeWeek(target, seed?)` wraps **60** retries of `_randomizeWeekCore(target)`, then runs the post-retry sequence (see Randomize Pipeline). Optional `seed` swaps in a deterministic PRNG for the call (restored in a `finally`) — used by the stress harness for reproducible runs.

**Retry selection** (lexicographic, lower is better):
1. INV11 count (hard invariant — must be 0)
2. Goal misses (person-days that fail any of the 6 primary daily goals)
3. Total waste (INV20 hard)
4. INV14 count (household same-meal-within-5-days)

**Recency gap** enforced by `getRecentMealIds(dayIndex, days, lookback)` — household-level, symmetric ±window. Formalized as INV11 (≥2-day batch gap) + INV14 (≥5-day same-meal cook gap).

**Result quality** (current, 100-seed runs — Test 1 deterministic + Test 2 nondeterministic):
- Primary goal hit rate: **~99.9%** (worst observed day in the cleanest run: +100 kcal; misses are rare borderline fat%/veg)
- Secondary goal hit rate: ~100%
- Hard invariants (INV1–5, 7–13, 17, 19, 20-hard, 23–27): **0**
- INV14: **0**; zero-waste (non-soft): 100%; meals closed-off: 0.0%
- Per-click time: ~600 ms–1.5 s (see the timing-measurement caveat — restart the preview server before any timing batch; a long-lived process inflates it)

## 3-Week View

- **Last / This Week / Next**: Three week pills. Auto-rollover shifts last←this←next.
- **Last week**: Amber banner "View Only". No randomize button.
- **Next week**: Blue banner "Planning Ahead". Fully editable.
- **Rollover**: Clears all manual overrides for the new week.

## UI Pills & State Cards (V245)

- **Leftovers** (amber) — auto, not clickable. Shows on leftover entries *unless* `sameDayShared:true`.
- **Big Cook** (amber) — auto, not clickable. Shows on cook anchor.
- **Set** (purple) — auto, not clickable. Shows when slot is manually overridden.
- **Shared** (green) — toggle for shared cooking.
- **Skip** (grey) — toggle. Sets MANUAL_SET. Eat Out visible when skipped.
- **Eat Out** (red) — toggle. Sets MANUAL_SET. Overrides skip.

**V245/V248 (2026-07-10) RunBook-style state cards** (user-requested redesign): a card's state paints the WHOLE card — 3px left accent edge + gradient wash. Eat-out (red) and skip (slate) are exclusive single-color cards. Informational states **stack** (V248, user decision — batch outranks shared "but show both"): priority `st-lo`/`st-cook` amber > `st-shared` green (shake excluded — shared-by-default there, not a state) > `st-set` purple. Primary state paints the edge + border; 2 states split the wash left/right (first color left), 3 states split in thirds (inline 90deg gradient built in `buildMealCardHtml` from `ACC_RGB`; max 3 — lo/cook mutually exclusive). Eat-out card hardcodes `st-eo`; Shared tab passes `st-lo`/`st-cook` only (green would be uniform noise there). **Pill visibility is pure CSS** (V249 — user: "hide all the pills until you click on it"): collapsed cards show NO pills, badges, or the Set chip at all — the accent edge + gradient carry the state; expanding (`toggleCard` flips `.open`, no re-render) reveals everything. Rules: `.mc:not(.open):not(.skipped):not(.st-eo) .mc-pill:not(.mc-pill-move){display:none}` + same for `.set-pill` and `.day-badge`. Exceptions: skipped + eat-out cards keep their Skip/Eat Out pair visible (they can't expand — mc-meta inert/absent — and the skip→eat-out flow needs both reachable); move-mode pills carry `mc-pill-move` ("⤓ Here" destinations and "Moving… ✕" must show on collapsed cards or the move feature breaks).

## Macro Display

- Stats bar: kcal (person color) / protein (person color) / carbs (green) / fat (yellow)
- Macro bar: P/C/F colored segments. Her tab uses pink (#F472B6) for protein.
- Meals tab color: blue (Him), pink (Her), green (Shared).

## Shelf/Fridge Tab (V242)

`renderShelf()` — rolling household inventory, **display-first**. V244 adds opt-in subtraction (`PANTRY_SUBTRACT`, ⚙️ settings, synced LWW): the shopping list's Both-view **label** shows net-to-buy (`_pantryNetLabel`, "✓ pantry" when covered, unit-match guard); `hisSum`/`herSum` and INV3 stay gross — subtraction never touches buy-math internals. Four sections: **Open from last week** (`_computePriorCarryover` partials usable by cook1), **Freezer** (`nonWaste` items: used vs back-in-freezer), **Long-shelf staples** (`longShelfLife` usage per trip), **Pantry (manual)** — `PANTRY` entries `{name:{qty,unit,_ts}}`, synced per-entry LWW (customIngredients pattern; deletion is soft qty:0 so removals propagate; forcePushTs floor applies). Pantry items matching a shopping `dbKey` show a green "🏠 have X" hint on the shopping row (display-only).

## Settings: Tab Visibility & Person Toggle (V242)

In the ⚙️ settings panel (V244: was ☁️; gear re-tap closes back to the previous tab; week pills close it too). **Tabs (this device)**: `TAB_PREFS` (lsGet, NOT synced) hides Shopping/Shelf/Recipes buttons; Meals always visible; hiding the active tab falls back to Meals. **People (household)**: `PERSON_ENABLED {him,her}` synced LWW like calBase (M23 tie rule). Disabling a person: gated at `getMealId` (returns null — the single choke point every consumer flows through, killing the DEFAULTS fallback), their ptab + Shared ptab hidden, randomize target coerced solo (`_soloPerson()` at the `randTarget` derivation — Phase-1 mirror/bothPersons flow from it), popup button hidden. SEL/overrides data preserved for re-enable. Both-off is blocked; disable prompts a confirm.

## Shopping

- **Trip keys**: `'cook1'` = Mon-Wed (3 days), `'cook2'` = Thu-Sun (4 days), `'custom'` = user-picked. UI labels show "📋 Mon–Wed" / "📋 Thu–Sun" but internal code/notes refer to these as `cook1`/`cook2`. Renamed from legacy `'sun'`/`'wed'` keys 2026-04-26 (those were named after the SHOPPING DAY, not the trip's day range — confusing because `sun` trip didn't include Sunday).
- **`buildShoppingList(trip, who)` — cook-anchor architecture (changed 2026-04-26 late)**:
  - For `cook1`/`cook2` trips: iterates cook anchors (`lo.isLeftover === false`). For each anchor whose cook day is in the trip, sums per-portion balanced amounts across ALL portions of the batch and attributes the FULL batch total to the cook anchor's person bucket (`hisSum` if Him is the anchor, else `herSum`). Leftover slots (`lo.isLeftover === true`, in any trip) contribute nothing — already shopped via the cook anchor. Solo cooks (no `lo` entry) add their slot's amount directly. This makes trip totals automatically grid-clean: each batch contributes its full snapped total to one trip; cross-trip batches don't split a batch's amount across trips.
  - For `custom` trip: slot-based attribution (each slot the user picked contributes its own balanced amount). This matches user intent — what they pick is what gets shopped.
  - Person attribution (`who`): in `cook1`/`cook2`, a shared cook's full batch goes into the COOK ANCHOR's person bucket. The cook is the one shopping; the other person's portion is implicitly included. For solo cooks, anchor person = eater person, no difference. **Him-only / Her-only views show only batches where that person is the cook anchor** — shared batches don't appear in both views.
  - Pre-2026-04-26 architecture iterated every slot independently and added each slot's amount; that double-counted batch portions across trips for cross-trip batches (Wed cook + Fri leftover put one fractional kcal-prop portion in cook1 and another in cook2, neither on grid). The cook-anchor rewrite fixes this.
- `hisSum`/`herSum` are NEVER modified — reflect exact post-pipeline balanced amounts.
- `shopQtyWithCount()` converts qty → shopping label (packages, whole produce, or dry-cup conversion for cooked grains/beans).
- Waste flagged per pkg item, skipped for `longShelfLife`.
- Egg whites vs whole eggs are separate lines.
- **INV3 mirrors this architecture** in its expected reconstruction (also cook-anchor-based for cook1/cook2). Bidirectional check: forward catches shopping over/under-counting, reverse catches expected ingredients that addShopIngredient silently dropped (`['water']` allowlist for items that legitimately never reach shopping).

## Shared Tab

`renderSharedView(day)` → `renderSharedCard()` for each slot where `him_id === her_id`. The card iterates `lo.portions` and sums the actual balanced per-serving amounts across all portions for the combined total. Per-person per-serving amounts shown inline on each row for reference (1-decimal format).

## Recipes Tab

Three collapsible sections:
- **New Recipe**: Compact form with slot/person chips, bordered ingredient list, steps textarea.
- **New Ingredient**: 2-row compact form (Name/Unit/Role + Kcal/Pro/Fat/Carb).
- **Edit Recipes**: Slot/meal picker with inline preview. Edit mode shows quantity dropdowns.
- **Validation (Audit R13, 2026-06-02)**: New Recipe rejects a lunch/dinner meal with no veg (would otherwise fire INV10, which is static over MEALS). New Ingredient rejects a `cooked`-named entry lacking pkg/dry and a `dry/dried/uncooked`-named entry lacking a cooked/canned sibling (would fire INV19), and has an optional **Max Amt** (so scalable custom ingredients are INV13-bounded).

**Meal categories**: Dropdowns group meals by category. Lunch/dinner dropdowns additionally expose a **Vegetarian** group.

## Temp Ingredient Button

Each meal card shows a `+` button in the ingredient section header. Tapping opens a picker (`addTempIngredient` → `confirmTempIngredient`) to append a one-off ingredient to that person/day/slot without editing the underlying recipe.

## Cloud Sync

GitHub Gist API push/pull. **Payload version 4** (2026-04-26): per-key timestamps give true last-write-wins on weekData (all 3 weeks: sel, lateSnack, sharedSchedule, manualSet, overrides), `ADJ_TARGETS`, `customMeals` (per-meal `_ts` — edits propagate), `customIngredients`, `EAT_OUT_DB`. v3 entries read as `ts=0` so any v4 local entry wins (clean migration). **Force Push** button bumps every timestamp to now + PATCHes directly (overwrite remote). Per-device **Sync Protection** toggle (`LOCK_MANUAL_SLOTS`, not synced) makes local `manualSet` slots immune to incoming overwrites. **Audit R13 (2026-06-02)**: `calBase`/`proTarget` now sync last-write-wins via `calBaseTs`/`proTargetTs` (was a blind pull-wins overwrite); `userEdited` (the Set-pill display flag) now merges on the SEL ts (was sent in the payload but ignored on receive).

## Runtime Invariants

`verifyInvariants()` runs after every `randomizeWeek` and emits **INV1–27**. Any violation warns to console with a specific message. **>0 hard violations = bug** (tracking-only: INV6/14/15/16/18/20Soft/20Leftover/21/22 — signals, not fails, but not noise either). `verifyInvariants()` does NOT invalidate cache — it validates the current post-pipeline state.

**Full detailed rules: see [INVARIANTS.md](INVARIANTS.md)** and `~/.claude/.../memory/system_invariants.md` (current).

| ID | Rule | Tolerance | Status |
|---|---|---|---|
| **INV1** | Same-person leftover amounts match cook-day amounts exactly | 0 | hard |
| **INV2** | `calcTotals(p,d)` day kcal matches sum of kcal across slots from `getBalancedSlotIngredients` — stats bar vs cards consistency | kcal within 2 | hard |
| **INV3** | `buildShoppingList(trip, who)` amounts match balanced cache summed across the trip — shopping list vs cards consistency | exact | hard |
| **INV4** | Solo pkg meal must have all pkg ingredients in `PKG_FLEX_CONFIG` (else flex scaling can't resolve trip waste). Replaced Phase 1.5 inline cleanup. | exact | hard |
| **INV5** | Card macros (via `computeCardMacros`) match `getBalancedSlotIngredients` for that slot — card header vs ingredient list consistency | exact | hard |
| **INV6** | Per-meal protein/carb ratio changes <50% vs base recipe — signals day-balancer isn't distorting the dish too aggressively | ~2/run typical | **tracking-only** |
| **INV7** | Cross-person cook scoop ratio consistent across all ingredients — one pot, one ratio (per-person split proportional to kcal share) | 1% | hard |
| **INV8** | Solo per-serving amounts AND batch totals land on ≤2 decimals OR 1/8 fractions (0.125, 0.375, 0.625, 0.875) OR thirds-grid multiples (⅓/⅔/1⅓… — deliberate, fmtFrac renders third-glyphs; checked at a looser 0.003). pkg items exempt | 0.001 (thirds: 0.003) | hard |
| **INV9** | Him/Her tabs never show "Combined ingredients (serves N)" header for a same-day shared meal — Shared tab owns combined view | exact | hard |
| **INV10** | Every lunch/dinner recipe has >0 cups of veg (static check over MEALS) | static check | hard |
| **INV11** | ≥2-day gap between batches of the same meal within a week (excludes `noLeftover`) | exact | hard |
| **INV12** | `lo.totalServings === lo.portions.length` AND every portion shares the anchor's meal ID — detector consistency | exact | hard |
| **INV13** | Per-serving amount for any ingredient with `db.minAmt`/`db.maxAmt` within bounds (solo AND batch). Solo slots (no leftover-map entry) use `db.minAmtSolo` when defined for pan-oil/aromatic-quality floor | 0.001 | hard |
| **INV14** | Household-level: no two NEW cooks (non-leftover, either person) of the same meal within 5 days (lunch/dinner only). Breakfast/snack exempt — pool too small | exact | **tracking-only** (promote when breakfast normalization grows pool) |
| **INV15** | Tracking-only: count of lunch/dinner leftovers **him** eats per week (regardless of cook). MPStress aggregates as `avgLeftoversEaten.him` | — | **tracking-only** |
| **INV16** | Tracking-only: count of lunch/dinner leftovers **her** eats per week. MPStress aggregates as `avgLeftoversEaten.her` | — | **tracking-only** |
| **INV17** | Balancer↔calcTotals kcal canary: `balanceDayMacros.dailyMacros()` view matches `calcTotals(p,d)` per person-day. Catches `sameDayCookServings` double-count/under-count bugs in post-pipeline re-runs (silent ~500-700 kcal drift) | within 2 kcal | hard |
| **INV18** | `runBalanceAdjusters` convergence-loop cap-hit rate: per-randomize, ≤10% of calls may hit the 6-iter safety cap. Higher rate signals a new oscillation source. Investigate via `window._rbaDiagEnabled = true` + inspect `window._rbaDiag` | ≤10% per run | **tracking-only** |
| **INV19** | Cooked/dry DB consistency: every "cooked" entry has `pkg` (canned) or `dry` (cup-cooked→cup-dry conversion); every cup-unit "dry" has a cooked sibling. Spices/herbs excluded by cup-unit filter | static | hard |
| **INV20** | Pkg/produce **trip waste** threshold (>1% pkg, >50%-of-perWhole produce). **Hard count = INV20 − INV20Soft.** Checked at TWO sites (per-trip + weekly `_inv20CarryWeekly`), both gating `longShelfLife`/`acceptableWaste`/`nonWaste` | >1% / >50% | hard |
| **INV20Soft** | Subset of INV20 fires for `softWaste:true` items (marinara, broth, banana/avocado/lemon/lime/orange/jalapeño). Subtracted from the hard count | — | **tracking-only** |
| **INV20Leftover** | Forward-inventory: this week's cook2 partial of a `crossTripCarry` item that becomes next week's `priorCarry`. Informational sub-category, not a fire | — | **tracking-only** |
| **INV21** | Pkg-only split of INV20 (waste >1%) | >1% | **tracking-only** |
| **INV22** | Produce-only split of INV20 (waste >50% of one whole) | >50% | **tracking-only** |
| **INV23** | Per-row displayed macros (× cookServings for combined view) sum to the card header per-serving × N. Catches compound-rounding divergence between `buildIngrEditRow` and `computeCardMacros` | `ceil(N/2)` per macro | hard |
| **INV24** | State-mutation mutual-exclusion: `SHARED_SCHEDULE='shared'` ∧ `EAT_OUT` contradict; `'eo-{side}'` ∧ `SKIPPED` same side contradict; `'eo-both'` ∧ `SKIPPED` either side contradict. Catches stale state from sync / pre-V31 data | exact | hard |
| **INV25** | Card ingredient amount display coherence: displayed amount text round-trips to within 0.02 of the balanced amount (solo + combined-batch view; skips fractional leftover/shared per-portion). Cooking-surface analog of INV3 | 0.02 | hard |
| **INV26** | Stress-harness guard: hard-fails any stress test / harness call that STARTS on polluted (non-pristine) state. Not a runtime-app invariant — protects against false baselines | exact | hard (harness) |
| **INV27** | NUTRI_DB kcal↔macro consistency: per entry, kcal ≈ 4·pro + 4·carb + 9·fat. Fires when \|diff\| > 25 kcal AND relative > 25% (threshold set empirically from the 149-entry sweep — separates basis-mismatch/typo bugs from label noise). New Ingredient form mirrors it with a confirm(). Found coconut milk's label-serving macros vs per-cup kcal on introduction (V240) | 25 kcal ∧ 25% | hard (static) |

## CSS Architecture

Uses CSS custom properties (`:root` vars) for theming. **V246–V249 (2026-07-10): neutral dark-grey palette** (user request — the old Tailwind-slate surfaces read as "a blue theme"; page bg tuned three times on user feedback, settling between the extremes): `--bg:#161719`, `--bg-card/--bg-surface:#222428`, `--border:#2E3138`, `--gray-light:#26282D`, `--text:#DCDDE0` (V252 off-white — user: "the white text is just too white"), `--text-mid:#B7BABF`, `--text-dim:#969CA3`. Person/state accents (his blue, her pink, shared green, amber, red, purple) unchanged — only surfaces were de-blued. Meta theme-color + manifest colors match `--bg`. The two partner-dialog/toast inline styles reference `var(--bg-card)` (they previously used a non-existent `--card` whose slate fallback always won). Key reusable classes:
- Layout: `macro-bar`, `macro-labels`, `hdr-row`, `sched-grid`, `sched-panel`, `paint-bar`
- Schedule pills: `sched-pill-wrap`, `sched-pill-half`, `sched-zone` (l/c/r)
- Buttons: `sched-btn`, `sched-btn-set`, `rand-btn`
- Cards: `sv-card`, `sv-meal-title`, `set-pill`, `day-badge`; V245 state accents `st-eo/st-skip/st-shared/st-lo/st-cook/st-set` (left edge + gradient wash) + the collapsed-card pill-visibility rule
- Sync: `sync-desc`, `sync-field-label`, `sync-id-box`, `sync-btn-grid`

## Key Helper Functions

- `computeLeftovers()` — unified detector (see Leftover & Batch Detector section)
- `getDayBalancedIngredients(p, d)` — **single source of truth** for all ingredient amounts. Cached map of `{slot: [{dbKey, amt, role, scalable, origAmt}, …]}`.
- `getBalancedSlotIngredients(p, d, s)` — shortcut for one slot. Every consumer reads from here: `calcTotals`, `buildShoppingList`, `computeCardMacros`, `renderSharedCard`, `computeDailyFV`.
- `unifyCrossPersonRatios()` — batch ratio enforcement (floor-aware).
- `snapBatchTotals()` — per-serving grid snap of batch totals, rebuilt via `getDayBalancedIngredients` first.
- `snapBatchTotalsToGrid()` — final floor-aware snap after unify.
- `boostBatchVegForDailyTarget()` — scales frozen batch veg across portions to hit daily 3c floor.
- `postBalanceWastePass()` — batch-aware pkg nudging with all-or-nothing revert.
- `verifyInvariants()` — runs INV1–12, does NOT invalidate cache.
- `computeCardMacros(port, person, day, s, cookServings, showBanner, mealTotalServings)` — adjusted macros + ingredient HTML.
- `computeDailyFV(p, d)` — `{veg, fruit}` cup totals for a person/day.
- `invalidateLeftoverCache()` — invalidates both leftover map and day-balanced cache.
- `lsGet(key, fallback)` / `lsSet(key, val)` — localStorage with JSON parse/stringify
- `lsGetRaw(key)` / `lsSetRaw(key, val)` — localStorage raw string access

## Key Files

- `index.html` — the entire app (single file, ~24,000 lines; includes `window.MPStress` harness)
- `manifest.json` — PWA manifest (standalone, dark theme)
- `sw.js` — service worker (network-first caching, GitHub API passthrough)
- `icon.jpeg` — app icon
- `CLAUDE.md` — this architecture doc (evergreen reference)
- `INVARIANTS.md` — standalone INV quick-reference
- `Archive/CLAUDE_sessions.md` — verbatim session logs 2026-04-17 → 2026-05-05 (archived 2026-05-30 to keep this doc lean)
- `Archive/` — backup copies of previous versions
- `~/.claude/projects/-Users-chris-Developer-Meal-Planner/memory/` — current distilled detail (topic files indexed by `MEMORY.md`)

## Schedule Edit Mode

Edit-mode-only grid on the Schedule tab (4 columns: Day | Bkfst | Lunch | Dinner — snacks pickable via cards). Detail: `system_schedule_edit_mode.md`.
- **V253 (2026-07-11) tap-for-menu redesign (user-picked Option A)**: tapping a CELL opens an explicit action menu — Shared meal / Him eats out / Her eats out / Pick meal… / Link leftovers… / Clear, with a ✓ on active states; tapping a DAY NAME or COLUMN HEADER opens the same menu scoped to the row/column (bulk toggle: all-on → all-off, the setSharedPreset convention; Pick/Link are cell-scope only). Solo mode hides Shared + the disabled person's row. The menu ops (`_schedOpShared`/`_schedOpEO`/`_schedOpClear` via `schedMenuAction`) mirror the old tap handlers' writes exactly (V70 eat-out cascade, V82 un-share cleanup, V85 layered clear looped to full reset, eo-overrides-shared per INV24) and feed the same touched-cell/side trackers — Apply/Undo/Reset and the V64 diff are untouched. **Pick meal… / Link leftovers… arm paint mode directly** (`_armPaintWithMeal`: V75 existing-group pre-load, else pre-queues the tapped cell for enabled persons; the meal submenu lists linked groups first, then protein-grouped meals); the old bottom Category/Meal/Select picker row is GONE (a color legend replaces it), making painting edit-mode-only like all grid editing. **The old tap handlers (schedTapLeft/Right/Center/Day, long-press, setSharedPreset*) remain as the harness surface + state-semantics reference — no longer wired to the UI** (paint mode still wires cell zones to paintTap/paintTapCenter).
- **`SHARED_SCHEDULE` values**: `'shared'`, `'eo-him'`, `'eo-her'`, `'eo-both'` (V71 rename from legacy `'skip-*'`; migration in `initSharedSchedule` + `mergeSyncData`).
- **Mutual exclusion enforced at runtime by INV24** (shared∧eatout, eo∧skip contradictions).
- **Apply path** commits the edit-mode diff to live state in one batch.

## Surgical User Edits + ⚖ Re-balance

Editing an ingredient amount on a card does NOT rerun the pipeline. Detail: `system_user_edit_architecture.md`.
- Edit → `_writeUserPin` mutates the balanced cache directly + writes an override with `_userSet:true` + `scalable:false` + `_priorAmt` (the pre-edit displayed value). Banner shows `_priorAmt → new`. Adjuster/unify/snap/INV13 all **bypass** `_userSet` pins (edits are absolute — no clamps, no min/max).
- **⚖ Re-balance** button → full pipeline rerun with user pins frozen.
- **↺ Reset** → clears user-origin overrides for that row, full rebuild.
- `_clearFreezeOverrides` (at randomize start) clears freeze pins (`scalable:false` WITHOUT `_userSet`) but preserves user pins. Phase 1's per-slot `clearOverrides` skips `MANUAL_SET`/`EAT_OUT` slots, which is why the dedicated freeze-pin clear exists.

## Leftover-Link & Auto-Link Groups

Visualizes cook+leftover batches as colored bands in the Schedule grid.
- **Manual groups** (`weekData[w].leftoverLinks`, persistent): user-painted; all slots get `MANUAL_SET=true`. 8-color palette (`cyan, orange, lime, yellow, fuchsia, violet, grey, darkblue`), strict no-reuse (allocator returns −1 when all 8 taken, V73).
- **Auto-groups** (`_autoLinkGroups`, transient): rebuilt every `renderMeals` from `computeLeftovers()` cook anchors (multi-portion lunch/dinner not already manual-grouped). Never persisted → can't drift. Manual wins on conflict. Selecting one in the picker materializes it into a manual group.
- `_validateManualLinkGroups()` self-heals on every render (drops slots whose meal no longer matches the group).

## Current State (2026-07-11, V258 — `main` @ tip)

- **Quality (100-seed Test 1 + Test 2, V238)**: primary ~**99.6–99.8%** (Test 1 99.64% / Test 2 99.79%; misses are exclusively borderline proPct 40–45% and veg 2.5–3.0c classes — zero kcal-bucket misses; cumulative Waves B+C cost ~−0.22pp vs V236 for honest waste accounting, phantom-INV14 elimination, and fat-drops that actually stick); hard INVs (1–5, 7–13, 17, 19, 20-hard, 23–27) **all 0**; INV14 **0**; zero-waste (non-soft) 100%, soft fires ~17/100 runs (M11b tiebreaker; plan-space shifted by the V238 adjuster fixes); INV6 ~71/100 runs (improved); meals closed-off **0.0%**; per-click ~600 ms–1.5 s on a fresh process.
- **Tracking INVs**: INV6 ~85–100 after V227 (Audit R12 added `noRatioCheck:true` to `korean_juk` + `sweet_potato_egg_hash` + `turkey_sweet_potato_hash` — structurally macro-skewed dishes whose budget-fit trim/boost swings P/C by design; 0 day-misses across all observed fires, so the drift carried no signal). Remaining drift outliers `sticky_miso_salmon_bowl`/`salmon_stir_fry_din`/`miso_tofu` are still tracked. INV20 fires are all-soft (avocado/jalapeño produce, marinara/broth pkg); INV18 cap-rate low.
- **Audit Rounds 11–13 CLOSED**: R11 — all CRITICAL+MEDIUM resolved, LOW A3/A6/E1 → V220 (A7 mirin tight margin left harmless; E2 ~12 condiment `minAmtSolo` deferred — do NOT pick up without a specific flagged issue). R12 (V227–V229) — deleted the already-disabled `postBalanceWastePass`/`boostBatchVegForDailyTarget` from RBA (behavior-neutral) + `noRatioCheck:true` on 3 macro-skewed dishes; detail in `AUDIT_ROUND_12.md`. R13 (V230–V231, 2026-06-02) — recipe-form INV10/INV19 validation + sync LWW for `calBase`/`proTarget`/`userEdited`.
- **Audit Round 14 (2026-07-04/07, V232)**: 46 findings (9 CRITICAL / 23 MEDIUM / 14 LOW), all adversarially confirmed — full detail + verdict traces in `AUDIT_ROUND_14.md`. **All 9 CRITICALs fixed in V232**: sync-pull cache invalidation, Reset stale-snapshot meal-id guard (`_postRandomizeSel`), per-serving-mode edit scaling, duplicate-dbKey combined rows, clearOverrides on kcal-reroll + shared-mirror commits, `_userSet`-preserving freeze-swap cleanup, freeze fixed-contributor accounting (user pins counted-not-written), single-person-randomize freeze scoping (participation rule + pre-run pin capture/restore — see Package Waste Elimination). Verified: Tests 1+2 clean (primary 99.86%/99.57%, hard INVs 0, INV14 0, INV20 all-soft), targeted reproducers per fix, A/B vs V231 on single-person runs (hard fires 11/9/13 → 5/6/1; remainder is the pre-existing structural class — the untouched person's frozen pots stranding partial packages, honestly INV20-reported). **CLOSED 2026-07-10 (V239)** — all 46 findings resolved: 9 CRITICALs (V232), 23 MEDIUMs (V233 partner-dialog + V235–V238 Waves A–C), 14 LOWs (V239 Wave D).
- **V233 (2026-07-08) — partner-waste dialog + Slot Mod closure**: per user decision, a UI-triggered single-person randomize now detects residual pkg/produce waste fixable by adjusting the OTHER person's amounts (`_detectPartnerWasteFixables`, INV20-hard gating, partner-contribution filter) and offers a per-instance modal — "Adjust {other}'s amounts" runs the household amounts-only freeze tail (meals unchanged; `_userSet` pins absolute; structurally-unfittable items get an honest toast, e.g. a single-eater solo below one container) vs "Leave {other}'s alone" (INV20 keeps reporting). Hooks: `runRandomizeFromPopup` + `applyScheduleEdit`; harness runs suppressed (`_suppressPartnerWasteDialog` set by `runSlotMod`/`runSlotModSequential`). **Slot Mod Test re-run post-R14 (chunked single-seed runs — monolithic 5-seed+sequential runs kill the embedded preview process, an environment limit, not app code): 1298/1300 across 5 seeds + 780/780 + 260/260 on reruns.** Both failures were `randomizePersist` — the harness's self-documented nondeterministic op (unseeded randomize from mutated state) stochastically hitting the known single-person residual class; wouldn't reproduce across 4 instrumented reruns of the same seed. `checkInv` now captures the actual violation lines in the failure record so the next flake self-documents.
- **V234 (2026-07-09) — randomizePersist flake ROOT-CAUSED and fixed**: the self-documenting failure record captured it as `INV17 balancer-truth-kcal drift=58`. Causal chain, proven deterministically: V214's `skipKcalOverSnacks` sets SKIPPED as the last pipeline stage WITHOUT cache invalidation (by design) → `calcTotals` (truth) drops the skipped snack → INV17's reconstruction summed every cache slot with no SKIPPED gate → false fire with drift == the skipped snack's kcal (58 = a 58-kcal fruit snack; synthetic V214 simulation reproduced drift == snack kcal exactly, silent post-fix). False positive by construction — no balancer runs between V214 and the next rebuild. Fix: INV17's reconstruction gates SKIPPED/EAT_OUT slots, mirroring calcTotals. Negative control verified (canary still fires on a genuinely incomplete cache day). Gates: Test 1 99.86% / hard 0 / INV17 0; Test 2 99.29% / hard 0.
- **V235 (2026-07-09) — R14 Wave A (5 MEDIUMs)**: M2 sync-lock bypass closed (skipped/eatOut per-key merges now honor `LOCK_MANUAL_SLOTS`). **M2b (V236)**: late snacks protected too — they're `pk(p,d)`-keyed so the slot-scoped `manualSet` lookup can't apply, but a late snack is ALWAYS a manual entry (no pipeline path creates one), so its existence is the manual flag: with the lock on, an existing local entry is immune to incoming edit/delete; empty days still receive new remote snacks; local deletions still push outward (newer ts). M3 Force Push authority via `payload.forcePushTs` — receiver treats it as a per-key ts floor, so receiver-only keys (its skips/SEL/late snacks) also resolve remote-wins and delete; normal pushes never carry the field; legacy clients ignore it. `saveBaseline` hardFail got the V207 `INV20Leftover` exclusion (was poisoning baselines with a false hard fail). INV25 de-tautologized — now verifies the RENDERED dropdown label round-trips (`_parseQtyLabel`, user-approved 0.0601 glyph band) and flags ambiguous duplicate labels; `buildQtyOptions` gained a dedupe guard (pushed off-grid value whose glyph collides with a grid option gets a 2-decimal label). INV23 gate widened to same-person `servings>1` combined views (the most common Big Cook shape was never checked at ×N) and the cross-person branch now verifies the RENDERED per-portion-summed rows against unrounded cache truth; render side: the combined card's header pm is recomputed from the rebuilt rows (was anchor-per-serving × N — on-screen rows didn't sum to the header). Verified: M2/M3 payload reproducers both directions, helper unit checks, Tests 1+2 (99.86%/99.36%, hard 0, INV23/INV25/INV17/INV3 all 0).
- **V237 (2026-07-09) — R14 Wave B (7 MEDIUMs + user-decided selector change)**: M8 `_collectHouseholdCooks` gates SKIPPED/EAT_OUT (phantom INV14 cooks); M9 `isBatchLeftoverEligible` rejects skipped/eat-out phantom anchors; M10 `getRecentMealIds` prev-week tail excludes leftovers (2-day-window heuristic — a prev-Wed cook with Thu/Fri leftovers no longer blocks Monday picks at cook-gap 5) and skipped/eat-out entries; M11 `_measuredTripWasteForPersons` matches INV20-HARD (produce softWaste subtracted, crossTripCarry gated); **M11b (user decision)**: soft waste re-added as the FINAL retry-selection tiebreaker + in the early-exit (`_measuredSoftTripWasteForPersons`) — measured tradeoff on identical seeds: strict-hard was 99.79%/39 soft fires per 100 runs, tiebreaker lands 99.71%/8; M12 auto-skips value-marked `'auto'` (persist/sync-surviving; the memory-only tracker made post-reload auto-skips permanent); M13 `tryResolveCook` swaps only the randomize target's cooks; M14 carry-absorb persons scoped to randTarget. **Net Wave B cost, stated plainly: primary 99.86%→99.71% deterministic (~2 extra borderline miss-days/100 weeks) for honest waste accounting + no phantom INV14 + no stuck auto-skips + no non-target mutations.** Reproducers per fix + Tests 1+2 (hard 0, INV14 0).
- **V238 (2026-07-09) — R14 Wave C (9 MEDIUMs)**: M15 `adjustIngredients` final min/max sweep honors `fatDropped` (was resurrecting zeroed fat items at minAmt AFTER backfill refilled their kcal); M16 full egg→egg-white swaps tag `fatDropped` (the wholeOnly snap floor resurrected the egg while the egg-white addition stuck); M17 `boostFV` never mutates `_userSet` pins (itemsByRole forwards the flag); M18 shared-card feeds-day badges read the batch's own `portions` (phantom badges from unrelated same-day batches + sameDayShared shown as leftover); M19 `_wasteHint` sums anchor-attributed (mirrors shopping/freeze/INV20 — cross-trip batches no longer show phantom hints whose suggestions CREATE waste); M20 `confirmTempIngredient` nextIdx spans all batch portions (second `+` from another portion destroyed the first added ingredient); M21 skip/eat-out pill OFF restores MANUAL_SET+USER_EDITED when user pins exist (grid edit-mode clears keep release semantics deliberately); M22 shopping carry depletion uses HOUSEHOLD demand in every view (Her-only view no longer loses her marinara/broth line); M23 calBase/proTarget tie: remote wins a ts-tie only when local is factory default (pre-R13 customizations survive legacy partners). Reproducers: M17/M20/M21/M23 staged probes; gates Test 1 99.64% / Test 2 99.79%, hard 0, INV14 0, miss buckets exclusively borderline (no kcal bucket).
- **V239 (2026-07-10) — R14 Wave D (14 LOWs) → AUDIT ROUND 14 CLOSED**: Leftovers pill now shows the cook day + his/her attribution ("Leftovers · her Tue" — the dead `leftoverBadge` var deleted); `_writeUserPin` V176/V177 fallbacks index the per-person FILTERED ingredient list (zero-amt recipe rows shift the idx space); weekly INV20 carry site gates `longShelfLife` (defensive symmetry with the per-trip site); stale comments corrected (detector "sharedWith co-anchor" shape, unify ref, skip-if-close min() semantics, `getRecentMealIds` Phase-1 isolation overstatement — the stale-SEL over-block bias is documented as accepted); CLAUDE.md doc fixes (DISCOURAGED 3000 not 500, no breakfast/snack anchors, skip-if-close min(), retry-loop pipeline-per-retry + M11b tuple + fatBoosts step, INV8 thirds grid, pkg-vs-produce waste-warning flags, unify fast-path 0.001 absolute); INVARIANTS.md now documents INV17–26 (was stopping at INV16). Verified: pill DOM check ("Leftovers · her Tue"), Test 1 identical to V238 (99.64%, hard 0, INV14 0) — LOW fixes moved nothing.
- **V240/V241 (2026-07-10) — data-integrity insurance**: INV27 (kcal↔macro consistency, empirical 25kcal∧25% threshold; caught + fixed coconut milk's label-serving-vs-per-cup basis mismatch — fat was under-counted ~28g/cup on coconut meals) + `MPStress.selfTestInvariants()` — negative controls proving every hard invariant CAN fire (one targeted corruption/patch per INV, snapshot-isolated, 18/18 pass; documented skips: tracking-only set, INV9 render-gate, INV26 meta). A checker silently going dead now fails the self-test instead of waiting for the next audit round. Run it after any verifyInvariants change.
- **V242 (2026-07-10) — Shelf/Fridge tab + settings + solo mode**: new 🧺 Shelf top tab (see Shelf/Fridge Tab section) with synced manual pantry + "🏠 have" shopping hints (display-first — buy-math subtraction deliberately deferred pending user decision on INV3 semantics); per-device tab show/hide; household `PERSON_ENABLED` toggle (solo mode — gated at getMealId, randomize coerced, data preserved). Verified: pantry CRUD + per-entry LWW merge + force floor, tab prefs incl. active-tab fallback, full solo battery (her tabs hidden, meals gone, 'shared' randomize coerced him-only with 0 hard fires, shopping her-empty, re-enable restores), Test 1 byte-identical with both enabled (99.64%, hard 0 — gates are passthrough).
- **V243 (2026-07-10) — manual meal move/swap** (pinned proposal 2026-05-06): "⇄" pill arms move mode; eligible destination cards show "⤓ Here". Implemented as SWAP (every slot resolves to a meal via DEFAULTS — one-way moves would surface the default confusingly): SEL + overrides + balanced-cache rows travel VERBATIM (no pipeline), both slots MANUAL_SET+USER_EDITED+ts-bumped, 'shared' cells dissolve like changeMeal. Eligibility: same slot group ({lunch,dinner} interchangeable; breakfast↔breakfast; snack↔snack), no skip/eat-out, person availability both directions. Like all manual actions, invariants judge randomizer output — user rearrangement is the user's call. Harness: `moveMealOp` added to runSlotMod (265/265 incl. 5 move scenarios); verified cache-verbatim + survives-randomize + eligibility blocks.
- **V244 (2026-07-10) — settings gear + pantry subtraction + solo schedule grid**: ☁️→⚙️ icon; gear re-tap closes settings back to the previously open tab (`setTopTab(topTab)` — topTab never mutates while the panel is open); a week-pill tap while in settings closes the panel first (`switchWeek` guard). **Pantry subtraction** (user request): household-synced `PANTRY_SUBTRACT` checkbox (⚙️ Pantry panel; LWW + forcePushTs floor, M23-style tie, default false) — when ON, the shopping list's **Both-view label** nets out pantry stock via `_pantryNetLabel` (fully covered → "✓ pantry"; free-text pantry units only subtract when they match the shopping unit, blank = natural unit). LABEL-LEVEL ONLY: `hisSum`/`herSum` and everything INV3 verifies stay gross; Him/Her-only views stay gross (one physical pantry can't be split across per-person views — M22 lesson); the 🏠 hint reads "−X" when active; Shelf helper text reflects the flag. **Solo schedule grid** (user bug: "Schedule meal still shows her when I had only him enabled"): a disabled person's pill half no longer renders (enabled half flex-fills, no shared mid zone), header preset zones collapse to one full-width zone, `schedTapLeft/Right/Center` + `setSharedPreset(Side)` gated, solo day-tap cycles normal ↔ `eo-{person}` (shared skipped), `dayAllSkip` ignores the disabled person. Verified: gear/week-pill round-trips, netting on/off/covered/him-gross/unit-guard probes, merge LWW both directions, INV fire-set identical flag on/off, solo grid DOM (21 him / 0 her / 0 mid) + guards no-op + screenshot; Test 1 identical to V239 (99.64%, hard 0, INV14 0, INV20 17 all-soft).
- **V245 (2026-07-10) — RunBook-style state cards** (user-requested redesign from a RunBook screenshot): a card's dominant state paints the whole card — 3px left accent `::before` edge + `linear-gradient(135deg, rgba(color,.16) → transparent 72%)` wash over `--bg-card` (precedence eat-out red > skip slate > shared green [shake excluded] > leftover amber > big-cook amber > set purple; `accCls` mirrors the pill conditions exactly). Pills now hidden unless active on collapsed cards via ONE CSS rule (`.mc:not(.open):not(.skipped):not(.st-eo) .mc-pill:not(.on){display:none}`) — expanding reveals the full toggle row (toggleCard flips `.open` in-DOM, no re-render needed); skipped/eat-out cards keep their pill pair (can't expand; skip→eat-out flow); "⤓ Here" is `.on` so move destinations stay visible collapsed. Eat-out card hardcodes `st-eo`; Shared tab passes `st-lo`/`st-cook` only. See UI Pills & State Cards section + `feedback_ui_design_direction.md` memory. Verified: DOM battery (collapsed=active-only, expand/re-collapse, skip/eo pairs reachable, move-dest visible, st-set via changeMeal, Shared-tab st-cook), mobile screenshots all six accents, Test 1 byte-identical to V244 (99.64%, hard 0, INV14 0, INV20 17 all-soft).
- **V246 (2026-07-10) — neutral near-black theme** (user: "hard to see with the blue theme going on"): all Tailwind-slate surfaces swapped for RunBook-matched neutral greys (see CSS Architecture for the exact `:root` values); meta theme-color + manifest updated; the two `var(--card,…)` modal fallbacks (dead var — slate fallback always won) now use `var(--bg-card)`. Semantic accents unchanged. Sweep-verified zero remaining slate hex/rgba literals; screenshots across Meals/Shopping/settings/schedule grid; Test 1 byte-identical (99.64%, hard 0, INV14 0, INV20 17 all-soft).
- **V247 (2026-07-10) — theme lightened** (user: "go a little lighter on the black outside.. contrast is a little rough"): `--bg` #0B0C0E→#131417, `--bg-card/--bg-surface` #16181B→#1A1C20 (elevation step kept gentle); meta theme-color + manifest + the two modal fallback literals follow. Diff is provably 5 color values (no logic) — screenshots verified; no pipeline gate needed.
- **V248 (2026-07-10) — lighter greys + stacked state gradients** (user: "slightly lighter grey" + "big cook/leftover priority over shared.. but show both.. first on the left and second color on the right.. thirds" ): palette raised one notch (see CSS Architecture); accent priority now lo/cook > shared > set with multi-state cards blending colors left→right (2 states) or in thirds (3 states) via inline gradient; primary state keeps the edge/border. Verified: DOM gradient strings for 2-state (cook+shared, lo+shared) and 3-state (cook+shared+set), screenshots, Test 1 identical (99.64%, hard 0).
- **V249 (2026-07-10) — fully clean collapsed cards + bg tuned down**: ALL pills/badges/Set chip hidden until a card is expanded (accent gradients carry the state; skipped/eat-out cards and move-mode pills exempt — see UI Pills section); `--bg` #1A1B1E→#161719 ("outer color is too light" — cards stay #222428, giving stronger card lift). Verified: DOM battery (collapsed zero-pill, expand-reveal, set-chip toggle, skip pair, move src+dest), screenshot, Test 1 identical (99.64%, hard 0).
- **V250 (2026-07-10) — gradients brightened** (user: "make the gradient slightly brighter"): all state-wash alphas up ~40% — single-state edge .16→.22 (skip/set .14→.20), fade stop .05→.08 (.04→.07); 2-state edges .16→.22 middle .05→.08; 3-state edges .16→.22, center band .12→.17. Diff is 8 lines of alpha values (6 CSS rules + 2 inline gradient strings), no logic; screenshot verified.
- **V251 (2026-07-10) — default-card sheen** (user: "the default needs a very slight white gradient.. looks to bland"): `.mc` base background is now `linear-gradient(135deg, rgba(255,255,255,.055), .015 45%, 0 72%)` over `--bg-card` — plain cards get a soft top-left sheen matching the state-wash geometry; state classes and multi-state inline gradients override it entirely (they replace `background`). One CSS line; screenshot verified.
- **V252 (2026-07-10) — off-white text** (user: "the white text is just too white.. make like an off white"): `--text` #F0F1F2→#DCDDE0, `--text-mid` #C4C7CB→#B7BABF (hierarchy step preserved), `--text-dim` unchanged. Two var values; screenshot verified.
- **V253 (2026-07-11) — schedule grid tap-for-menu redesign** (user-picked Option A from 3 mockups; "we can pivot if we need to"): see the Schedule Edit Mode section for the model. Verified: pristine-state DOM battery (all 6 menu actions incl. eo-overrides-shared, bulk day/column toggles + ✓ states, Pick meal…→paint→Assign→SEL+MANUAL_SET, Link leftovers…→group forms, Apply/Undo round-trips, solo-mode row hiding), screenshots (action menu + meal submenu match the approved mockup), Test 1 on fresh process (99.64%, hard 0, INV14 0, INV20 17 all-soft — byte-identical), and a git-diff proof that ZERO harness-exercised functions have modified lines (state machine byte-identical to V243's 265/265 Slot-Mod-passing code; a full slot-mod re-run on this session's degraded long-lived browser process exceeded practical wall-clock and was killed — re-run it on a fresh process when convenient, expected green by the diff-proof). **Testing lesson recorded** (`system_schedule_menu_v253.md`): consecutive seeded randomizes in one page session are NOT comparable — in-memory prior-week residue survives localStorage.clear(); A/B comparisons need wipe + PAGE RELOAD per run (two phantom hard-INV scares during verification were exactly this).
- **V254 (2026-07-11) — Option B look on Option A interaction** (user request): every grid cell now renders a VISIBLE center segment between the halves (`.sched-pill-cen`, ⚭ glyph) — lit green when the cell is shared, dim otherwise; in paint mode it replaces the old invisible `sched-pill-mid` overlay as the tap-both target (visible affordance); normal-mode interaction unchanged (whole cell opens the menu). Paint-bar hint rewritten to state the batch rule the detector applies ("Earliest selected day cooks it; every later selected cell eats that cook's leftovers") — answers the user's "how is it deciding what to get leftovers from". Verified: 21 center chips, 8 lit on seed-777 shared cells, paint center queues both, screenshot. (Stale-build trap hit again mid-verify — cache-busted query param needed after server restart.)
- **V255 (2026-07-11) — grid gradient washes** (user: "the gradient look in schedule meals too"): `_schedGradBg(bg,dir)` converts each cell half's flat state tint into a directional wash — strong (1.5×α) at the cell's OUTER edge fading (0.35×α) toward the center chip; applied post-paint-override so queued highlights match; `transparent` + skip's darkened-tab overlay pass through flat. Harness `_hasGreenSharedAnyCell` still matches (the gradient string contains the rgba green). Verified: 16 gradient halves on seed run, unit checks, screenshot.
- **V256 (2026-07-11) — Set glow + true paint preview color** (both user requests): (1) the USER_EDITED purple is GONE from all border/centerline cascades (V62/V63/V79 outer-purple + V68 inner-group inset all retired) — Set now renders as an inside-out purple glow (`linear-gradient` strongest at the center chip fading outward, α .45→0) LAYERED over the state wash ("the double": state color outside, purple inside; skip/eat-out still suppress it per V56; same trigger conditions as the old border). Borders cascade group → shared → skip → eat-out → default. (2) Painting a NEW link group previews the color it will actually get on Assign — `_allocateLinkColor()` at render (same allocator, same state as paintAccept's commit → preview === assigned); amber only when the palette is saturated. Verified: DOM style asserts (glow present, zero purple borders, preview color === allocator's next, no amber), screenshot incl. the shared+set double; harness has no purple-border assertions.
- **V257 (2026-07-11) — borderless grid** (user: "get rid of all of the borders in schedule meals and just have the strong gradients"; the "green vertical line" they flagged was a lime link-group border-left edge): the ENTIRE cell border machinery is deleted — state borders, centerline colors (V62/V63/V68/V80 arc), group outlines, queue-selection borders, insets. States are gradient washes only: link ANCHOR = soft group wash (.26, was outline-only — "filled = leftover .5, soft = anchor"), shared .32, eat-out .3, queued .45, `_schedGradBg` hi multiplier 1.5→1.6, default cells = faint neutral tile rgba(255,255,255,.05). Verified: 0 border props across 42 halves, green-scan intact, group anchors visible, screenshot.
- **V258 (2026-07-11) — solid cook anchors + stronger set glow** (both user requests): link-group cook ANCHOR = SOLID flat fill of the group color (rgba .7, bypasses `_schedGradBg`; white text for all group members) — "bright = the day you act"; leftovers keep the .5 gradient wash; legend reads "leftover links (solid = cook day)". Set glow raised .45→.62 with a later fade start (35%/65%) so purple clearly reads when layered over a state wash ("the combo"). Verified: 5 solid anchors + combo glow .62 in DOM on seed run, screenshot.
- **Branch tip**: `MP_2026-07-11_V6` == `main` (V258). Convention: every commit gets an `MP_<date>_V<N>` branch AND `main` fast-forwarded to it; push both immediately.

## Session History 2026-05-06 → 2026-05-30 (V15–V220) — digest

Verbatim per-session logs through 2026-05-05 are in `Archive/CLAUDE_sessions.md`; the deep current detail is in the `~/.claude/.../memory/` topic files. This is the connective summary of the 203 commits since.

- **Schedule Edit Mode + surgical-edit maturation (05-06 → 05-08, V25–V86)** — edit-mode grid, per-side tap cycle, every-first-tap-clears (V85), per-side touched tracking, Apply path, INV24 mutual-exclusion, 8-color no-reuse palette, auto-link groups + paint-mode color preservation. Recipe-instruction audit (V99, 24 recipes). See `system_schedule_edit_mode.md`.
- **Slot Mod Test + display invariants (05-08 → 05-09, V99–V130)** — built the Slot Mod Test (surgical-edit + edit-mode + state-mutation audit, 40 ops × 5 geometries; `reference_slot_mod_test.md`). Added **INV24** (mutual-exclusion runtime) and **INV25** (card amount display coherence — INV3 analog). Undo-granularity-matches-action (V130).
- **Recipe/DB data (05-10 → 05-13, V131–V136)** — Thai basil ground turkey + new ingredients; lettuce `minAmt`; frozen corn classified as veg.
- **Display/data audits rounds 7+8 (05-18 → 05-19, V137–V155)** — `snapBatchTotals` minAmt-as-batch-floor fix, marinara minAmt, 6 deferred audit fixes, banner-pred matches view scaling.
- **crossTripCarry / prior-week carryover (05-19 → 05-21, V155–V192)** — `crossTripCarry` flag + `_computePriorCarryover`: a `cook2` partial jar (marinara/chicken broth) becomes next week's `priorCarry`; carry-aware `_freezeOneItem` targets `Y = N×perUnit + priorCarry`; carry banner (sequential-fill attribution), shopping/INV3/INV20 wired. (V186 revert then V192 restore.)
- **Stage 2 absorb + harness hardening (05-22 → 05-25, V193–V209)** — `_absorbCarryItem` helpers (V193 dead code → V200/V201 wire-up): actively consume `priorCarry` by meal-swapping so c1 demand lands clean. **INV26** + bulletproof `_clearAllState` (V194/V195) — hard-fail any stress test starting on polluted state. **Test 2 rewrite (V197)** — nondeterministic, fresh random prior week per click. V199 trimmed crossTripCarry to marinara+broth; V202/V203 `nonWaste` flag (green beans); V204 lemon/lime `acceptableWaste`; V205 absorb two-swap INV14 hole; V207 reporter hardFail filter; V208/V209 **c1-aware** absorb + freeze fallback (`carryUsed = min(priorCarry, c1Demand)`). See `system_freeze_and_overrides.md`.
- **Day-kcal-correction arc (05-26 → 05-29, V210–V214)** — surfaced by Test 2 drill-downs (+263/+312 over-target days, root cause = balancer pumping a cook-anchor dinner that propagates to all batch-leftover days). V210 freeze tries `±1 jar`; **V211** dropped bestAdd's dinner exemption + tightened slot cap 1.5×→1.25× (killed the +263); V212 snack reroll pkg swap-out; V213 `rerollKcalOffBreakfast`; V214 `skipKcalOverSnacks` last-resort skip (transient `_autoSkipSlots`, must run LAST). Net: zero days >150 off-target.
- **Variety, INV14, final cleanups (05-29 → 05-30, V215–V220)** — V215 INV14 resolver tries the EARLIER cook when the later (shared-dinner) cook can't swap; **V216/V217 removed the last-week restriction everywhere** (`getLastWeekMealIds` deleted) → recency-only variety; V218 fixed V214 stranding a co-contributor's freeze pin (seed-45 hard fires); V219 B8 weekly-INV20 acceptableWaste/nonWaste gate; V220 Audit-11 LOW cosmetics. **Audit Round 11 closed.**

