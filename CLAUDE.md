# Family Meal Planner — Architecture Summary

Single-file HTML/JS PWA (`index.html`, ~7140 lines) for two people ("Him"/"Her") with nutrition tracking, shopping lists, package waste elimination, and cloud sync. Installable on mobile via `manifest.json` + `sw.js` service worker.

## Data Layer

- **NUTRI_DB** — ingredient database. Units: tbsp/cup/oz/each/slice/scoop (no tsp). Per-ingredient flags:
  - `halfSnap` — ½ tbsp increments
  - `wholeOnly` — always whole (eggs, bread, tortilla, rxbar, tuna pouch, celery, fish oil)
  - `wholeWhenSolo` — whole for single-portion cooks only, fractional OK when shared/leftover (e.g. scallion)
  - `minAmt` — floor (beans 0.5 cup, ground meat 8 oz, avocado 0.25, oils/nut butters protected)
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
- **SHARED_SCHEDULE** — per day/slot sharing and eat-out plan. Values: `'shared'`, `'skip-him'` (eat-out him), `'skip-her'` (eat-out her), `'skip-both'` (eat-out both), or absent (normal).
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

## Calorie Adjuster

Clean 2-step uniform scale with a `mealTotalServings` param so the snap
pass knows the true batch size for shared/leftover cooks:

1. **Skip-if-close**: If recipe is within 15% or 80 kcal of budget, no adjustment.
2. **Uniform scale**: All scalable ingredients scale by the same factor (capped at 1.75× scale-up on some meals).
3. **Fat-drop + backfill**: When a meal's fat % exceeds the limit, biggest fat contributor is dropped/reduced and calories are refilled with protein/carb items. Egg wholes auto-swap to egg whites when fat % exceeds limit.
4. **Post-snap trim**: Reduce highest-calorie items when over budget after snapping. 50% carb floor.
5. **Per-portion snap** (single pass): snap each ingredient's per-portion amount to its grid:
   - `oz`/`slice`/`scoop`/`serving` → whole
   - `cup` → 0.25 grid
   - `tbsp`/`halfSnap` → 0.5 grid
   - `each` eggs → whole; other `each` → 0.25 grid (or whole when `wholeWhenSolo` and single-portion)
   - `wholeOnly` → always whole
   - Shared/leftover totals stay clean because the sum of 0.25-multiples is on the 0.25 grid (removed the old total-level snap branch)
   - Packaged items snap too; the package nudge can still refine within ±0.25 to hit clean package boundaries (this is why some amounts legitimately end up off-grid, e.g. 2.625 cup beans when 2 × 2.625 = 3 full cans)
6. **Package nudge**: Per-meal nudge with per-ingredient flex ranges:
   - Default: ±0.25 cup / ±2 oz, ±50 kcal
   - Marinara: +100% up (low cal, 66 kcal/cup)
   - Beans/chickpeas: +50% up, ±120 kcal
   - Coconut milk: +75% up / -50% down
   - Skips `longShelfLife` items.

Shared meals: each person gets their own portion (his adjusted + her adjusted = shared total).

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
   - **Veg < 3c**: +veg one grid step (no trim — veg is so low-cal the min-grid trim would remove way more kcal than the veg adds)
4. Cached per (p, d); invalidated via `invalidateLeftoverCache`.
5. Fruit is NOT boosted — user preference, and most days hit naturally.

Dinner also still absorbs daily calorie residual (see `getSlotAdjustment`).

Consumers (all read from the balancer so cards/totals/shopping all agree):
- `calcTotals` (daily totals shown in stats bar)
- `computeCardMacros` (meal card render)
- `computeDailyFV` (veg/fruit check helper)
- `renderSharedCard.adjustedForPerson` (Shared tab)
- `buildShoppingList` (shopping qty)

## Page State Persistence

Session state survives refresh via `sessionStorage['mealPlannerPageState']`: `topTab`, `person`, `day`, `activeWeek`, `scrollY`, `openCards`, `sharedSchedOpen`. Saved on `beforeunload`, restored at init. Scroll position restored after render via `setTimeout`.

## Package Waste Elimination

Achieves 100% zero-waste on `Randomize` clicks via a multi-layer pipeline:

