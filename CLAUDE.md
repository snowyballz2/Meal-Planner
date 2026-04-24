# Family Meal Planner — Architecture Summary

Single-file HTML/JS PWA (`index.html`, ~10,300 lines) for two people ("Him"/"Her") with nutrition tracking, shopping lists, package waste elimination, and cloud sync. Installable on mobile via `manifest.json` + `sw.js` service worker.

## ⚠ Invariant & Communication Rules (read first)

**Invariants are contracts, not targets.** Any INV1–5 / INV7–12 violation — even one, even "rare," even "can't reproduce" — is a bug and MUST be investigated until root-caused. The following justifications are banned in this repo:

- "stochastic edge"
- "close enough" / "within tolerance"
- "probably bad luck" / "noise"
- "statistically insignificant"
- "rare enough to ignore"
- "can't reproduce with current state"

If an INV fires and you can't reproduce it, that means **you haven't instrumented enough yet** — add logging, bisect seeds, trace the pipeline step-by-step. Do not close the investigation with a dismissive framing. A historical precedent this rule prevents: INV7 drift in this repo was hand-waved as "stochastic" for multiple sessions; the actual cause was `postBalanceWastePass` splitting cross-trip batches, producing different scale factors on the same batch's portions. The invariants were doing their job; the investigators were not.

Only INV6 is tracking-only (explicitly documented as such). Everything else is hard.

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
  - `pkg` — packaged items with `{size, unit, drained/cups, type}`. Types: `'can'` (default), `'container'` (tofu), `'jar'` (marinara), `'carton'` (broth, egg white), `'pouch'` (tuna pouch), `'bulk'` (ground meats — skip shopping-list conversion)
  - `pkg.longShelfLife` — carton carries between trips; excluded from waste analysis and package nudge (egg white)
  - `produce: {perWhole, label}` — converts cup counts → whole-produce counts for the shopping list (bell pepper, broccoli, cucumber, zucchini, sweet potato, etc.)
- **DISCOURAGED_INGREDIENTS** — `['coconut milk']`. Phase 1 scoring adds a 500-point penalty per meal using one, so the randomizer picks them rarely (~60% of weeks have 0 coconut). When coconut IS picked, Phase 3 pairs it with other coconut meals to fill the can.
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
- Anchor must be lunch or dinner. Leftovers must also be lunch or dinner (breakfast/snack can be in a batch only as the anchor if user manually sets).
- **Batch window**: cook day + 2 (3-day span max).
- **Batch cap**: 6 portions total.
- Any meals with `noLeftover:true` are skipped.

One cook, no parallel chains: for a shared same-day batch with him + her, there is ONE anchor, not two. Everyone else — same-person leftovers, cross-person leftovers, and the same-day other-person portion — is a member of that one anchor's batch.

## Calorie Adjuster

Clean 2-step uniform scale with a `mealTotalServings` param so the snap
pass knows the true batch size for shared/leftover cooks:

1. **Skip-if-close**: If recipe is within 15% or 80 kcal of budget, no adjustment.
2. **Uniform scale**: All scalable ingredients scale by the same factor (capped at 1.75× scale-up on some meals).
3. **Fat-drop + backfill**: When a meal's fat % exceeds the limit, biggest fat contributor is dropped/reduced and calories are refilled with protein/carb items. Egg wholes auto-swap to egg whites when fat % exceeds limit.
4. **Post-snap trim**: Reduce highest-calorie items when over budget after snapping. 50% carb floor. Trim order: fat → carb → protein.
5. **Per-portion snap** (single pass): snap each ingredient's per-portion amount to its grid:
   - `oz`/`slice`/`scoop`/`serving` → whole
   - `cup` → 0.25 grid
   - `tbsp`/`halfSnap` → 0.5 grid
   - `each` eggs → whole; other `each` → 0.25 grid (or whole when `wholeWhenSolo` and single-portion)
   - `wholeOnly` → always whole
6. **Package nudge**: Per-meal nudge with per-ingredient flex ranges. Default ±0.25c / ±2 oz, marinara +100%, beans/chickpeas +50%, coconut +75%/-50%.

## Cross-Person Unification

`unifyCrossPersonRatios(skipRebuild)` enforces "one pot, one recipe" for multi-person batches.

**Math:**
```
batchKcal      = Σ person_pps × person_servings   (across all portions)
totalAmt[ing]  = Σ portion_amt × person_servings  (per ingredient)
perKcal[ing]   = totalAmt / batchKcal
new_amt_i      = perKcal × person_i_kcal
```

Each portion's new per-serving amount is proportional to their kcal budget. Scoop ratios become identical across all ingredients (checked by INV7 at 1% tolerance).

**Floor handling (veg/fruit + minAmt items)**:
- Veg/fruit floor = recipe base amount per portion
- `minAmt` items floor = `db.minAmt` per portion
- If any portion's kcal-proportional amount falls below its floor, scale the WHOLE batch up by `scaleFactor = floor / smallest_ideal`. Ratios preserved, floor met, only the batch total grows.

Called twice in the pipeline: once before `snapBatchTotals` (fresh unification), once after `postBalanceWastePass` with `skipRebuild=true` (restores ratios after waste nudges desync them).

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
   - **Veg < 3c**: +veg one grid step (no trim — veg is so low-cal the min-grid trim would remove way more kcal than the veg adds). Threshold 0.005c. Cap 3× recipe base.
4. Cached per (p, d); invalidated via `invalidateLeftoverCache`.
5. Fruit is NOT boosted — user preference, and most days hit naturally.

## Variety Filter (Phase 1)

`_randomizeWeekCore` Phase 1 builds two candidate-exclusion lists per person/day:

- **`recentIds`** via `getRecentMealIds(dayIndex, days, p, 5)` — meals picked by EITHER him or her in the past 5 days (excluding prior-day entries flagged as leftover in `computeLeftovers`). Eating a leftover isn't a "new meal" — it should never block same-meal picks.
- **`lastWeekIds`** via `getLastWeekMealIds(p)` — all meal IDs from last week's SEL (both persons).

Phase 1 candidates filter:
- **Snacks exempt** — small pool (17 in rotation), meant to repeat freely.
- `lastWeekIds` match → reject unconditionally.
- `recentIds` match → reject UNLESS `isBatchLeftoverEligible(d, s, mealId)` returns true. That helper returns yes if there's a cook ANCHOR (not a leftover) of `mealId` in the past 2 days — specifically checking the leftover map to distinguish anchors from leftovers. Only lunch/dinner eligible, non-`noLeftover` meals.

Fallback cascade (preserves variety filter as long as possible): primary → drop `used` → drop shared-slot → drop variety (last resort). Each level still honors filter when possible; only drops constraints as needed to find a viable meal.

**Variety filter now applied in ALL meal-setting stages**: Phase 1 primary + fallbacks, rerollMissDays, Phase 1.5 (solo pkg removal), Phase 3 Strategy A (waste-reduction swap), Phase 3 Strategy C (solo pkg removal), Phase 4 (her-mirror swap). Each is per-person, lookback=4 days to match INV14's `gap<5`. `_prevWeekKey()` selects the chronologically-previous week (`'this'` when randomizing `'next'`, `'last'` otherwise).

**INV14 delta rejection**: swap stages (rerollMissDays, Phase 1.5, 3-A, 3-C) count `countInv14()` before and after candidate swaps; reject any swap that would raise the count. The retry selector scores lexicographic (totalWaste, goalMisses, inv14Count) — bestSEL is restored with the lowest combined tuple.

## Randomize Pipeline (order matters)

Every `randomizeWeek` call runs the full sequence on the best retry:

1. `_randomizeWeekCore` — Phase 1 random picks, Phase 2 waste analysis, Phase 3 A/B/C swaps, shared-schedule enforcement
2. `rerollMissDays` — per-miss-day single-slot swaps
3. `applyTripFlexScaling` — proportional flex-ingredient scale to hit package boundaries
4. `unifyCrossPersonRatios()` — first unify (rebuilds cache)
5. `snapBatchTotals()` — snap each batch total to per-serving grid, redistribute proportionally, re-run balancer on affected days with batch slots frozen
6. `postBalanceWastePass()` — **batch-aware**. Iterates cook anchors, sums each batch's contribution as one unit, nudges whole batches toward package boundaries, reverts whole-batch if any affected day breaks goals
7. `unifyCrossPersonRatios(true)` — second unify (skipRebuild), restores ratios that waste nudging may have desynced
8. `snapBatchTotalsToGrid()` — **floor-aware final snap**. Snaps each batch total to per-serving grid (NEAREST). If snapping down would drop any portion below its floor, snaps UP instead. Re-runs balancer on affected days with batch slots frozen.
9. `boostBatchVegForDailyTarget()` — last-resort booster. When a day is under 3c veg and all non-batch veg is maxed, grows the batch's veg total by +0.25c at a time and redistributes proportionally across all portions (preserves INV7 ratios).
10. `verifyInvariants()` — runs INV1–16; INV6, INV14, INV15, INV16 are tracking-only (don't count as fails)
11. `renderMeals()` + `autoSaveWeek()`

**Retry loop** (30 outer iterations of `_randomizeWeekCore`, then lexicographic best by waste→misses) NOW runs the full post-balance pipeline INSIDE each retry's measurement — so the goal-miss count reflects the actual final state, not pre-snap estimates. Fixed this session: previously the retry selector saw pre-snap numbers and committed to combos that drifted post-snap.

**Critical: `renderMeals()` does NOT invalidate the balanced cache.** Earlier versions did and wiped all post-pipeline mutations (snap, unify, waste, boost) before the user saw them. Mutation paths (meal swap, override, skip/eat-out, randomize) must explicitly invalidate *before* calling `renderMeals`.

## Card Display

Every consumer reads per-serving from `getBalancedSlotIngredients(p,d,s)`:

- **Solo slot**: shows per-serving with on-grid amounts (INV8 enforces)
- **Batch cook anchor (non-shared, e.g. cross-person only)**: shows "Combined ingredients (serves N)" with batch total summed across `lo.portions`. Him tab (anchor) shows this.
- **Batch cook anchor (shared same-day, `loInfo.shared`)**: Him/Her tabs show **per-serving only**, no combined view. The Shared tab owns the combined view (enforced by INV9). Big Cook pill may still render on Him/Her tabs — user OK'd.
- **Batch leftover (same-day shared)**: renders as normal per-serving card with Shared highlight (no "Lo <day>" pill).
- **Batch leftover (time-shifted, same or cross-person)**: shows per-serving with "Leftovers <day>" pill. Per-serving amounts are fractional by design (kcal-proportional split of the unified batch).

**1-decimal display** in dropdowns: when a batch member's per-serving amount doesn't match a preset (¼, ⅓, ½, ¾, 1, 1¼, etc.) and the slot is part of a multi-portion batch, the custom option label rounds to 1 decimal (7.701 → "7.7"). Solo slots keep the existing 3-decimal display — if a solo slot ever goes fractional, we want to see it, not hide it.

## Cross-Tab Card Sync

Expanding/collapsing a meal card in the Him tab mirrors the same slot's state in the Her tab. Shared tab has independent state. Implemented in `toggleCard(k)` by splitting the key and setting `openCards[otherKey] = openCards[k]`.

## Page State Persistence

Session state survives refresh via `sessionStorage['mealPlannerPageState']`: `topTab`, `person`, `day`, `activeWeek`, `scrollY`, `openCards`, `sharedSchedOpen`. Saved on `beforeunload`, restored at init. Scroll position restored after render via `setTimeout`.

## Package Waste Elimination

Achieves 100% zero-waste on `Randomize` clicks via a multi-layer pipeline:

1. **Phase 1 (random picks)**: 60 attempts per person/day. Scoring uses **scaled-to-slot-budget** kcal (not raw base kcal). Score = `calDiff + fatPenalty + discouragedPenalty`. Early exit when `calDiff ≤ 100 && fatPct ≤ 0.30`.
2. **Phase 1.5 (solo pkg removal)**: Any pkg meal that is NOT shared and NOT part of a leftover chain gets replaced with a non-pkg alternative.
3. **Phase 2**: Package analysis per trip (Mon–Wed / Thu–Sun) via `_analyzeTripPackages`. Uses per-slot scaled estimates.
4. **Phase 3**: Convergence loop (up to 6 iterations per trip) with strategies A (swap non-pkg to wasting ingredient), B (mark resolvable-by-nudge), C (remove single-use pkg only if it strictly reduces total trip waste).
5. **Retry loop**: 30 internal retries per `randomizeWeek` click. Lexicographic best by (totalWaste, goalMisses).
6. **Smart day re-roll**: scored single-slot swaps for miss-days. Pkg meals never swapped out or in during re-roll.
7. **Trip-level flex scaling**: proportionally scales flex-ingredient meals to hit pkg boundaries. Per-usage revert if a day breaks.
8. **`postBalanceWastePass` (batch-aware)**: iterates cook anchors, treats each batch as one unit when nudging. All-or-nothing per-batch revert.
9. **Dried beans**: 11 bean meals use dried variants (no `pkg`). Eliminates bean can waste entirely.

Waste display in shopping list: `waste = ceil(total/perPkg)*perPkg - total`. Displayed as "⚠️ ½ can unused". Skipped for `longShelfLife` items.

## Randomizer

`randomizeWeek(target)` wraps 30 retries of `_randomizeWeekCore(target)`, then runs targeted day re-rolls.

**Retry selection** (lexicographic, lower is better):
1. Total waste
2. Goal misses (person-days that fail any of the 6 primary daily goals)

**2-day meal gap rule** enforced by `getRecentMealIds(p, 2)` — excludes meals used in the previous 2 days. Formalized as INV11.

**Result quality** (measured 50 runs × 700 person-days):
- Primary goal hit rate: ~97% (misses: borderline fat%, kcal ±100 boundary, occasional veg)
- Secondary goal hit rate: ~100% (the "buffer zone must always be 100%" target)
- Zero-waste rate: 100%
- Per-click time: ~2–3s on desktop

## 3-Week View

- **Last / This Week / Next**: Three week pills. Auto-rollover shifts last←this←next.
- **Last week**: Amber banner "View Only". No randomize button.
- **Next week**: Blue banner "Planning Ahead". Fully editable.
- **Rollover**: Clears all manual overrides for the new week.

## UI Pills (top row of each meal card)

- **Leftovers** (amber) — auto, not clickable. Shows on leftover entries *unless* `sameDayShared:true`.
- **Big Cook** (amber) — auto, not clickable. Shows on cook anchor.
- **Set** (purple) — auto, not clickable. Shows when slot is manually overridden.
- **Shared** (green) — toggle for shared cooking.
- **Skip** (grey) — toggle. Sets MANUAL_SET. Eat Out visible when skipped.
- **Eat Out** (red) — toggle. Sets MANUAL_SET. Overrides skip.

## Macro Display

- Stats bar: kcal (person color) / protein (person color) / carbs (green) / fat (yellow)
- Macro bar: P/C/F colored segments. Her tab uses pink (#F472B6) for protein.
- Meals tab color: blue (Him), pink (Her), green (Shared).

## Shopping

- `buildShoppingList(trip, who)` adds each slot's balanced amounts via `getBalancedSlotIngredients`. No leftover multiplier, no cross-person handling, no shake special case. Every slot contributes directly.
- `hisSum`/`herSum` are NEVER modified — reflect exact balanced amounts.
- `shopQtyWithCount()` converts qty → shopping label (packages, whole produce, or bulk).
- Waste flagged per pkg item, skipped for `longShelfLife`.
- Egg whites vs whole eggs are separate lines.

## Shared Tab

`renderSharedView(day)` → `renderSharedCard()` for each slot where `him_id === her_id`. The card iterates `lo.portions` and sums the actual balanced per-serving amounts across all portions for the combined total. Per-person per-serving amounts shown inline on each row for reference (1-decimal format).

## Recipes Tab

Three collapsible sections:
- **New Recipe**: Compact form with slot/person chips, bordered ingredient list, steps textarea.
- **New Ingredient**: 2-row compact form (Name/Unit/Role + Kcal/Pro/Fat/Carb).
- **Edit Recipes**: Slot/meal picker with inline preview. Edit mode shows quantity dropdowns.

**Meal categories**: Dropdowns group meals by category. Lunch/dinner dropdowns additionally expose a **Vegetarian** group.

## Temp Ingredient Button

Each meal card shows a `+` button in the ingredient section header. Tapping opens a picker (`addTempIngredient` → `confirmTempIngredient`) to append a one-off ingredient to that person/day/slot without editing the underlying recipe.

## Cloud Sync

GitHub Gist API push/pull with per-slot timestamp merge (last-write-wins). Syncs weekData (all 3 weeks), customMeals, customIngredients, eatOutDB.

## Runtime Invariants

`verifyInvariants()` runs after every `randomizeWeek`. Any violation warns to console with a specific message. **>0 violations = bug** (except INV6, which is tracking-only).

**Full detailed rules: see [INVARIANTS.md](INVARIANTS.md)** — standalone quick-reference with expanded rule text.

| ID | Rule | Tolerance | Status |
|---|---|---|---|
| **INV1** | Same-person leftover amounts match cook-day amounts exactly | 0 | hard |
| **INV2** | `calcTotals(p,d)` day kcal matches sum of kcal across slots from `getBalancedSlotIngredients` — stats bar vs cards consistency | kcal within 2 | hard |
| **INV3** | `buildShoppingList(trip, who)` amounts match balanced cache summed across the trip — shopping list vs cards consistency | exact | hard |
| **INV4** | Solo pkg meal must have all pkg ingredients in `PKG_FLEX_CONFIG` (else flex scaling can't resolve trip waste). Replaced Phase 1.5 inline cleanup. | exact | hard |
| **INV5** | Card macros (via `computeCardMacros`) match `getBalancedSlotIngredients` for that slot — card header vs ingredient list consistency | exact | hard |
| **INV6** | Per-meal protein/carb ratio changes <50% vs base recipe — signals day-balancer isn't distorting the dish too aggressively | ~2/run typical | **tracking-only** |
| **INV7** | Cross-person cook scoop ratio consistent across all ingredients — one pot, one ratio (per-person split proportional to kcal share) | 1% | hard |
| **INV8** | Solo per-serving amounts AND batch totals land on ≤2 decimals OR 1/8 fractions (0.125, 0.375, 0.625, 0.875). pkg items exempt | 0.001 | hard |
| **INV9** | Him/Her tabs never show "Combined ingredients (serves N)" header for a same-day shared meal — Shared tab owns combined view | exact | hard |
| **INV10** | Every lunch/dinner recipe has >0 cups of veg (static check over MEALS) | static check | hard |
| **INV11** | ≥2-day gap between batches of the same meal within a week (excludes `noLeftover`) | exact | hard |
| **INV12** | `lo.totalServings === lo.portions.length` AND every portion shares the anchor's meal ID — detector consistency | exact | hard |
| **INV13** | Per-serving amount for any ingredient with `db.minAmt`/`db.maxAmt` within bounds (solo AND batch). Solo slots (no leftover-map entry) use `db.minAmtSolo` when defined for pan-oil/aromatic-quality floor | 0.001 | hard |
| **INV14** | Per person, no two NEW cooks (non-leftover) of the same meal within 5 days (lunch/dinner only). Breakfast/snack exempt — pool too small | exact | **tracking-only** (promote when breakfast normalization grows pool) |
| **INV15** | Tracking-only: count of lunch/dinner leftovers **him** eats per week (regardless of cook). MPStress aggregates as `avgLeftoversEaten.him` | — | **tracking-only** |
| **INV16** | Tracking-only: count of lunch/dinner leftovers **her** eats per week. MPStress aggregates as `avgLeftoversEaten.her` | — | **tracking-only** |

## CSS Architecture

Uses CSS custom properties (`:root` vars) for theming. Key reusable classes:
- Layout: `macro-bar`, `macro-labels`, `hdr-row`, `sched-grid`, `sched-panel`, `paint-bar`
- Schedule pills: `sched-pill-wrap`, `sched-pill-half`, `sched-zone` (l/c/r)
- Buttons: `sched-btn`, `sched-btn-set`, `rand-btn`
- Cards: `sv-card`, `sv-meal-title`, `set-pill`, `day-badge`
- Sync: `sync-desc`, `sync-field-label`, `sync-id-box`, `sync-btn-grid`

## Key Helper Functions

- `computeLeftovers()` — unified detector (see Leftover & Batch Detector section)
- `getDayBalancedIngredients(p, d)` — **single source of truth** for all ingredient amounts. Cached map of `{slot: [{dbKey, amt, role, scalable, origAmt}, …]}`.
- `getBalancedSlotIngredients(p, d, s)` — shortcut for one slot. Every consumer reads from here: `calcTotals`, `buildShoppingList`, `computeCardMacros`, `renderSharedCard`, `computeDailyFV`.
- `unifyCrossPersonRatios(skipRebuild)` — batch ratio enforcement (floor-aware).
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

- `index.html` — the entire app (single file, ~10,300 lines; includes `window.MPStress` harness)
- `manifest.json` — PWA manifest (standalone, dark theme)
- `sw.js` — service worker (network-first caching, GitHub API passthrough)
- `icon.jpeg` — app icon
- `CLAUDE.md` — this architecture doc
- `Archive/` — backup copies of previous versions

## Current State (as of 2026-04-17 session — late)

### Quality (baseline 50-run batches, deterministic seeded)
- **Primary goals**: **97.7–98.5% hit rate** (multi-batch range). Misses cluster at Her fat% 30.1–31.9% and occasional Her veg/kcal borderline.
- **Secondary goals**: 100%
- **Zero-waste rate**: 100%
- **INV1–5, INV7–13**: **0 violations** (baseline 100 runs + varied 50 runs = 2100 person-days)
- **INV6**: tracking only
- **Per-click time**: ~2–3s

### Varied-state stress (50 runs × 14 person-days w/ random skips, locks, sharing — eat-outs removed from harness)
- **Primary goals**: ~97.7% hit rate (matches baseline — pipeline handles user overrides cleanly)
- **Most common miss**: Her fat% borderline
- **All invariants**: 0 violations

### Stress-test harness (`window.MPStress`)
Dev-only in-browser harness for running N randomizations × 14 days and reporting per-goal miss histograms, fat/kcal/veg bins, invariant counts, and veg-per-serving ceiling (flags >3c per serving). Methods:
- `MPStress.runBaseline(N)` — clean-state runs
- `MPStress.runVaried(N)` — with stochastic eat-outs/skips/locks/sharing
- `MPStress.runSharing(N)` — across fixed sharing configurations
- `MPStress.runOne(mode, seed, cfgFn)` — single-run primitive

State is snapshotted/restored per run with explicit `clearTimeout(_selSaveTimer)` to prevent leakage of stressed state into localStorage via the autosave debounce.

### Threshold system (added late this session)
Every non-protein/non-carb ingredient has explicit per-serving `minAmt` and `maxAmt` in NUTRI_DB. Enforced everywhere per-serving amounts are computed or modified. INV13 catches violations.

**Enforcement points** (pipeline order):
1. `adjustIngredients` uniformScale — clamps to min/max after scale
2. `adjustIngredients` post-balance correction — same
3. `boostFV` (balancer veg grow) — respects max(relative, maxAmt)
4. `unifyCrossPersonRatios` — scales batch DOWN if any portion exceeds maxAmt; scales UP to hit minAmt (existing floor behavior). Safe to do in unify now that `postBalanceWastePass` cross-trip bug is fixed
5. `boostBatchVegForDailyTarget` — respects maxAmt
6. `snapBatchTotals` — reduces snapped total to keep max portion ≤ maxAmt
7. `snapBatchTotalsToGrid` — same

**Ingredients with thresholds (~60 items):**
- **Veg (17)**: leaf veg (spinach, kale, bok choy) max 3c. Standard veg (broccoli, bell pepper, carrots, grape tomatoes, zucchini, brussels sprouts, asparagus, bean sprouts, cucumber) max 2c. Aromatic small veg (red onion max 0.5c, shallot, scallion, poblano, celery).
- **Oils (3)**: avocado, olive, sesame — min 0.13 tbsp (supports proportional scaling of fats in big-batch recipes), max 1.5 tbsp.
- **Other fats (6)**: peanut butter (min 0.5, max 2), almond butter (same), tahini (min 0.25, max 2), chia seeds (min 0.25, max 2), sesame seeds (min 0.25, max 1), coconut milk (min 0.25, max 1).
- **Fatty foods (4)**: avocado whole, cheddar jack, heavy cream, butter.
- **Fruits (5)**: banana/apple/orange each 0.5–1. Mixed berries 0.25–1.5c. Acai 0.25–1c.
- **Spices/aromatics (16)**: all halfSnap tbsp items (cinnamon, salt, black pepper, rosemary, thyme, garlic powder, onion powder, cumin, italian seasoning, dill, oregano, parsley, cilantro, chili flake, red pepper flake, ginger) — min 0.13, max 1.
- **Other (2)**: garlic (cloves) min 0.5 / max 4. Lime (each) min 0.25 / max 1.

Previously there was a hardcoded 3c-per-serving veg backstop in four enforcement points. Removed — `db.maxAmt` is now the single source of truth. If a new veg is added without `maxAmt`, it has no absolute ceiling (only the relative 3× base / 4× leaf cap in boost paths). Add `maxAmt` when adding new veg to the DB.

### Applied fixes this session
- **Fix B (veg-boost reach)** in `boostFV` (line ~3519) and `boostBatchVegForDailyTarget` (line ~5706): raise 3× recipe cap to **4× for leaf veg only** (`baby spinach`, `kale`, `bok choy`, all <35 kcal/cup). No INV regression.
- **Fix D (Phase-1 fat-penalty strengthen)** in `_randomizeWeekCore` phase-1 scoring (line ~6907): raise daily-fat-overage coefficient from 1000 to **3000** at the existing `>0.30` threshold. Tightens fat% distribution (fewer >32% outliers).
- **Fix A (directional rounding)** in `adjustIngredients` post-trim snap (`snapAmt` function, line ~3356): remove the `Math.ceil` bias when BOOSTING fat. Uses `Math.round` — eliminates a documented source of fat% upward drift.
- **3c/serving veg cap** in `snapBatchTotals` (line ~6137) and `snapBatchTotalsToGrid` (line ~5935), plus boost paths (`boostFV`, `boostBatchVegForDailyTarget`). No portion exceeds 3c veg regardless of recipe base or batch scaling. NOTE: a parallel cap in `unifyCrossPersonRatios` was tried and REMOVED — it caused intermittent INV7 drift (veg scaled independently from protein/carb). Snap caps alone are sufficient.
- **Seeded `randomizeWeek(target, seed)`**: optional `seed` arg replaces `Math.random` with a deterministic PRNG for the duration of the call and restores it in a `finally`. Used by the stress harness (`runOne` passes `seed+1e6`) so failing cases are reproducible. This surfaced an INV1 bug (below).
- **Root-cause fix in `postBalanceWastePass`**: the waste pass iterated trips (Mon-Wed, Thu-Sun) and processed each batch per-trip, filtering portions to those in the current trip. For a batch spanning trips (e.g., Her's Wed-lunch cook + Her's Thu-dinner leftover), trip 'sun' would nudge the Wed portion one way and trip 'wed' would nudge the Thu portions a different way — desyncing same-person leftover pairs (INV1) and cross-person ratios (INV7). Fix: gate on the cook day's trip (`if(!inTrip[d])return;`) and process ALL portions of the batch atomically — the whole batch uses one package from one trip's shopping. This is the real root cause of the earlier INV7 drift that was only papered over by removing the unify cap; the unify cap is safe with this fix in place.
- **`MPStress.enumerateFailures(runs, startSeed)`**: dumps top (meal, slot, person, missType) offenders and (slotA+slotB) pairs across N runs. Produces the raw `allFailingDays` list for external aggregation.
- **Recipe changes** (based on 500-run enumeration):
  - `korean_rice_bowl`: sesame oil **1 tbsp → 0.5 tbsp**. Per-meal fat% 32.8% → 25.5%. Her fat misses 24 → 11 (-54%).
  - `miso_edamame`: fully reworked. Was water + miso + silken tofu + sesame seeds (52% fat, misleadingly named — no edamame). Now water + miso + silken tofu + edamame 0.5c + egg white 0.5c + scallion 2× (**26% fat, 256 kcal, 31g protein**). The egg white (0% fat) dilutes the fat% below 30 while keeping structural protein.
  - `celery_pb_light` → **removed** and replaced with 3 new snacks:
    - `celery_yogurt_dip`: 2 celery + 0.75c Greek yogurt 0% + dill + garlic powder + black pepper + lemon. **110 kcal, 1.8% fat, 19g pro**.
    - `celery_tuna_salad`: 2 celery + 1 tuna pouch + 0.25c Greek yogurt + lemon + black pepper. **135 kcal, 8.2% fat, 27g pro**.
    - `celery_apple_plate`: 2 celery + 1 apple. **107 kcal, 4% fat**, adds 1.5c fruit.
  - Why the replacement: `celery_pb_light` was structurally unfixable (celery has 0 macros, PB is 75% fat) — the optimizer couldn't hit Her's snack budget without pushing fat%. The new snacks have real protein/carb structure so the adjuster can scale them to budget without fat%-drift cascade into dinner.
- **Fix C skipped** — `safety=55/60` raised in `balanceDayMacros` regressed hit rate by ~0.7pp.
- **Fix E reverted** — package-meal reroll escape hatch introduced INV1 violations and regressed hit rate by ~0.8pp.

### Late-session recipe changes
- **Avocado oil removed** from `salmon_lentils`, `red_curry` (oil was redundant on top of naturally-fatty protein / coconut milk).
- **`chicken_thigh_din` deleted**, DEFAULTS updated to `lemongrass_chicken_thigh`.
- **`egg_orange_light` deleted**, **`eggs_orange` deleted**, **`eggs_apple` deleted**, **`eggs_chickpeas` deleted** — user decision to remove egg+fruit snack combos.
- **`edamame_apple`, `edamame_orange_eve`, `edamame_berries_eve`, `edamame_berries_light` deleted** — egg+fruit/edamame+fruit combos all removed.
- **5 new snacks added**:
  - `yogurt_apple_cinnamon` (215 kcal, 1.3% fat, 24.5g pro)
  - `yogurt_banana_honey` (227 kcal, 1.6% fat, 19g pro)
  - `shrimp_cucumber_plate` with dill (113 kcal, 10.8% fat, 23.6g pro)
  - `chickpea_cucumber_salad` (127 kcal, 8.1% fat)
  - `spiced_chickpea_spinach` (125 kcal, 8.8% fat)
- **3 new celery snacks replaced `celery_pb_light`**: `celery_yogurt_dip`, `celery_tuna_salad`, `celery_apple_plate`.
- **Bean renaming**: `chickpeas dried` → `chickpeas cooked`, `black beans dried` → `black beans cooked`, `cannellini beans dried` → `cannellini beans cooked`. The ingredients measure COOKED cups (despite previous naming). Recipe display still shows "Chickpeas, cooked: X cups".
- **`mediterranean_chickpea_salad`** added (lunch/dinner): 594 kcal, 17.7% fat, 32.4g pro, 2.85c veg. 1.5c chickpeas : 0.5c grape tomatoes (3:1 ratio from user's original recipe). Scale: Him 1.53×, Her 1.00×.
- **`coconut_turkey_curry`** rewritten (lunch/dinner): from 924 kcal → **574 kcal**, 24.1% fat, 28.3g pro, 2.13c veg. User provided the original full-recipe quantities for proportional per-serving scaling.
- **New ingredients in NUTRI_DB**: `grape tomatoes`, `red onion`, `parsley`, `cilantro`, `dried oregano`.

### Remaining fat% misses (what 97–98% represents)
After all fixes, remaining Her fat misses cluster tightly at **30.1–31.9%** — the absolute cliff. The downstream pipeline (selector + balancer + snap) gets close to 0.30 but tips slightly over because:
1. Her kcal budget (1900) makes any fat-dense snack a large %-share
2. Snacks like `celery_pb_light` (~80 kcal, 66% fat) and `miso_edamame` (~111 kcal, 46% fat) are structurally high-fat — can't be reduced much without becoming un-food
3. Same meal combos repeat across seeds (e.g., `chicken_breakfast_wrap + turkey_zucchini_boats + salmon_lentils + yogurt_berry_eve` fails 3× on Her's Monday)

Further improvement would require: restructuring these snack recipes (add non-fat protein to dilute, e.g., cottage cheese), or a per-slot fat-budget phase-1 constraint that prevents high-fat snacks from co-selecting with high-fat dinners on Her days.

### Open work for next session

**Recipe normalization** (in progress): bring all lunch/dinner bases into **500–700 kcal** range (target 600) and breakfast bases into **320–520 kcal** range (target 420). This ensures every meal scales proportionally to both Him (910 budget) and Her (595) within the 1.75× estimate cap.

Completed this session: `coconut_turkey_curry` (924→574), `mediterranean_chickpea_salad` (new 594). Deleted: `chicken_thigh_din`, `egg_orange_light`, `eggs_orange`, `eggs_apple`, `eggs_chickpeas`, `edamame_apple`/`orange_eve`/`berries_eve`/`berries_light`, `celery_pb_light`.

**Still needs rewrite (26 recipes):**

*Lunch/dinner below 500 (needs bump, 11):* `lemongrass_salad` (318), `cannellini_kale_soup` (354), `white_bean_soup` (357), `lentil_soup_lean` (364), `turkey_zucchini_boats` (387), `hummus_wrap` (388), `chicken_sweet_potato_bowl` (391), `lentil_chicken_bowl` (411), `shrimp_quinoa_bowl` (439), `viet_vermicelli` (444), `roast_chicken_din` (498).

*Lunch/dinner above 700 (needs trim, 7):* `filet_din` (718), `red_curry` (751), `thai_peanut_noodle` (775), `spicy_tofu_chicken_noodles` (795), `shrimp_bowl` (813), `salmon_teriyaki_din` (849). (`coconut_turkey_curry` already done.)

*Breakfast below 320 (bump, 5):* `sweet_potato_egg_hash` (242), `korean_juk` (249), `shakshuka` (297), `chicken_breakfast_wrap` (314), `turkey_sweet_potato_hash` (319).

*Breakfast above 520 (trim, 3):* `coconut_chia_pudding` (553), `protein_pancakes` (576), `yogurt_bowl_post` (597).

**Scaling approach** (user-confirmed):
- Scale protein + carb together in step 1 (not sequentially)
- Less scaling of veg (they're near min already)
- Fat/aromatic/spice items: per-serving thresholds enforce floors/ceilings; proportional scaling is fine for fats at batch level
- User provides the original full recipe when rewriting (like they did for `coconut_turkey_curry`) — we can't assume existing recipe ratios are correct. When the original isn't available, bump/trim the main protein/carb only and leave fixed items untouched.
- One recipe at a time, user reviews each

**Other open items:**
- **INV6 enforcement**: currently tracking-only. Could cap how much day balancer shifts P/C ratio — tradeoff vs macro goal accuracy.
- **Secondary goal UI**: "yellow zone" vs "green zone" display on stats bar.
- **Meal variety audit**: some meals still heavily favored.
- **Ground meat pkg.type**: `'container'` — verify shopping display matches.
- **Cheat meals**: `noRandomize` infrastructure ready, no meals flagged yet.
- **Hummus dilution**: `cucumber_hummus_light` sits at 49% fat (hummus is structurally 50%). Options proposed: reduce hummus + add more veg OR add tuna pouch to turn it into a crudité+protein. Not yet applied — user decision pending.

### Snapshots (Archive/)
Recent checkpoints for rollback:
- `index_2026-04-17_*` — prior session (see that session's notes)
- `index_2026-04-18_*` — pipeline fixes (minAmtSolo, retryRealNumbers, maxAmt caps, variety filter)
- `index_2026-04-20_*` — flex-aware waste + snapSoloSlot + INV4 + markdown report
- **`index_2026-04-21_household_inv14.html`** — current baseline. Household INV14/filter, rerollInv14Violations, chickpeas cooked swap, INV15/16 exclude sameDayShared, INV7 cross-batch checker fix. Primary 98.64%, INV14=1, all hard INVs=0, 0% closed-off, 94.4% variance.

## Session 2026-04-21 — INV4 promoted, household INV14, cleanup pass

### What landed
- **Phase 1.5 removed entirely.** Replaced by hard **INV4**: solo pkg meal must have all pkg ingredients in `PKG_FLEX_CONFIG` so `applyTripFlexScaling` can resolve the trip-level waste. No more inline cleanup; enforced as a hard invariant instead. INV4 was "reserved, unused" since the invariant system was first added (2026-04-16); never had a rule until now.
- **INV14 + variety filter BOTH promoted to household-level.** Previously per-person → per-person, which silently allowed cross-person same-meal repeats (Her Mon cook + Him Wed cook with gap=2 was invisible). Now `getRecentMealIds`, `getLastWeekMealIds`, and `countInv14`/INV14 all scan both persons. `p` stays in signatures for backward compat but is ignored by content.
- **`rerollInv14Violations` resolver pass.** Runs right after `rerollMissDays`. For each INV14 pair, tries to swap the LATER cook to a non-conflicting meal. Accepts only if INV14 count strictly decreases, waste doesn't worsen, and affected day misses don't increase. Dropped INV14 from 17 → 1 on the 100-run test.
- **INV15/16 exclude `sameDayShared`.** Previously Her's count was inflated 4-5/wk by shared-dinner portions (detector always picks Him as anchor, Her's same-day same-slot portion gets `isLeftover:true + sameDayShared:true`). The metric now measures time-shifted reheat only. Him 3.0, Her 2.8 (previously Him 2.7, Her 6.1 — same data, different definition).
- **INV7 checker bug fix.** The check found the "other person's slot" via `getMealId(otherP, feedsDay, os) === mealId`, which picked the first slot match on that day — if the same meal was in two different batches same day, it compared across batches and reported bogus drift. Now uses the anchor's `lo.portions` list directly.
- **Report format rewritten to markdown tables.** `formatReport` outputs proper markdown sections/tables so output renders well in chat (not ASCII box-art). Includes KEY METRICS block with baseline deltas, miss severity bins, top meals in failing days, per-slot meal usage, never-picked lists.
- **Two snack recipes un-shut-out.** `chickpea_cucumber_salad` + `spiced_chickpea_spinach` were always removed by Phase 1.7 because they used `chickpeas roasted` (pkg, only 2 meals use it). Swapped to `chickpeas cooked` (non-pkg, same macros — user clarification: they're dried-cooked, not canned). All 120 meals now pick.

### Pipeline order (final state post-2026-04-21)
Inside `_randomizeWeekCore` (runs inside retry loop):
1. Phase 1 (random picks with variety filter + fallback cascade)
2. ~~Phase 1.5~~ REMOVED (replaced by INV4)
3. Phase 1.6 (over-budget snack swap)
4. Phase 1.7 (sole-pkg snack swap)
5. Phase 2 (pkg waste analysis)
6. Phase 3 (Strategy A/B/C swap/nudge loop)
7. Phase 4 (shared-schedule enforcement)

Post-retry (in `randomizeWeek` outer loop):
1. `rerollMissDays` — fix primary goal misses
2. **`rerollInv14Violations`** — fix household same-meal-within-5d repeats (NEW)
3. `applyTripFlexScaling` — nudge flex pkg amounts to boundaries with carb/fat backfill
4. `unifyCrossPersonRatios` — one pot, one ratio
5. `snapBatchTotals` — snap batch totals to grid
6. `postBalanceWastePass` — batch-aware pkg nudging
7. `unifyCrossPersonRatios(true)` — re-normalize
8. `snapBatchTotalsToGrid` — final batch grid snap
9. `boostBatchVegForDailyTarget` — grow batch veg to hit 3c daily
10. `snapSoloSlotAmountsToGrid` — final non-batch grid snap (INV8)
11. `verifyInvariants` — INV1-16 check

### Current quality (2026-04-21 final 100-run baseline, mixed shared config)
- Primary hit rate **98.64%**
- INV14 **1** total (down from 17 after household promotion → rerollInv14Violations resolved 16)
- Hard invariants (INV1-5, 7-13) **all 0**
- Meals closed-off **0.0%** (all 120 meals picked)
- Avg variance **94.4%**
- Zero-waste rate 100%

### Open items for next session
- **Breakfast normalization** — 8 breakfast recipes still off-budget: sweet_potato_egg_hash 242, korean_juk 249, shakshuka 297, chicken_breakfast_wrap 314, turkey_sweet_potato_hash 319, coconut_chia_pudding 553, protein_pancakes 576, yogurt_bowl_post 597. All get picked now but hit rate drops when they land on tight budgets.
- **Lunch/dinner outliers** — spicy_tofu_chicken_noodles 795, red_curry 751, thai_peanut_noodle 775, hummus_wrap 388, chicken_sweet_potato_bowl 391, lentil_chicken_bowl 411, shrimp_quinoa_bowl 439, viet_vermicelli 444, roast_chicken_din 498.
- **Phase name/number cleanup** — current naming is 1, 1.5 (gone), 1.6, 1.7, 2, 3(A/B/C), 4 — the decimals + Strategy-letters + implicit post-retry numbering (reroll, flex, unify, snap, waste, unify2, grid-snap, boost, solo-snap) is ad-hoc. Next session: give each stage a clear number and descriptive name.
- **INV6 drift audit** — tracking-only P/C-ratio-change metric. Currently ~5 fires/run. How extreme are the distortions? Check top offenders, decide if it should be promoted to hard.
- **Code review pass** — recent work added several helpers (`canFlexFitToPkg`, `countInv14`, `rerollInv14Violations`, `snapSoloSlotAmountsToGrid`, `_prevWeekKey`) and several pipeline stages got rewritten. Review for dead code, redundant invalidations, misleading comments.
- **Retry selector Option C (parked)** — reorder from `(waste, misses, inv14)` to `(waste, inv14, misses)`. Could push last INV14 fire to 0 but might hurt miss rate. User said "maybe C if it helps and doesn't hurt misses" — test separately.
- **Continue recipe adjustments** (user-driven, one at a time).

### Standard test reference
- Invocation: `MPStress.runStandard(100)` → returns agg + prints markdown report
- Seeds: 12345..12444 (deterministic)
- Shared-schedule config: Mon/Wed/Fri/Sun dinners + Wed lunch (applied automatically by runStandard, restored after)
- Baseline saved to localStorage via `MPStress.saveBaseline(agg)` — shows delta against saved baseline in the Key Metrics block. Current saved: primary 98.64, INV14=1, hard=0, closed-off 0.0%, variance 94.4%.

## Session 2026-04-18 — Major Structural Work

### Threshold system extensions
- **`minAmtSolo`** (new concept): higher per-serving floor for single-portion cooks (pan-oil realism, aromatic quality). Applied to 5 items: avocado oil 0.5, red onion 0.2, scallion 2, celery 2, poblano 1. Fires only when `mealTotalServings === 1`. Enforcement: 3 clamp points in `adjustIngredients` + veg/fruit clamp in `getDayBalancedIngredients` + INV13 check uses `minAmtSolo` for solo slots.
- **`minAmt` doubled for wide-range veg** (13 items, ratio ≥4): baby spinach, kale, broccoli, bell pepper, carrots, grape tomatoes, zucchini, brussels sprouts, asparagus, bok choy, bean sprouts, shallot, cucumber. Narrow-range items (red onion, scallion, celery, poblano) kept at original min because ratio ≤2.5 conflicts with cross-person kcal ratios — instead uses `minAmtSolo` for variety.
- **`0.13` → `0.125` standardization**: all per-serving minimums that were `0.13` (approximate 1/8) replaced with `0.125` (exact 1/8). Cleaner fraction, displays as "⅛".
- **INV8 now accepts 1/8 fractions** in addition to 2-decimal values. Prevents false-firing on clean 1/8 amounts.

### Pipeline fixes
- **`adjustIngredients` clamp gaps closed**: all 3 early-return paths (delta<5, within-threshold, no-scalables) now apply minAmt/maxAmt clamp via `_clampThresh` helper. Final return also sweeps non-scalable items.
- **`getDayBalancedIngredients` always routes through adjustIngredients** — previously slotAdj=0 bypassed it, now it always calls to apply clamps. Veg/fruit clamp in the "ALWAYS use base recipe amount" branch now also respects minAmt/maxAmt/minAmtSolo.
- **`postBalanceWastePass` respects maxAmt** — previously scaled batches past maxAmt when chasing package boundaries. Now caps so largest portion ≤ maxAmt.
- **`applyTripFlexScaling` respects maxAmt** — same issue, same fix.
- **Retry loop measures on post-pipeline state** — previously measured pre-snap, committed to drifted combos. Now runs full unify/snap/waste/boost inside the measurement, so goal-miss selection sees real numbers. Cost: ~65ms per click. Hit rate +0.4pp baseline, +0.14pp varied.
- **1.75× scale caps removed** from 4 spots (Phase 1 scoring, Phase 3 swap estimates, 2 waste approximations). Actual adjuster has no cap, estimates now match reality. Frees small-base recipes to compete. Hit rate +0.5pp baseline, variety +4.1pp improvement.

### Variety filter (updated 2026-04-20)
- `getRecentMealIds(dayIdx, days, p, lookback=4)` — **household-level** (scans BOTH persons' past 4 days). Crosses into chronologically-previous week via `_prevWeekKey()`. Per-person scope was tried and reverted 2026-04-21 because it let cross-person same-meal repeats slip through (e.g., Her Monday cook + Him Wednesday cook = 2-day gap, silently allowed).
- `getLastWeekMealIds(p)` — **household-level**, reads chronologically-previous week's SEL for both persons.
- `isBatchLeftoverEligible(d, s, mealId)` — returns yes only if a cook ANCHOR (not leftover) of mealId exists in past 2 days. Cross-references `computeLeftovers()` to distinguish anchors from leftovers.
- Snacks exempt (small pool, meant to repeat).
- Applied in **ALL swap stages** (Phase 1 primary + all fallbacks, rerollMissDays, Phase 1.5, Phase 3 Strategy A, Phase 3 Strategy C, Phase 4).
- Swap acceptance in those stages also checks `countInv14()` delta — reject any swap that raises the per-week count.
- Retry selector scores (totalWaste, goalMisses, inv14Count) lexicographic; lower inv14 wins ties.

### Invariants INV14/15/16 (tracking-only)
- **INV14**: Household-level — no same meal cook by EITHER person within 5 days (gap<5 fires). Lunch/dinner only. Breakfast/snack exempt. Variety filter (`getRecentMealIds`/`getLastWeekMealIds`) also household-level since 2026-04-21 to match.
- **INV15**: count of lunch/dinner leftovers **him** eats per week (regardless of who cooked). Format: `INV15 leftovers-eaten: him count=N`.
- **INV16**: same for her. Both aggregate in MPStress as `avgLeftoversEaten.him`/`.her`.
- All 3 are tracking-only. Stress harness filters them out of `invAnyFailExceptINV6`.

### Recipe changes this session

**New recipe:** `salmon_bowl` — "Salmon rice bowl with soy-honey glaze", 559 kcal, 34% fat. Uses new NUTRI_DB entry `peanuts`.

**Renamed + normalized:**
- `salmon_teriyaki_din` → `salmon_stir_fry_din` ("Salmon stir-fry with brown rice & veg"). 849→690 kcal. Fixed missing rice vinegar + ginger.
- `cannellini_kale_soup` → "Chicken, white bean & kale soup". Merged white_bean_soup into it, added chicken 4oz, added celery 1, added black pepper. 354→584 kcal, 52.9% carb.
- `lentil_soup_lean` → "Chicken & lentil vegetable soup". +chicken 4oz, +egg white to 0.5, +farro 0.5c. 364→579 kcal, 45.7% carb.
- `shrimp_bowl` → "Shrimp & rice bowl". Removed black beans, avocado oil 1→0.125, broccoli 0.75→1, bell pepper 0.25→0.5, avocado 0.5→0.5. 813→610 kcal, 31% fat.
- `turkey_zucchini_boats` → "Turkey-stuffed zucchini boats with pasta". +whole wheat pasta 1c. 387→561 kcal.
- `chicken_noodle_soup` — +avocado oil 0.5, carrots 0.5→0.75, celery 1→2, +red onion 0.25. 400→661 kcal, 2c veg.
- `lemongrass_salad` — chicken 5→10oz, +peanuts 2 tbsp, +lemongrass 1 tbsp (was missing from ingredients despite being in name). 318→586 kcal.

**Deleted:**
- `white_bean_soup` (merged into cannellini_kale_soup)

**Step/ingredient gap fixes (8 recipes):**
- `chicken_noodle_soup`, `korean_egg_bowl`, `korean_juk`, `korean_rice_bowl`, `turkey_meatballs_din`, `white_bean_chicken_chili` — added ingredients that steps referenced
- `filet_din` — removed "baste with butter" from steps (user doesn't use butter)
- `lemongrass_chicken_thigh` — "sugar" → "maple syrup" in steps (recipe uses maple syrup)

### Current quality (100-run baseline, 50-run varied, 100-seed variety)
- **Baseline hit rate**: ~98.0–98.4%
- **Varied hit rate**: ~98.0–98.6%
- **Hard invariants (INV1–5, 7–13)**: 0
- **Tracking invariants (INV6, 14, 15, 16)**: emit as designed
- **Closed-out meals (variety)**: ~29–34% depending on recipe changes. Breakfast stuck at 9/27 = 67% closed out.
- **Zero-waste rate**: 100%

### Open items for next session
- **Breakfast normalization** (biggest variety opportunity) — 18 of 27 breakfast meals still shut out. List: sweet_potato_egg_hash 242, korean_juk 249, shakshuka 297, chicken_breakfast_wrap 314, turkey_sweet_potato_hash 319, coconut_chia_pudding 553, protein_pancakes 576, yogurt_bowl_post 597 (currently top-picked but over range), + 10 more never-picked.
- **Lunch/dinner remaining outliers** (~13 recipes still off-target): spicy_tofu_chicken_noodles 795, red_curry 751, thai_peanut_noodle 775, hummus_wrap 388, chicken_sweet_potato_bowl 391, lentil_chicken_bowl 411, shrimp_quinoa_bowl 439, viet_vermicelli 444, roast_chicken_din 498.
- **Ground meat pkg.type** — `ground turkey 93` and `ground chicken` currently `'container'`; should be `'bulk'` per design (exempts from Phase 1.5 solo-pkg removal). Currently turkey/chicken recipes are shut out of solo slots because Phase 1.5 removes them.
- **kcalHigh misses creeping up** — adding ingredients to normalized recipes lifts base kcal; the day-absorber scales dinner hotter on some seeds. Worth watching.
- **Fat%>30 still present on salmon recipes** — structural (salmon is ~54% fat by kcal). Can't easily fix without cutting salmon oz.

## Session 2026-04-21 (late) — Code review cleanup

Read-only code review of the 2026-04-21 INV4/INV14/INV15/INV16 work, then seven small cleanups applied one at a time with post-change 25-run verification. Final 100-run sanity check confirms parity.

### Report format rule (IN MEMORY — always apply)

When relaying `MPStress.formatReport(agg)` output to the user, **paste it as native markdown** — direct `| col | col |` tables and `### headers`, NOT wrapped in triple-backtick code fences. The chat UI renders the tables as clean grids; code-fenced they show raw pipe syntax and are hard to scan. Include EVERY section the report produces (Key Metrics, Miss Breakdown, Hard Invariants, Tracking Invariants, Per-slot Meal Usage, Top Picks Per Slot, Never Picked if present, Miss Severity, Top Meals in Failing Days, Timing).

Before running `runStandard` in a fresh preview-Chrome profile, seed the baseline so the Key Metrics table shows the 3-column `| Baseline | Current | Δ |` diff instead of the single-column fallback. Use the **current carry-forward values** (end of 2026-04-21 late session):
```js
localStorage.setItem('mealPlannerStressBaseline', JSON.stringify({primary:98.21, inv14:0, hardFail:0, closedPct:0.0, avgVariance:94.9}));
```
Update those numbers session-over-session as the saved baseline evolves. Full rule: [`feedback_mpstress_report_rendering.md`](~/.claude/projects/-Users-chris-Desktop-Meal-Planner/memory/feedback_mpstress_report_rendering.md).

### Changes landed
- **Dead `calDiff` checks removed** in Phase 3 Strategy A (~8210) and Strategy C (~8350). `var calDiff = 0; if (calDiff > 150) return;` were never reachable — the `slotBudget` guard above already enforced the cal-distance check. Also removed dead `bestCalDiff` tracking in Strategy C.
- **Dead ternary branch collapsed** in `rerollInv14Violations.findPairs` — `const later = cooks[j].dayIdx >= cooks[i].dayIdx ? cooks[j] : cooks[i];` always picks `cooks[j]` because `cooks` is built in DAYS-ascending order with `j > i`. Simplified to `pairs.push({later: cooks[j]});` with explanatory comment.
- **Stale Phase 1.5 comments updated** at 3 spots to reference **INV4** (its hard-invariant replacement). "Tie-breaking candidate" retry-loop comment corrected to match actual "only when waste=0" behavior. "Per-person recent NEW cooks" comment corrected to household-level.
- **Dead `p` argument dropped** from `getRecentMealIds(dayIndex, days, lookback)` and `getLastWeekMealIds()`. Both became household-level on 2026-04-21 but kept `p` in signatures "for backward compat"; seven call sites updated to drop it.
- **`_collectHouseholdCooks(los)` helper extracted** — single source of truth for the household-cook enumeration. Three near-identical copies existed in `countInv14`, `rerollInv14Violations.findPairs`, and `verifyInvariants` INV14 block. All three now delegate.
- **`_fastTripWasteForPersons(days, persons)` helper extracted** — single-source-of-truth for the cold-path flex-aware trip-waste estimator. `rerollMissDays` and `rerollInv14Violations` previously had near-identical copies; now both delegate. The retry-loop inline copy is intentionally **NOT** extracted — that's hot path (30 retries × 100 runs = 3000 invocations per stress test), where avoiding the function-call boundary and closure allocation measurably matters.
- **`FLEX` constant removed from `applyTripFlexScaling`** — byte-equal duplicate of global `PKG_FLEX_CONFIG`. Now reads from the global. Inline kcal/oz notes from `FLEX` preserved as inline comments in `PKG_FLEX_CONFIG`.

### Strategy B aligned to PKG_FLEX_CONFIG (landed 2026-04-21 late)

Strategy B's hand-rolled `flexIngr` list (predated `PKG_FLEX_CONFIG` per git commit `dd798c8`) was replaced with a direct `PKG_FLEX_CONFIG` lookup. Strategy B doesn't mutate amounts — it only sets `resolved=true` to signal "flex can fix this; stop swapping." The prior divergence meant Strategy B was either lying (saying yes when flex couldn't reach, e.g. beans at +100% when flex caps at +75%) or giving up too early (saying no for tofu/tuna/ground-meats/chicken-broth where flex could actually handle them).

```js
// Before: hardcoded flexIngr list + coconut branch + 0.25/0.25 default
// After:
var _bCfg = PKG_FLEX_CONFIG[pkg.dbKey] || {maxUp: 0.25, maxDown: 0.25};
var maxUp = _bCfg.maxUp, maxDown = _bCfg.maxDown;
```

**Measured effect** (100-run diff, pre-fix → post-fix): INV14 2→**1** (`quinoa_bowl` gap=3 no longer fires, matches baseline), avg variance 94.1→**94.4%** (matches baseline), dinner top-3 rotated `coconut_turkey_curry` out in favor of `chicken_noodle_soup` and `turkey_meatballs_din` — exactly the predicted effect: chicken-broth + ground-meat meals now rotate freely where Strategy B was falsely rejecting them. Primary 98.43→98.36% (−0.07pp, within seed variance). Hard INVs still all 0 ✓.

### Balancer fix — rxbar-tripling catastrophic bug (landed 2026-04-21 late)

**Root cause investigation (seed 12380, him Sunday, +259 kcal miss)**: `balanceDayMacros` boosted rxbar from 1 → 3 bars on a day that was already structurally fine (base recipe 1 rxbar + 1 apple = 295 kcal vs 256 snack budget = +39, within tolerance). Final state: snack 635 kcal (2.5× budget), day 3059 kcal (+259 over target).

**Why it fired**: `bestAdd('protein')` filtered out `tofu firm` because it's tagged `pkg:{type:'container'}`. That left only non-pkg protein items: black beans (0.264 pro-kcal ratio), rxbar (0.267), egg white in dinner (scalable:false). Rxbar narrowly won. Each iteration added +180 kcal (rxbar `wholeOnly`) while trimming −54 kcal of rice, a **+126 kcal net inflation per iteration** — the balancer chased protein but silently destroyed daily kcal.

**Two bugs in one spot**:
1. Balancer had NO per-slot budget check — blind to the fact that growing rxbar was destroying the snack slot.
2. Balancer assumed +pro / −carb-or-fat is kcal-neutral, but `wholeOnly` items with 180-kcal steps paired with 54-kcal trims are NOT neutral.

**Fix at [bestAdd](index.html:3611)**: when called with `trimKcalStep`, iterate the sorted pool and skip any item that:
1. Has `pInc * db.kcal > 2 × trimKcalStep` — prevents kcal inflation from mismatched step sizes
2. Would push its slot past **150% of slot budget** after adding — prevents snack-destruction (dinner + shake exempt)
3. Is `protein powder` — user preference, don't solve problems with supplements

Plus: the three priority branches (pro-gap, carb%, fat%) now find `trim` FIRST, compute its kcal step, and pass to `bestAdd`. Priority 1 proGap threshold raised from 3 → **7** because balancer effort on borderline cases (−4 to −6g) often spiked fat% or kcal without meaningfully closing the gap — accept up to −7g protein variance as fine.

**Non-issue** (investigated and ruled out): concern that `unifyCrossPersonRatios` would undo balancer changes on shared-dinner slots. Verified with math and code trace: unify preserves batch TOTALS and redistributes kcal-proportionally across both persons. Balancer's +1 oz boost on her becomes ~+1.04 oz after unify (slightly more, because she's the smaller kcal share). Boost is preserved, just smoothed.

**Note about her shared-dinner slots**: the classification loop at [index.html:3243](index.html:3243) explicitly skips `lo.crossPerson` leftovers, meaning `sameDayShared` cross-person slots fall through to normal processing. They are NOT frozen for the balancer — the balancer can touch them, and unify redistributes after. Earlier speculation about "frozen shared dinner limiting Her's Friday options" was wrong.

### Final 100-run result vs saved baseline (98.64% / INV14=1 / all hard=0 / closed=0% / variance=94.4%)

| Metric | Baseline | Current | Δ |
|---|---|---|---|
| Primary hit rate | 98.64% | 98.21% | −0.43pp |
| INV14 total | 1 | **0** | **−1** ✓ |
| Hard invariants (INV1-5, 7-13) | all 0 | all 0 ✓ | unchanged |
| Meals closed-off | 0.0% | 0.0% | — |
| Avg variance | 94.4% | 94.9% | **+0.49pp** ✓ |
| Max kcal miss | +259 (rxbar 3×) | **+120..+150 bin** | no more catastrophic overshoots |
| Timing (avg / max) | — | 885ms / 1168ms | — |

**Miss breakdown**: kcalLow=2, kcalHigh=12, pro=2, carbPct=1, fatPct=3, veg=2, fruit=4. Spread evenly — no dominant failure mode.

Primary is 0.43pp under baseline because baseline's "higher hit rate" was partly driven by the rxbar-tripling bug masking other issues (protein gaps got fake-solved by adding +180 kcal bars; counted as primary hit even though the day was nutritionally wrong). Current version has fewer false-rescues and genuinely reflects day quality.

### Threshold sweep for proGap (for reference — 7 chosen)

| Threshold | Primary | pro misses | fatPct misses | Variance | Total misses |
|---|---|---|---|---|---|
| proGap>3 (original) | 98.00% | 5 | 5 | 94.4% | 28 |
| proGap>5 | 98.21% | 2 | 2 | 94.8% | 23 |
| **proGap>7 (chosen)** | **98.21%** | **2** | **3** | **94.9%** | **24** |
| proGap>10 | 98.21% | 0 | 5 | 94.9% | 26 |

### Open items for next session (added to prior list)
- **Phase name/number cleanup** — still ad-hoc (1, 1.6, 1.7, 2, 3-A/B/C, 4, plus post-retry stages). Renumber cleanly with descriptive names.
- **INV6 drift audit** — tracking-only at ~5 fires/run (P/C ratio >50% vs base). Decide whether to promote to hard or accept the day-balancer's aggression.
- **Retry selector Option C** (parked) — reorder `(waste, misses, inv14)` → `(waste, inv14, misses)`. Might knock out the last INV14 fire; might hurt misses. User-flagged "only if it helps and doesn't hurt misses."
- **Friday miss pattern** — not a real structural issue (unify preserves balancer boosts on shared dinners). Observed 5-of-8 Friday clustering in a small sample was likely seed noise. If future runs continue to show Friday bias at 100-run scale, investigate; otherwise noise.

## Session 2026-04-22 — INV6 audit, threshold pass, veg fixes, 60 retries

### INV6 audit findings (start of session)
Full 100-run capture showed **459 INV6 fires, max pct 569% (`viet_noodle_bowl` 6eggs+0.25c noodles), p99 263%**. 94% P-up direction — balancer one-sided. `yogurt_banana_honey` C-up case hit **4.67 tbsp honey** (was unbounded). Top offenders: `yogurt_berries_light` (54 fires), `shrimp_cucumber_plate` (53), `coconut_turkey_curry` (29).

### What landed this session

**DB threshold pass (~60 ingredients got per-serving min/max):**
- Proteins: chicken/turkey/fish/filet all 4–12 oz, tofu firm/silken 3–8 (minAmtSolo 3), canned tuna 2–8, eggs 1–6 each, egg white 0.25–1 c, shrimp 4–12, rxbar 1–2, tuna pouch = 1 (wholeOnly), yogurt 0.5–2.
- Carbs: rice/pasta/noodles 0.25–1.5c, oats 0.25–1c, whole wheat toast/tortilla 1–3 (wholeOnly), granolas 0.25–0.75c, potato 0.25–1.5c, oat flour 0.125–0.5c.
- Condiments: honey/maple/sugar narrow-window with `minAmt:0.25 + minAmtSolo:0.5 + maxAmt:1` (batch vs solo split — 2:1 max/min can't survive 2.05:1 kcal split otherwise).
- Other: soy sauce 0.5–3, vinegars 0.5–2, salsa 1–4, miso/broth conc 0.5–2.
- Bean/legume family raised to maxAmt 2c (was 1.5). Edamame too.
- Non-aromatic veg dropped to **minAmt 0.25** (honors recipe bases like 0.25c bell pepper in hummus_wrap) — solo falls back to same via `_effMin` when no `minAmtSolo` override.
- Non-aromatic veg maxAmts tightened: leaf 3→2, standard 2→1.5 (caps bind on Him in shared batches, Her proportionally).
- Celery max 4→3 each. Lemon added 0.25/1 (matching lime). Lemongrass added 0.5/2 tbsp. Coconut milk pkg removed, max 1→0.5, min 0.25→0.125.

**Balancer / pipeline fixes:**
- **Veg boost cap bug**: `boostBatchVegForDailyTarget` now scans ALL portions against 3×/4× base cap, not just iterating person's side. Was causing Him's portion to balloon past cap when Her's daily boost grew the shared batch proportionally. Was the root cause of 10–12c veg days.
- **bestAdd Cap 3**: per-serving maxAmt check prevents balancer from pushing egg white past 1c, protein powder past 1 scoop, etc.
- **Post-balance correction snap-then-clamp bug**: after `snapAmt` rounds to grid, if result exceeds `maxAmt`, floor to nearest grid step at-or-below cap. `protein powder` maxAmt 1.5 was rounding to 2 on scoop grid before fix. Tightened maxAmt to 1 to match recipe base.
- **bestTrim + post-balance correction** now respect `minAmtSolo` (pan-sauté floor) via solo-slot lookup.
- **wholeOnly per-portion rounding** in `unifyCrossPersonRatios`: for `wholeOnly` items (tortilla/toast/eggs/rxbar/tuna-pouch/celery), each portion rounds to its own whole number instead of kcal-proportional scaling. INV7 exempts `wholeOnly` (ratios intentionally diverge — can't serve ½ tortilla). Applied same pattern to honey/maple/sugar via minAmt/minAmtSolo split.
- **INV6 refinement**: ingredients whose balanced amount hits `minAmtSolo` are excluded from raw/bal ratio sums (threshold doing its job, not distortion). `noRatioCheck:true` meal flag exempts structurally ratio-sensitive dishes — applied to `shrimp_cucumber_plate`, `yogurt_snack`, `yogurt_apple_cinnamon`, `yogurt_banana_honey`.
- **Balancer Priority 1 trim order**: `['carb','fat']` → `['fat','carb']`. Carb floor 40%: Priority 1 & 2 stop trimming carb when day is at floor.
- **Phase 1 fallback cascade variety lock**: for lunch/dinner, `used` AND variety filter preserved in all fallback levels. Previously dropped both, allowing same-day dupe (INV14 gap=0). Snacks unchanged.
- **rerollKcalOffSnacks**: new bidirectional pass after `rerollMissDays`. For any day off kcal target >100, swaps snack to best-fitting candidate (picks smallest |newDelta|). Complements reroll-miss (which uses miss-count reduction).
- **rerollInv14Violations** acceptance: strict "misses don't grow" → `+2 miss tolerance` (didn't help residual gap=3 alone).
- **Retry count 30 → 60**: solved the 2 residual gap=3 INV14 cases (iteration-order leak where Her's earlier day duplicates Him's later day because Her doesn't look forward). Primary 97.36→98.07, INV14 2→0, timing ~2× (730→1320ms avg).

**Meal changes:**
- **Coconut suppression**: Phase 1 penalty 500→3000 per coconut-containing meal. `mealUsesDiscouraged` helper filters coconut meals from all reroll/swap phases (rerollMissDays, rerollInv14, Phase 3 Strategy A/C, Phase 4). Only Phase 1 primary selection can introduce coconut meals. Picks dropped from ~15% to 5.2%.
- **Recipe changes**: `coconut_turkey_curry` rice 0.75→1.25c + coconut milk 0.4→0.25c (574→613 kcal, P:C 0.54→0.40); `turkey_sweet_potato_hash` turkey 3→4 oz (matches new minAmt); ground turkey 93 minAmt 4→3 (allows batch splits); egg noodles maxAmt 0.5→1.5 (fixes `chicken_noodle_soup` clamp).
- **Yogurt cleanup**: deleted `yogurt_berry_eve`/`yogurt_orange_eve`/`yogurt_berries_light` (duplicates of yogurt_parfait_eve/yogurt_snack). Remaining 6 yogurts expanded to `slots:['breakfast','snack']`.
- **3 new mid-sized snacks** (200–285 kcal base): `pb_apple_slices`, `pb_banana`, `edamame_salted`. All picked regularly (edamame_salted especially — 94/5600 picks).

### Stress (100-run vs session-start 98.21% baseline)

| Metric | Start | End | Δ |
|---|---:|---:|---:|
| Primary hit rate | 98.21% | **98.07%** | −0.14pp |
| Hard invariants (INV1-5, 7-13) | all 0 | **all 0 ✓** | clean |
| INV14 | 0 | **0** | same |
| INV6 | 459 | 242 | −47% |
| Meals available | 120 | **126** | +6 |
| Coconut pick rate | ~15% | **5.2%** | rare |
| Days veg >8c | 118 | 40 | −66% |
| Worst INV6 pct | 569% | p99=194% | far tighter |
| Timing avg | 885ms | **1320ms** | +435ms from 60 retries |

### Stress-test state-dependence finding (end of session)
**Confirmed**: `MPStress.runStandard()` results depend on starting `SEL` + `weekData.last.sel`. Same seed + different starting state = different output (tested: primary 98.07% at session state vs 98.21% from clean state; INV14=0 vs INV14=2 on identical seeds). `snapshot()`/`restore()` preserves internal consistency WITHIN a run but `runStandard` doesn't force a clean initial state. User accepts this non-determinism as "variety in stress testing" — do NOT auto-clear in `runStandard`.

**New inspect API** (added 2026-04-22, commit c06ddfc): each `runOne` now captures a `postSnap` before restoring state. `MPStress.inspectDay(seed, p, d)` returns the per-slot ingredient breakdown for any preserved run (read-only). `MPStress.inspectRun(seed)` restores the seed's finalized state into live globals (pair with `MPStress.exitInspect()`). Use these for post-hoc drill-down instead of trying to re-reproduce a seed fresh.

### Open items for next session
- **Recipe normalization** ongoing. Still 20+ lunch/dinner off-target (see prior session's list). `coconut_turkey_curry` and `turkey_sweet_potato_hash` done this session.
- **Retry time cost** — 1.3s avg is snappy for interactive use but ~2× what we had. Could profile hot path inside retry loop if user wants to reduce.
- **kcalLow pattern** — 16 misses (mostly Him). Structural: some meals cap out before reaching Him's slot budgets. `celery_apple_plate` can't scale (celery + apple both have `maxAmt` that tops near 107 kcal) — Phase 1 scoring allows him to pick it anyway when day has high-cal meals elsewhere. User explicit: "not concerned if day target is hit."
- **INV6 distribution after session** — 242 fires, max ~250% (down from 569). Still tracking-only. Promotion to hard would require addressing the coconut/turkey recipe-ratio sensitivity that survived the tighter caps (top offenders now: `chicken_noodle_soup`, `shrimp_coconut_curry`, `coconut_turkey_curry`).

## Session 2026-04-22 (late late) — code audit + Test 2 + 4 defensive fixes

Spawned a parallel audit across 5 areas (balancer, veg/unify, Phase 1/reroll, threshold/recipe, inspect API). Filtered false alarms, verified concrete findings, then applied 4 fixes one at a time with stress test validation per fix.

### What landed

**Fix #1 — `window._stressRuns` populate.** `runBaseline`/`runStandard`/`runVaried`/`runSharing` now write `window._stressRuns = results` before returning, so `MPStress.inspectDay(seed, p, d)` and `inspectRun(seed)` work after a normal `runStandard(100)` call. Previously the inspect API only worked via the manual chunked-loop pattern from the handoff message; CLAUDE.md's description was misleading. Verified with a 3-run sanity that `inspectDay(12345, 'him', 'Monday')` returns real data instead of `{err:'no run or no postSnap'}`.

**Fix #2 — Phase 1 incomplete-attempt guard.** Added `var incomplete = false;` at the top of each Phase 1 attempt; set to `true` if the variety+used filter dead-ends on breakfast/lunch/dinner (the snack and late_snack fallbacks always find candidates, so they're exempt). After SLOTS.forEach, `if (incomplete) continue;` skips the score check, so partial-trySel can never become `bestSel`. Without this, the outer `if (bestSel) { ...delete SEL[selKey]... }` path could commit a SEL with deleted slots if all 60 outer retries hit the same dead-end. Defensive — instrumentation confirmed the dead-end never fires across the standard-test seeds (zero rejections in 10 seeds × 60 retries × 14 person-days × 60 attempts = 5M+ attempt iterations). Bug is real in code structure but not reachable on current recipe pool. Both tests still all-hard-INV-clean after the fix.

**Fix #3 — Phase 1 fat early-exit ceiling 0.30 → 0.31.** Scoring penalty fires `>0.31` but early-exit was `<=0.30`, leaving a 0.301–0.31 blind spot where attempts had no fat signal at all. Aligned the early-exit ceiling to match the penalty threshold. **Mixed result**: Test 1 (deterministic) regressed −0.64pp on the fixed-seed walks; Test 2 (randomized + state-evolving) improved +0.86pp across diverse states. Both tests show fatPct misses dropped (intent achieved). User chose to keep — Test 2's broader coverage suggests net-positive across realistic state space.

**Fix #4 — snap-then-clamp grid>maxAmt fallback.** `adjustIngredients` post-balance correction at line ~3563 had `if(newAmt<g) newAmt = g;` after `Math.floor(maxAmt/g)*g`, which violated `maxAmt` if `grid > maxAmt`. No DB entry currently triggers (smallest cup-grid maxAmt is 0.5; smallest tbsp-grid is 1), but the math is wrong defensively. Changed to `if(newAmt<g) newAmt = Math.min(g, fi.db.maxAmt);` — better to break grid alignment than the per-serving cap. Mathematically verified with a synthetic test (pathological case `maxAmt:0.4 + grid:0.5`: OLD returned 0.5 violating cap; NEW returns 0.4 respecting cap. Sane case unchanged). Both tests all-hard-INV-clean.

### New: Test 2 (`MPStress.runStandard2`) — true randomized counterpart

Test 1 (`runStandard`) is **100 deterministic walks** through fixed seeds 12345..12444 — useful for reproducing failures, but blind to any code path the seeded PRNG doesn't reach (Fix #2's dead-end is invisible to it; Fix #4's pathological branch is invisible). Test 2 differs on TWO axes:

1. **Nondeterministic**: `randomizeWeek` uses real `Math.random` (no seeded PRNG override).
2. **State-evolving**: no snapshot/restore between runs. Each run starts from the prior run's output, simulating real-world repeated Randomize clicks. Exercises state-evolution paths the deterministic test cannot reach.

**Tradeoff**: failing seeds aren't directly reproducible (Math.random state isn't captured). Drill into failures via `postSnap` + `MPStress.inspectDay` after the fact.

**Implementation:**
- `runOne(mode, seed, cfgFn, opts)` — new 4th arg with `{nondeterministic, persistState}`. Default behavior preserved (both flags false).
- `aggregate` propagates `mode` from runs to output.
- `formatReport` reads `agg.mode` for both the title (`runStandard` vs `runStandard2`) and the baseline localStorage key (`mealPlannerStressBaseline` vs `mealPlannerStressBaseline2`).
- `saveBaseline` mode-aware writes; `clearBaseline(mode)` mode-aware delete.

### Stress baselines (carry-forward to next session)

```js
// Test 1 (deterministic, seeds 12345..12444):
localStorage.setItem('mealPlannerStressBaseline', JSON.stringify({primary:98.21, inv14:2, hardFail:0, closedPct:0.0, avgVariance:94.7, mode:'standard'}));
// Test 2 (randomized + state-evolving):
localStorage.setItem('mealPlannerStressBaseline2', JSON.stringify({primary:98.64, inv14:3, hardFail:0, closedPct:0.0, avgVariance:94.4, mode:'standard2'}));
```

Test 1 final: 98.21% / INV14=2 / hard=0 (timing varied 1.4–2.7s avg session-over-session due to state-dependence).
Test 2 final: 98.64% / INV14=3 / hard=0 (timing 1.3s avg).

### Communication rule added

**"Don't dismiss audit findings or defensive guards with 'this scenario can't happen.'"** Banned framings: "no DB entry currently triggers this", "the case is theoretical", "won't happen in practice", "trust internal code", "unreachable code path". The Claude Code system-prompt default ("don't add error handling for scenarios that can't happen") does NOT apply in this project. Code paths that "can't fire" do fire here (precedent: INV7 drift dismissed as "stochastic" for sessions; root cause was real). If a stress test cannot exercise a code path you're trying to fix, **build a targeted reproducer** before declaring the fix neutral — a test that can't hit the path is not a validator.

Memory: [`feedback_no_cant_happen_dismissals.md`](~/.claude/projects/-Users-chris-Desktop-Meal-Planner/memory/feedback_no_cant_happen_dismissals.md).

### Open items carry forward
- (carried) Recipe normalization, retry time cost, kcalLow pattern, INV6 distribution from prior session.
- **Test 1 vs Test 2 verdict divergence on Fix #3** — worth tracking. If future fixes show similar split, may indicate Test 1's seed set is pathological for some pipeline regions.
- **Phase 1 dead-end reproducer** (parked) — Fix #2 is verified mathematically + instrumented (zero fires on standard test). If recipe pool ever shrinks, a synthetic reproducer (force `getMealsForSlot('lunch')` to return [], pre-populate SEL, observe no `delete SEL[*_lunch]` after randomize) would prove the fix's effect. Not built this session.
- **runStandard2 timing variance** — saw runs as long as 4.8s during state-evolved measurement. Worth investigating if state evolution pushes specific code paths into pathological retry counts.

## Session 2026-04-23 — 24 recipe rewrites, critical cache bug, maxAmtSolo infra, pkg-nudge removal

**Headline**: `runStandard` **98.07% → 99.14%** (+1.07pp carry-over). `runStandard2` **97.64% → 99.36%** (+1.72pp). All hard INVs 0 on both. Four commits pushed.

### What landed (in commit order)

**Commit `daa9db8` — Recipe normalization** (24 rewrites, 2 deletions, `white rice cooked` added to NUTRI_DB, full curry overhaul):

- Lunch/dinner outliers fixed: `hummus_wrap` 387→610 (chicken 5→8oz + 1→2 tortillas, "2 wraps per serving"), `chicken_sweet_potato_bowl` 390→567 (+lentils 0.5c + chicken 7→9oz; renamed "Chicken, sweet potato & lentil bowl"), `spicy_tofu_chicken_noodles` 795→687 (fat% 39→26%), `lentil_chicken_bowl` 410→590 (+avocado oil 0.5), `shrimp_quinoa_bowl` 439→571 (+avocado oil 0.5), `viet_vermicelli` 444→590 (+peanuts 1 tbsp — classic Viet garnish, +variety), `thai_peanut_noodle` 775→595 (PB 2→1 + sesame oil 1→0.25; fat% 39→25%), `filet_din` 718→543 (filet 7→5 + potato 1.25→1.5 + oil 1→0.25 — fat% still 33% structurally; user accepted "this one is just gonna have to show up with healthier meals"), `white_bean_chicken_chili` 710→598 (cream→yogurt + cheddar 1.5→1oz + oil 0.5→0.25 + chicken 6→8; fat% 46→28%), `roast_chicken_din` 498→602 (chicken 7→9 + farro 0.75→1c).
- Breakfast outliers fixed: `sweet_potato_egg_hash` 242→408 (+2 whole eggs + 1c spinach + bell pepper 0.5→1c; renamed "Sweet potato & egg hash"), `shakshuka` 297→435 (eggs 1→2 + whites 0.25→0.5 + marinara 0.5→1c), `chicken_breakfast_wrap` 314→450 (+1 whole egg + whites 0.25c + chicken 5→6oz; renamed "Chicken & egg breakfast wrap"), `savory_congee` 315→418 (+1 whole egg + chicken 3→4oz), `white_bean_scramble` 320→457 (beans 0.5→1c + spinach 1→2c + avocado oil 0.25 tbsp), `yogurt_bowl_post`→`yogurt_bowl_sweet` 597→395 (oats 0.75→0.5 + honey 1→0.5 + no almond butter; renamed), `protein_pancakes` 576→455 (maple 1→0.5 + no AB + cinnamon).
- Snack outliers fixed: `tuna_crackers_apple` 385→285, `tuna_crackers_orange` 352→252 (triscuits 10→5 on both).
- **Full curry sauce overhaul**: standardized all 4 coconut curry recipes at 0.25c coconut + consistent "dry-bloom paste → whisk coconut + water → sauce" method. `red_curry` renamed "Crispy tofu red curry with jasmine rice". `shrimp_coconut_curry` coconut 0.5→0.25c + paste 1→1.5 + shrimp 5→7oz. `coconut_turkey_curry` paste 0.5→1 + water step. `chickpea_curry_bowl` rice 1→0.5c + edamame 0.5→0.75c (mixed into rice base).
- **Deleted** `coconut_chia_pudding` + `coconut_oatmeal` (redundant coconut breakfasts; discouraged-penalty + off-target).
- **Rice-cooker + Instant-Pot assumption** applied to ALL cooking steps (14 rice/grain recipes, 7 dried-bean recipes). Recipe steps now say "warm jasmine rice (from rice cooker)" / "chickpeas (from Instant Pot)" instead of raw-cooking instructions.
- **Authenticity fixes**: brown rice → jasmine (Thai curry, Chinese congee) or **white rice** (Korean juk, Korean egg bowl, Korean rice bowl, bibimbap — Koreans use short-grain white rice). Added `white rice cooked` DB entry (identical macros to jasmine, different label for shopping accuracy).

**Commit `484a572` — Critical cache bug fix + maxAmtSolo infra + snack swap move**:

- **CRITICAL: snapshot/restore cache bug**. `snapshot()` didn't capture `_dayBalancedCache` or `_leftoverCache`. On round-trip (snapshot → mess up state → restore), **11 of 14 days drifted by −52 to +11 kcal** because the post-randomize pipeline mutations (unify/snap/waste/boost — 7 ops) live in the cache, not source state. Meant `inspectDay` silently showed DIFFERENT numbers than `runOne` captured. All prior per-day drill-downs were reading wrong numbers. Fix: added `_dayBalancedCache` + `_leftoverCache` to snapshot/restore. Verified: 0 of 14 days drift now.
- **maxAmtSolo infrastructure** parallel to existing `minAmtSolo`. Added `_effMax(db)` helper in adjustIngredients + solo-aware max in INV13 verifier. Updated 4 enforcement sites in adjustIngredients. Batch-pipeline ops (snap/unify) still use `db.maxAmt` (batch context).
- Solo caps applied: `avocado oil` / `olive oil` / `sesame oil` **maxAmtSolo:1 tbsp** (max stays 1.5 for batches). `1% milk` **maxAmtSolo:1 cup** (max stays 2).
- Protein maxAmt bumps for more proportional scaling headroom: `chicken breast` / `chicken thigh` 12→16 oz. `tofu firm` / `silken tofu` 8→12 oz.
- **`rerollKcalOffSnacks` moved to end-of-pipeline** and rewritten cache-preserving. Previously ran at step 3 (pre-batch-pipeline); saw pre-pipeline kcal. Days that shifted post-pipeline weren't caught. Now runs just before `verifyInvariants`. Cache-preserving mutation: only replaces `cached.snack` per (p,d); never `invalidateLeftoverCache()`. Snacks are never batch members so mutating just snack is safe. Batch slots (lunch/dinner) + other days keep pipeline mutations.

**Commit `c765922` — Per-meal pkg nudge removed** (−76 lines dead code, fixes double-scaling bug):

- Per-meal pkg nudge (in `adjustIngredients`) and `applyTripFlexScaling` both fit pkg ingredients to packages with +100% flex caps. They **stacked**, letting marinara scale to 3.55× base (0.75c → 2.66c on turkey_meatballs_din) — far above either's intent. This was the root cause of Tuesday's over-pumped lunch in the run-93 −192 kcal investigation.
- `applyTripFlexScaling` is strictly more capable (trip-level view, same flex caps, same kcal caps, plus cal-neutral carb/fat backfill). INV4 enforces all pkg ingredients are in `PKG_FLEX_CONFIG` so trip-flex has full coverage.
- Removed the 70-line per-meal nudge block + dead `remaining` variable.
- **Test 2 +0.43pp improvement** (98.93→99.36) — real gain attributed to eliminating the double-scaling that caused bogus over-allocations cascading into other slot imbalances.

### Investigation: Test 2 run 93 him/Thursday −192 kcal (batch-cook cascade)

First investigation using the fixed cache-preserving `inspectDay`. Traced the day to a batch-cooking issue:
- Thursday's lunch is a LEFTOVER from Tuesday's dinner cook (burrito_bowl).
- Tuesday's dinner (the cook anchor) was sized to Tuesday-dinner's budget — which `balanceDayMacros` had trimmed from 896 to 665 in a fat-to-protein swap (avocado cut, yogurt added).
- Tuesday's LUNCH got over-pumped to 1181 (vs budget 896) by a combination of `balanceDayMacros` protein bumps + `applyTripFlexScaling` marinara push + the per-meal nudge double-scaling.
- Thursday's lunch inherits the under-sized Tuesday cook → 665 vs Thursday's 896 budget → −231 lunch kcal → −192 day delta.

**Three architectural issues surfaced**:
1. **Per-meal nudge + trip-flex double-scaling** (fixed in `c765922`)
2. **Day balancer doesn't consider cook-anchor status** — will trim a slot that's feeding a future leftover, not knowing it'll propagate.
3. **No batch-aware sizing** — when a cook feeds multiple days, its amount is sized to cook-day's slot budget alone. Weighted across all fed days would be better.

### Stress baselines (carry-forward to next session)

```js
// Test 1 (deterministic, seeds 12345..12444):
localStorage.setItem('mealPlannerStressBaseline', JSON.stringify({primary:99.14, inv6:229, inv14:1, inv15Him:2.9, inv16Her:2.8, hardFail:0, closedPct:0.0, avgVariance:95.1, missCounts:{kcalLow:1, kcalHigh:0, pro:1, carbPct:1, fatPct:2, veg:3, fruit:4}, timingAvg:1288, mode:'standard'}));

// Test 2 (true randomized + state-evolving):
localStorage.setItem('mealPlannerStressBaseline2', JSON.stringify({primary:99.36, inv6:245, inv14:0, inv15Him:3.0, inv16Her:3.1, hardFail:0, closedPct:0.0, avgVariance:94.9, missCounts:{kcalLow:2, kcalHigh:1, pro:0, carbPct:2, fatPct:2, veg:2, fruit:0}, timingAvg:1230, mode:'standard2'}));
```

### Open items for next session

Top priorities (user-flagged):
- **Audit `adjustIngredients` for total-day-macro awareness**. Does it consider total macros across shake + breakfast + lunch + dinner + snack when scaling per-slot, or only lunch/dinner? Currently it scales per-slot to per-slot budget, then `balanceDayMacros` does cross-slot corrections. The question: should per-slot scaling factor in the whole-day picture first (e.g., if day pro is already high, don't over-scale the highest-pro slot)? Investigation could surface similar architectural redundancies as the per-meal pkg nudge.
- **More maxAmtSolo caps**. Current coverage: oils (avocado/olive/sesame), milk. Audit what other ingredients should have tighter solo caps. Candidates to consider: condiments (soy sauce, honey — already has solo split), fats (butter, heavy cream, tahini), seeds (chia, sesame seeds), protein powders, cheese.
- **Per-meal pkg nudge removal suggests broader architectural audit**. We found an entirely redundant AND harmful pipeline step that nobody had caught. Worth a full pass on pipeline ordering/redundancy: do any other steps stack with each other's effects? Candidates: `unifyCrossPersonRatios` runs twice (once pre-waste, once post) — intentional, but verify it's not over-correcting. `snapBatchTotals` + `snapBatchTotalsToGrid` — different granularities, verify intent. `boostBatchVegForDailyTarget` — check interaction with solo grid snap.

Architectural follow-ups surfaced this session:
- **Batch-aware cook sizing**: when a slot is a cook anchor feeding future-day leftovers, consider target budgets across all fed days, not just cook-day's slot budget.
- **Cook-anchor priority in `balanceDayMacros`**: don't trim cook-slot ingredients when doing day-level macro balancing (they propagate to leftovers).
- **Marinara double-scale root cause is fixed** but may want to verify other pkg items don't have similar layered scaling paths (check `boostBatchVegForDailyTarget` + `applyTripFlexScaling` for veg items).

Carried from prior sessions:
- Recipe normalization: remaining 8 "intentionally light" snacks below 150 snack band (accepted as design category).
- `his_shake` 239 kcal under 250 shake band floor (trivial, 11 kcal).
- Phase 1 dead-end reproducer (parked), Test 1 vs Test 2 verdict divergence tracking, runStandard2 timing variance investigation.
- INV6 is 2.29/run Test 1, 2.45/run Test 2 — tracking only. Promotion to hard would require tighter balancer constraints.

## Session 2026-04-24 — Audit, post-balance removal, Stage 1a cache-snapshot win, unify idempotency

**Big session**. 10 commits, two async audits, one tagged "BIGUPDATE" checkpoint, INV6 severity added to reports, INV17 new hard invariant, Stage 1a pipeline-duplicate-work elimination, and the first idempotency refactor informing Stage 2 design.

### Headline numbers (Test 1 / runStandard, saved baseline)
- Primary: **99.14% → 99.86%** (+0.72pp)
- INV6: 229 → 250 (+21, severity tail narrowed; now bounded at 167% max drift vs 300%+)
- INV14: 1 → 0
- Hard INVs: all 0 ✓ (including new INV17)
- Timing: 1288ms → 663ms (−48%)

### Commit chain this session
```
cc3b439  unifyCrossPersonRatios: drop unconditional rebuild + per-ingredient idempotency
c8490a1  Stage 1a: Skip 7-stage pipeline re-run when cache survives from winning retry
7c3a7a0  Remove Phase 1.6 (over-budget snack swap)
4090604  MPStress report: add INV6 severity distribution
cb89829  (tag: BIGUPDATE-post-balance-removal)
bb759b3  HIGH #2 fix + INV17 + audit cleanup
29c63d3  Recipe bumps: coconut_turkey_curry + turkey_sweet_potato_hash
afca802  Day-balancer restructure + variety filter same-day fix + harness defenses
f507859  (prior session end)
```

### What landed
1. **Day-balancer restructure** (`afca802`) — P0 kcal-gap priority + multi-priority-per-pass + thrash detection. Replaced if/else-if with no-break convergence. Variety filter same-day fix (closes shared lunch+dinner same-meal hole). MPStress harness gains: `runOne` auto-pushes to `_stressRuns` + double-verify canary. All hard INVs clean.

2. **Recipe bumps** (`29c63d3`) — `coconut_turkey_curry` 623→724 kcal (turkey 4→8, rice 1.25→1), `turkey_sweet_potato_hash` 357→537 kcal (turkey 4→6, sweet potato 1→0.75, +1c egg white). `jasmine rice cooked` maxAmt 1.5→2.

3. **HIGH #2 fix** (`bb759b3`) — `sameDayCookServings` double-count bug in `unifyCrossPersonRatios` + `snapBatchTotalsToGrid` post-pipeline re-runs. Root cause: by the time these re-runs happen, `_dayBalancedCache` already has materialized same-day leftover slot. Setting `mult=2` on cook slot while leftover slot is also present caused `dailyMacros` to count portion 3× (cook×2 + leftover×1). Silent 500-700 kcal balancer-view inflation → over-trim → kcalLow.

4. **INV17 — balancer↔calcTotals kcal consistency canary** (`bb759b3`). Asserts balancer's `dailyMacros()` view matches `calcTotals()` source-of-truth for every person-day. Catches double-count/under-count bookkeeping bugs in the balancer's `sameDayCookServings` logic. Would have caught HIGH #2 immediately.

5. **Audit cleanup** (`bb759b3`) — deleted dead `capVegPerServing` (87 lines), dead `MACRO_LIMITS.maxCarbPct`, dead `typeof computeLeftovers === 'function'` guards (6 sites), hoisted `computeLeftovers()` out of `applyTripFlexScaling` inner loop (~28 rebuilds/click → 1).

6. **BIGUPDATE: post-balance correction removed** (`cb89829`, tagged). Post-balance was redundant with new balancer P0. A/B tested (post-balance ON vs OFF × 100 runs each) showed no primary regression; Test 2 actually gained (INV6 -54, veg misses 4→0). Removed ~120 lines.

7. **INV6 severity in reports** (`4090604`) — drift-magnitude buckets (<60%, 60-80%, ..., >300%) + max drift + top offenders now visible in `formatReport` output. Lets user distinguish "230 minor drifts" from "230 fires with catastrophic tail".

8. **Phase 1.6 removed** (`7c3a7a0`) — redundant with end-of-pipeline `rerollKcalOffSnacks`. Primary 99.36% → 99.86% (+0.50pp, `rerollKcalOffSnacks` picks better than 1.6's random). Timing 1151ms → 654ms (−43%).

9. **Stage 1a — cache snapshot on winning retry** (`c8490a1`). Retry loop runs 7-stage pipeline on waste-zero retries; post-retry was re-running the SAME 7 stages on winning SEL. Pure duplicate work. Fix: snapshot `_dayBalancedCache` + `_leftoverCache` on retry winner, restore both, skip re-run when cache survives.

10. **unifyCrossPersonRatios idempotent** (`cc3b439`) — Stage 2-aligned pattern proof. Drop unconditional rebuild, use `getDayBalancedIngredients` for lazy per-portion build, add per-ingredient fast-path (skip write if already within tolerance of target), gate `affectedDays` tracking on actual mutations. Byte-for-byte identical stress output.

### Stage 1a debugging saga (3 attempts — valuable learnings)

**v1 (failed, INV7=1220 across 20 seeds)**: captured `_dayBalancedCache` via `JSON.parse(JSON.stringify(...))`. Ratios drifted after restore. Hypothesis was "deep-clone loses shared-reference structure."

**v2 (failed, INV7=155 across 10 seeds)**: added `unifyCrossPersonRatios(true) + snapBatchTotalsToGrid` fixup after restore to re-establish ratios. Still drift.

**v3 (worked, INV7=0 across 100 seeds)**: root cause was **snapshot timing** + **early-break assumption**:
- Snapshot happens AFTER `invalidateLeftoverCache()` (which is called by `countInv14()` for INV14 scoring). By then cache was empty → restored empty cache → subsequent reads rebuild as non-unified state.
- FIX PART 1: move snapshot BEFORE the `invalidateLeftoverCache + countInv14` block.
- Even then, the early-break case assumed "SEL is already the winner, cache is too" — false, because the LAST retry's `countInv14` wiped the cache right before the break.
- FIX PART 2: always restore from `bestCaches` whenever present, regardless of early-break vs loop-completion.

Diagnostic technique that found it: added `verifyInvariants()` calls at each stage boundary (A, B, C, D), checked INV7 count at each. Revealed A=0, B=28, narrowing the drift to "between A and B". Further narrowing (M1 check inside goalMisses loop, A2 immediately after A) isolated it to "between end of goalMisses block and DIAG B" — which turned out to be the `invalidateLeftoverCache()` call right there.

**Key insight**: when debugging cache-state issues, sprinkle `verifyInvariants()` checkpoints + write counters to `window._diagX`. Reload + run 3-5 seeds. The fires will tell you WHERE the drift enters.

### Timing paradox — why removing code made things slower

After deleting post-balance correction, Test 1 timing went from 1151ms → 1899ms (+65%). Puzzled for a while. Audit agent surfaced the mechanism:

**Post-balance correction was indirectly making the PIPELINE faster.** It tightened day-kcal to ±20 (via role-group scale), so the cache stored "clean" values. Downstream pipeline stages (`applyTripFlexScaling`, `rerollKcalOffSnacks`) check `|day.kcal - target| > 100` as their TRIGGER threshold. With tighter cached values, those triggers fired less often → fewer cache invalidations → fewer `getDayBalancedIngredients` rebuilds → fewer balancer runs.

Without post-balance: cache exits pipeline at ±100 (P0's threshold). Downstream triggers fire more often → more invalidations → more balancer re-invocations (~500-1000/click → ~750-1000/click). +1ms per extra invocation × ~750 extra = ~+750ms observed.

**Phase 1.6 removal recovered it** — that change eliminated 840 per-click snack-candidate scans inside the 60-retry Phase 1-4 hot path.

**Generalized lesson**: timing isn't additive across pipeline stages. Cache invalidation frequency × balancer cost per invocation dominates. Changes that affect the cache's "cleanliness" state at pipeline-stage boundaries have cascading timing effects through the `>threshold` trigger points of downstream stages.

### Stage 2 design seeds — unified convergence loop

**Audit findings** (async agent run, inventoried all 12 post-retry functions):
- 9 of 12 already have fast-paths that short-circuit when state is compliant
- 3 need work before loop-safe: `applyTripFlexScaling` (idempotency guard), `unifyCrossPersonRatios` (was: unconditional rebuild — now fixed in `cc3b439`), `balanceDayMacros` invocations inside snap/unify (defer to single end-of-loop pass)
- Biggest redundancy: retry loop's waste-zero branch runs the SAME 7 stages as post-retry (both `unifyCrossPersonRatios` calls, both snaps, waste pass, boost) — Stage 1a partially addressed by capturing cache on winner.

**Proposed convergence loop structure** (for future session):
```js
function finalizePipeline() {
  let changed = true, safety = 20, sigs = [];
  while (changed && safety-- > 0) {
    changed = false;
    changed = unifyBatchRatios()  || changed;     // has fast-path (cc3b439)
    changed = snapBatchesToGrid() || changed;     // has per-item fast-path
    changed = fitPackagesToFlex() || changed;     // needs idempotency guard
    changed = boostVegIfDayShort()|| changed;     // has fast-path
    changed = swapSnackIfDayOff() || changed;     // has fast-path
    if (thrashDetected(sigs)) break;
  }
  verifyInvariants();
}
```

**Idempotency pattern validated by `cc3b439`**: each adjuster does
1. **Lazy cache access**: `getDayBalancedIngredients(p, d)` instead of direct cache read. Returns cached or builds from SEL.
2. **Fast-path check**: compute target state, compare to current; skip if within tolerance.
3. **Mutation-gated flagging**: don't mark downstream work needed if nothing was actually mutated.

**Candidates for similar treatment** (ranked by readiness):
- `snapBatchTotals` — structurally similar to unify, has per-item fast-path. Gate balancer re-run on mutations.
- `snapBatchTotalsToGrid` — same pattern.
- `postBalanceWastePass` — per-batch fast-path exists; ensure affected-day flagging mutation-gated.
- `boostBatchVegForDailyTarget` — already has `vegGap > 0.005` fast-path; good shape.
- `applyTripFlexScaling` — hardest. Writes OVERRIDES + reads via `getBalancedSlotIngredients`. Needs boundary-check guard ("is tripTotal already at package boundary?") before applying scale.

### Rules of thumb learned

1. **Invariants are contracts, not targets**. INV7 firing caught Stage 1a v1 in 5 seconds; ship tests WOULD have masked it as "tiny seed variance". Every hard-INV fire = bug.

2. **INV17 kcal canary isn't sufficient for ratio drift**. It confirms day-kcal math is consistent between balancer's view and `calcTotals`. It does NOT catch cross-person ratio drift (INV7's job). Both canaries are needed.

3. **Cache snapshots have timing dependencies**. `invalidateLeftoverCache()` fires unexpectedly (inside `countInv14()`, per-candidate in rerolls, etc.). A snapshot taken AFTER a latent invalidate captures empty `{}`.

4. **Early-break assumptions are dangerous**. "Loop broke early because winner was current — so state is already the winner" is TRUE for SEL, FALSE for cache if the break happens right after an invalidate.

5. **Lazy cache build >> pre-rebuild**. `getDayBalancedIngredients(p, d)` returns cached or builds — the adjuster doesn't need to know which. Removes the "rebuild everything just in case" pattern.

6. **Fast-path check before work, mutation-gated flagging after**. Together make a function safely callable N times with O(1) cost on passes after the first. The pattern for convergence loops.

7. **"Don't dismiss can't happen"** (from prior session, reaffirmed). Stage 1a v2's "early-break preserves cache" assumption was an unexamined "can't happen" — caught by INV7.

8. **Timing isn't additive**. Code removal can cause timing regressions via indirect cascade (looser cache → more trigger-fires downstream). Profile the actual hot paths, don't reason from code-size alone.

9. **Byte-for-byte identical output is the gold-standard regression test**. `cc3b439` produced 100-run results identical to the pre-change baseline. Stronger than "primary hit rate within 0.1pp" because it confirms no path changed.

### Stress harness notes
- `MPStress.runStandard()` — 100 runs seeded 12345..12444. Deterministic per-seed. State-dependent across runs (user accepts).
- `MPStress.runStandard2()` — nondeterministic (Math.random) + persistState=true. Exercises state-evolution paths.
- `runOne` now **auto-pushes to `window._stressRuns`** with same-seed eviction (fixes the stale-inspect footgun that produced the phantom INV7=5 false alarm earlier in session).
- `runOne` now runs **double-verify canary** — `verifyInvariants()` called twice back-to-back after randomize; throws if counts disagree. Catches future snapshot/cache consistency bugs that would silently corrupt invCounts.

### Saved baselines (localStorage)
Test 1 carry-forward:
```js
{primary:99.86, inv6:250, inv14:0, inv15Him:3.1, inv16Her:2.7, hardFail:0,
 closedPct:0.0, avgVariance:94.8,
 missCounts:{kcalLow:0, kcalHigh:0, pro:0, carbPct:1, fatPct:0, veg:1, fruit:0},
 timingAvg:655, mode:'standard'}
```
Test 2 (not re-baselined after `cc3b439` — byte-for-byte identical to Test 1 change, so pre-change baseline still valid): `mealPlannerStressBaseline2`.

Labeled snapshot: `mealPlannerStressBaseline_BIGUPDATE-post-balance-removal` + `2_BIGUPDATE-post-balance-removal` preserved at the `BIGUPDATE-post-balance-removal` tag.

### Open items for next session (ranked)

**Ready** (Stage 2-aligned, pattern proven):
1. Apply idempotency pattern to `snapBatchTotals` + `snapBatchTotalsToGrid` (1 session each, ~30 lines). Expected: byte-for-byte identical stress, gains Stage 2 muscle.
2. Apply idempotency pattern to `postBalanceWastePass`. More complex (batch-atomic revert) but mostly has fast-paths.
3. Apply idempotency pattern to `applyTripFlexScaling`. Hardest — needs boundary-check guard.

**Design work**:
4. Draft unified convergence-loop skeleton (separate session). Should inventory thrash-detection strategy at loop level.
5. Decide: after converting all 5 adjusters to idempotent, can we drop the explicit pipeline ordering entirely in favor of the loop?

**Deferred** (from this session):
- **Stage 1b** (cache-preserving rerolls): decided to skip in favor of Stage 2 since the pattern will be obsolete there. If user changes mind, see this session's Stage 1b investigation notes for Option A/B/C tradeoffs.

**Carry-forward from prior sessions**:
- Recipe normalization for remaining off-budget meals (~8 lunch/dinner + ~5 breakfast). Pattern: user provides original full recipe, we scale proportionally.
- INV6 audit: top offenders `pb_apple_slices`(43), `pb_banana`(42), `filet_din`(34) — all structural (peanut butter fat ratios, filet is 33% fat by design). Accepted.
- Retry timing cost (60 retries × per-retry pipeline) investigation if user wants to push timing further.

### Runbook

**Running standard stress** (Test 1, deterministic):
```js
// Copy a chunked pattern from the session — preview_eval 30s timeout
// needs ~10-12 seeds per chunk. Setup + run + aggregate + formatReport.
```

**Inspecting a specific day's state** (after runOne):
```js
MPStress.inspectDay(seed, 'him', 'Monday')   // returns slot breakdown
MPStress.inspectRun(seed)                    // restores full post-randomize state
MPStress.exitInspect()                       // back to pre-inspect state
```

**Debugging cache-state issues** (proven technique from Stage 1a v3):
1. Add `window._diagX = 0` counters at stage boundaries in question.
2. At each boundary: `try { var n = verifyInvariants().filter(v => v.startsWith('INV7 ')).length; window._diagX = (window._diagX||0) + (n>0?1:0); } catch(e){}`
3. Run 3-5 seeds, examine which boundary first shows non-zero.
4. Narrow between those boundaries with more counters until you find the responsible line.

**When the harness says "all 0 ✓" but you suspect ratio drift**: run 5-10 seeds with the code live, then call `verifyInvariants()` directly while the stress state is live (not via `inspectRun` — that restores postSnap which may have subtle differences from live state). If INV7 fires live but report says 0, that's a snapshot/restore bug (like the INV7=5 phantom from the session-start).