1. **Phase 1 (random picks)**: 60 attempts per person/day. Scoring uses **scaled-to-slot-budget** kcal (not raw base kcal) so meals with low base kcal like smoothies aren't systematically skipped. Score = `calDiff + fatPenalty + discouragedPenalty`. Early exit when `calDiff ≤ 100 && fatPct ≤ 0.30`.
2. **Phase 1.5 (solo pkg removal)**: After Phase 1 + shared-schedule sync, scans every slot. Any pkg meal that is NOT shared and NOT part of a leftover chain gets replaced with a non-pkg alternative. Prevents the #1 waste source: a single 0.5 cup bean meal opening a 1.75 cup can with no pairing.
3. **Phase 2**: Package analysis per trip (Mon–Wed / Thu–Sun) via `_analyzeTripPackages`. Uses per-slot **scaled estimates** (budget/baseKcal ratio × base amounts) for speed — not the full day-balancer.
4. **Phase 3**: Convergence loop (up to 6 iterations per trip) that greedily reduces total trip waste:
   - **Strategy A**: Swap non-package slots to meals that use the wasting ingredient. Scores every candidate by **total trip waste across all packages** (not just this one) so a swap that fixes tofu but opens bean waste gets rejected. Uses cheap base-kcal guard instead of full calcTotals for speed.
   - **Strategy B**: Mark as resolvable-by-nudge if per-meal nudge can close the gap.
   - **Strategy C**: Remove a single-use package meal only if the removal **strictly reduces** total trip waste. Preserves meals like `silken_tofu_smoothie` when Strategy A has paired them.
5. **Final**: Enforces shared schedule.
6. **Retry loop**: 30 internal retries per `randomizeWeek` click. Uses fast approximate waste counting during retries (not buildShoppingList). Keeps best by (totalWaste, goalMisses) lexicographic. Exits early on (0, 0).
7. **Smart day re-roll** (`rerollMissDays`): scored single-slot swaps for miss-days (see Randomizer section).
8. **Trip-level flex scaling** (`applyTripFlexScaling`): after all retries + re-rolls, proportionally scales ALL meals in a trip using a flex ingredient to hit the nearest package boundary. Per-usage: each day checks daily goals post-scale; reverts that specific day if any goal breaks. Day-balancer auto-compensates by trimming carb/fat.
   - Flex ranges: marinara +100%, beans/chickpeas +75%, coconut +75%/-50%, broth +100%/-50%, tofu +100%, tuna +75%/-25%, ground meats +75%
9. **`minAmt`**: Prevents adjuster from zeroing out packaged ingredients.
10. **Waste display**: Shopping list `hisSum`/`herSum` are NEVER modified — they reflect exact cook amounts from meal cards. Waste = `ceil(total/perPkg)*perPkg - total`. Displayed as "⚠️ ½ can unused". Skipped for `longShelfLife` (egg white) items. Bulk (ground meats) included since freezing partial bags is inconvenient.

### Meal portion sizing for zero-waste

Certain meals had portions tuned to allow clean package-summing combos:
- `silken_tofu_smoothie`: 7 oz silken tofu (pairs with 7 oz soup = 14 oz container)
- `breakfast_burrito`: 0.75 cup black beans (pairs with 1 cup `black_bean_rice_bowl` = 1.75 cup can)

## Schedule Meals (Meal Planning UI)

Collapsible panel with 7×3 grid (Mon-Sun × Breakfast/Lunch/Dinner):

- **Split pills**: Him/Her halves per cell. Tap toggles eat-out, long press toggles shared.
- **States**: Normal (gray), Shared (green), Eat-out him/her/both (red).
- **Manual Set**: Purple indicator for slots manually overridden. Schedule grid locked for manually-set slots.
- **Day toggle**: Tap Mon-Sun label cycles whole day (normal → shared → eat-out → normal).
- **Presets**: B/L/D buttons with 3-zone click (left=him eat-out, center=shared, right=her eat-out).
- **Set button**: Locks current schedule as manual overrides.
- **Clear button**: Clears all manual sets with confirm popup.
- **Painting mode**: Select slot + meal, tap cells to queue, Assign to apply.

## Randomizer

`randomizeWeek(target)` wraps 30 retries of `_randomizeWeekCore(target)`, then runs targeted day re-rolls.

**Per-retry pipeline:**
- **Pre-phase**: Clears old skips, locks eat-out slots, applies schedule eat-outs.
- **Phase 1**: Per-person per-day, 60 random attempts. Kcal contribution is estimated at the **slot budget** (not base) so low-base meals aren't penalized. Score = `calDiff + fatPenalty + discouragedPenalty`.
- **Phase 2**: Analyzes package waste per trip.
- **Phase 3**: Convergence loop of A/B/C strategies to eliminate waste (see "Package Waste Elimination").
- **Final**: Enforces shared schedule.

**Retry selection** (lexicographic, lower is better):
1. Total waste (package items with residual waste)
2. Goal misses (person-days that fail any of the 6 primary daily goals: cals ±100, protein, carbs ≤55%, fat ≤30%, veg ≥3c, fruit ≥1c)

Early-exits on `(totalWaste=0, goalMisses=0)`. Otherwise keeps the best-scoring state across 30 retries.

**Smart day re-roll** (`rerollMissDays`) — runs after the best state is restored:
- For each day still missing any primary goal, iterate up to 7 times.
- Each iteration evaluates every non-pkg candidate meal for every non-pkg slot (both persons), computes the day's new miss count, and commits the single swap that maximally reduces misses.
- **Package meals are never swapped out** (waste optimizer owns them) and **never swapped in** (can't introduce new pkg dependencies).
- Reverts if total waste worsens.

**Scoring penalties**: `fatPenalty = (fatPct - 0.30) × 1000` if daily fat > 30%. `discouragedPenalty = 500 × (meals using any DISCOURAGED_INGREDIENT)`.

**Result quality** (measured 10 runs × 350 person-days each):
- Zero-waste rate ~100% (honest — shopping list matches card totals exactly)
- Per-person per-day "all 6 primary goals met": Him ~100%, Her ~98%
- Perfect weeks (both people, all 14 days, all 6 goals, zero waste): ~85%
- Per-click time ~2–3s on desktop.

**Meal variety preserved**: avg 38 unique meals per 7-day week (out of ~85 DB meals), week-to-week overlap ~5%. The goal-aware scoring slightly favors meals that reliably hit targets (e.g. turkey_meatballs_din, edamame snacks) but no meal is dead.

## 3-Week View

- **Last / This Week / Next**: Three week pills. Auto-rollover shifts last←this←next.
- **Last week**: Amber banner "View Only". No randomize button. Manual edits still possible.
- **Next week**: Blue banner "Planning Ahead". Fully editable.
- **Rollover**: Clears all manual overrides (skips, eat-outs, overrides, late snacks) for the new week.

## UI Pills (top row of each meal card)

- **Leftovers** (amber) — auto, not clickable. Shows when meal is a leftover.
- **Big Cook** (amber) — auto, not clickable. Shows on cook day.
- **Set** (purple) — auto, not clickable. Shows when slot is manually overridden.
- **Shared** (green) — toggle for shared cooking.
- **Skip** (grey) — toggle. Sets MANUAL_SET. Eat Out visible when skipped.
- **Eat Out** (red) — toggle. Sets MANUAL_SET. Overrides skip.

## Macro Display

- Stats bar: kcal (person color) / protein (person color) / carbs (green) / fat (yellow)
- Macro bar: P/C/F colored segments. Her tab uses pink (#F472B6) for protein.
- Meals tab color: blue (Him), pink (Her), green (Shared).

## Shopping

- `buildShoppingList(trip, who)` adds each slot's balanced amounts individually via `getBalancedSlotIngredients`. No leftover multiplier logic, no cross-person cook handling, no shake special case. Every slot (including leftover days and shakes) contributes its balanced amounts directly. Leftover days are pinned to cook-day amounts, so adding each day individually gives the correct batch total.
- **No shopping-level scaling** — `hisSum`/`herSum` are NEVER modified. They reflect exact balanced amounts.
- `shopQtyWithCount()` converts the ingredient qty into a shopping label:
  - `pkg` → count of packages (e.g. "1 container (14oz)" for tofu, "1 carton (32oz)" for egg white, "2 cartons (14oz)" for silken tofu)
  - `produce.perWhole` → whole-produce count (e.g. "3 cucumbers", "1 head broccoli")
  - `type:'bulk'` → raw quantity (no conversion)
- Waste = `ceil(total/perPkg) * perPkg - total`. Displayed as "⚠️ ½ can unused". Skipped for `longShelfLife` items.
- Egg whites are a separate line from whole eggs ("Egg, white" vs "Egg, whole").

## Shared Tab

`renderSharedView(day)` → `renderSharedCard()` for each slot where `him_id === her_id`. The card computes each person's **adjusted** ingredient list separately, then sums per-ingredient (his adjusted + her adjusted). This matches the Him and Her tabs and the shopping list — all three agree on totals. Individual Him/Her tabs show per-portion amounts with a plain "🥗 Ingredients" label for same-day shared slots; the "Combined (serves N)" label only appears when a meal is a non-shared Big Cook (solo leftover batch or cross-person cook) so the combined info isn't lost.

## Recipes Tab

Three collapsible sections:
- **New Recipe**: Compact form with slot/person chips, bordered ingredient list, steps textarea.
- **New Ingredient**: 2-row compact form (Name/Unit/Role + Kcal/Pro/Fat/Carb).
- **Edit Recipes**: Slot/meal picker with inline preview. Edit mode shows quantity dropdowns. Assign saves as custom override (clones built-in meals).

**Meal categories**: Dropdowns group meals by category. Lunch/dinner dropdowns additionally expose a **Vegetarian** group.

### Breakfast pool (23 meals as of latest round)
Egg scramble, tuna scramble, egg omelet, turkey+egg scramble, turkey sweet-potato hash, Korean egg bowl, Korean juk, Vietnamese noodle bowl, quinoa bowl, Thai tofu scramble, sweet-potato hash, chicken wrap, yogurt bowl, overnight oats, yogurt oat bowl, banana protein oats, protein pancakes, chia pudding, apple cinnamon oats, smoothie bowl, breakfast burrito (black beans), shakshuka (marinara), silken tofu smoothie, coconut chia pudding, coconut oatmeal, white bean scramble, savory congee (chicken broth). Coconut milk is discouraged — those breakfasts appear rarely by default.

## Temp Ingredient Button

Each meal card shows a `+` button in the ingredient section header. Tapping opens a picker (`addTempIngredient` → `confirmTempIngredient`) to append a one-off ingredient to that person/day/slot without editing the underlying recipe. Useful for ad-hoc additions.

## Cloud Sync

GitHub Gist API push/pull with per-slot timestamp merge (last-write-wins). Syncs weekData (all 3 weeks), customMeals, customIngredients, eatOutDB. Connect via GitHub token + Gist ID. Share button for easy device pairing.

## CSS Architecture

Uses CSS custom properties (`:root` vars) for theming. Key reusable classes:
- Layout: `macro-bar`, `macro-labels`, `hdr-row`, `sched-grid`, `sched-panel`, `paint-bar`
- Schedule pills: `sched-pill-wrap`, `sched-pill-half`, `sched-zone` (l/c/r)
- Buttons: `sched-btn`, `sched-btn-set`, `rand-btn`
- Cards: `sv-card`, `sv-meal-title`, `set-pill`, `day-badge`
- Sync: `sync-desc`, `sync-field-label`, `sync-id-box`, `sync-btn-grid`

Function-scoped variables use `const`/`let` (only ~40 top-level globals remain as `var`).

## Key Helper Functions

- `buildMealSelectOpts(slotMeals, activeId)` — grouped `<option>` HTML for meal selector
- `computeCardMacros(port, person, day, s, cookServings, showBanner, mealTotalServings)` — adjusted macros + ingredient HTML. Reads from the day-balanced cache.
- `computeDailyFV(p, d)` — returns `{veg, fruit}` cup totals for a person/day using post-adjustment ingredient amounts. For test/diagnostic evals (goal check).
- `getDayBalancedIngredients(p, d)` — **single source of truth** for all ingredient amounts. Cached map of `{slot: [{dbKey, amt, role, scalable, origAmt}, …]}`. Pipeline: classify leftovers → Pass 1 (non-leftover slots via per-slot adjuster; shakes as frozen raw) → Pass 2 (different-day leftovers pinned from cook day cache, frozen) → day-level macro balancer (same-day cook slots counted × servings via `sameDayCookServings`) → post-balancer calorie correction (fat-first trim/boost to close residual gap) → materialize same-day leftovers from finalized cook slots.
- `getBalancedSlotIngredients(p, d, s)` — shortcut for one slot. Every consumer reads from here: `calcTotals`, `buildShoppingList`, `computeCardMacros`, `renderSharedCard`, `computeDailyFV`.
- `verifyInvariants()` — runtime assertion checker. 5 invariants: leftover pair consistency, calcTotals↔balanced agreement, shopping↔balanced agreement, card↔balanced agreement. Runs after every `randomizeWeek`, warns on violations.
- `invalidateDayBalancedCache()` — invalidates when `invalidateLeftoverCache` runs.
- `lsGet(key, fallback)` / `lsSet(key, val)` — localStorage with JSON parse/stringify
- `lsGetRaw(key)` / `lsSetRaw(key, val)` — localStorage raw string access

## Cross-Tab Card Sync

Expanding/collapsing a meal card in the Him tab mirrors the same slot's state in the Her tab (and vice versa), so switching person tabs preserves both layout height and scroll position. Shared tab has independent state and still jumps to top on activation. Implemented in `toggleCard(k)` by splitting the key and setting `openCards[otherKey] = openCards[k]`.

## Key Files

- `index.html` — the entire app (single file, ~7500 lines)
- `manifest.json` — PWA manifest (standalone, dark theme)
- `sw.js` — service worker (network-first caching, GitHub API passthrough)
- `icon.jpeg` — app icon (favicon + apple-touch-icon + PWA icon)
- `CLAUDE.md` — this architecture doc
- `Archive/` — backup copies of previous versions

## Current State & Next Steps (as of 2026-04-16)

### What's working
- **Daily macro goals**: ~90% strict hit rate (30-run sample). All misses are borderline fat% (30.1–31%) or rare carb% (55.1%). Calories, protein, veg, fruit all 100%.
- **Secondary goals**: 100% hit rate (±150 cal, <35% fat, <60% carbs, pro min-10, ≥2c veg, ≥0.5c fruit)
- **Zero waste**: ~77% of runs (23/30) achieve honest zero waste
- **Data integrity**: `verifyInvariants()` checks 5 invariants after every randomize — 0 violations across 20 runs
- **Leftover pair consistency**: 100% — leftover days show exactly what was cooked
- **Meal variety**: avg ~33 unique meals per week, no dead meals
- **Coconut milk**: rarely picked (~60% zero-coconut weeks), paired when it is
- **Per-click time**: ~2–3s

### Single source of truth architecture (established 2026-04-16)

All data consumers read from `getBalancedSlotIngredients(p, d, s)`. No special cases for shakes, leftovers, cross-person cooks, or any other slot type. The balanced cache is the only place amounts live.

**`getDayBalancedIngredients` pipeline:**
1. Classify slots: same-day leftovers, different-day leftovers, normal slots
2. **Pass 1**: Compute non-leftover slots via per-slot adjuster. Shakes included as frozen raw amounts. Dinner target computed from actual amounts already in slots (not recomputed inline). Veg/fruit capped at 2× original recipe amount. Per-slot budget enforcement trims fat→carb→protein if non-dinner slot exceeds budget by >50 kcal.
3. **Pass 2**: Different-day leftovers pinned from cook day's cache, frozen.
4. **Day-level macro balancer**: `dailyMacros()` counts same-day cook slots × `sameDayCookServings` so the balancer tracks live amounts. Frozen slots (leftovers, shakes) contribute to totals but can't be modified.
5. **Post-balancer calorie correction**: If frozen leftovers push daily total >50 kcal off target, proportionally trims non-frozen ingredients. Fat trimmed first (with floor snap), then carb, then protein last. Accounts for `sameDayCookServings` multiplier.
6. **Materialize same-day leftovers**: Copy finalized cook slot amounts to same-day leftover slots.

**Cook day card display** for cross-person cooks: shows real combined batch = cook person's balanced × their servings + other person's balanced × their servings. "Serves N" label uses actual total.

### Recently fixed (2026-04-16 session)

1. **Stale leftovers in Phase 3**: Recompute `leftovers` each convergence iteration. Zero-waste ~70% → ~85%.
2. **Fictional leftover-day amounts**: Leftover days were independently balanced, showing fantasy numbers. Now pinned to cook-day amounts. 100% pair consistency.
3. **Same-day leftover balancer timing**: Leftovers were copied pre-balance then re-synced post-balance (stale during balancing). Now excluded from slots during balancing; `dailyMacros()` counts cook slot × servings.
4. **Shakes in balanced cache**: Eliminated all shake special cases across calcTotals, buildShoppingList, verifyInvariants.
5. **Cross-person cook shopping**: Was using raw amounts for other person's portion. Now uses balanced amounts.
6. **Cross-person cook waste optimizer**: Was missing scale factor for other person's portion.
7. **computeCardMacros when slotAdj=0**: Was skipping balanced cache. Now always reads from cache.
8. **Missing invalidateLeftoverCache after bestSEL restore**: Stale cache could affect rerollMissDays.
9. **Fat/carb swapped in stats bar**: `updateStatsBar` wrote fat to carbs position and vice versa during live editing.
10. **dailyFV missing sameDayCookServings multiplier**: Veg/fruit undercounted for same-day cook slots.
11. **Missing autoSaveWeek on ingredient edits**: `onIngrAmt`, `onIngrSwap`, `onIngrReset` now persist changes.
12. **Dinner target used inline recomputation**: Now reads actual balanced amounts from already-computed slots.
13. **Cross-person cook card display**: Shows real combined batch (his balanced × his servings + her balanced × her servings), not his × totalServings.
14. **Calorie correction fat snap**: Fat-role ingredients floor when trimming (over target), other roles round nearest.
15. **Simplified buildShoppingList**: Just adds each slot's balanced amounts. No leftover multiplier, no cross-person logic, no shake branch.
16. **Post-snap trim preserves protein**: `adjustIngredients` trim step now trims fat→carb→protein (was highest-kcal-first regardless of role). Prevents salmon/chicken from being crushed when dinner absorbs calorie residual.
17. **Phase 1.6 — swap over-budget snacks**: Whole-item snacks (RXBAR, eggs+apple) that can't be scaled for Her's 164 kcal budget are replaced. Snack over-budget rate 39% → 16%.
18. **Phase 1.7 — swap solo-pkg snacks**: If a snack is the only meal in the trip using a pkg ingredient, swap to non-pkg to avoid opening a package for one snack.
19. **Veg/fruit 2× cap**: After per-slot adjuster, veg/fruit capped at 2× original recipe amount (was unlimited — broccoli hit 260%).
20. **Per-slot budget enforcement**: Non-dinner slots trimmed fat→carb→protein if >50 kcal over budget after adjuster.
21. **Post-balance waste pass**: After full balanced pipeline, nudges pkg ingredient amounts across the trip to hit clean package boundaries. Reverts any day where goals break.

### Items for future sessions
- **Waste vs goals tension**: The day balancer and calorie correction can shift pkg amounts after the waste optimizer runs. Excluding pkg from the balancer was tested but net-negative (fewer tools for macro balancing). The post-balance waste pass helps (~77% zero-waste) but can't fix all cases. Deeper fix: tighter coordination between waste optimizer and balanced pipeline.
- **Cross-person leftover pinning**: Her's portion is computed independently for her eating day (correct for her calories) but not pinned to cook time. Shopping handles this correctly (adds each slot individually). Card display is fixed. Lower priority.
- **Secondary goal UI**: Could display as "yellow zone" vs "green zone" on the stats bar
- **Meal variety audit**: some meals like `turkey_meatballs_din` and `edamame_orange_eve` are heavily favored
- **Ground meat pkg.type**: changed from `'bulk'` to `'container'` — verify shopping display
