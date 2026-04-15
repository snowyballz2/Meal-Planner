# Family Meal Planner — Architecture Summary

Single-file HTML/JS PWA (`index.html`, ~6860 lines) for two people ("Him"/"Her") with nutrition tracking, shopping lists, package waste elimination, and cloud sync. Installable on mobile via `manifest.json` + `sw.js` service worker.

## Data Layer

- **NUTRI_DB** — ingredient database. Units: tbsp/cup/oz/each/slice/scoop (no tsp). Per-ingredient flags:
  - `halfSnap` — ½ tbsp increments
  - `wholeOnly` — always whole (eggs, bread, tortilla, rxbar, tuna pouch, celery, fish oil)
  - `wholeWhenSolo` — whole for single-portion cooks only, fractional OK when shared/leftover (e.g. scallion)
  - `minAmt` — floor (beans 0.5 cup, ground meat 8 oz, avocado 0.25, oils/nut butters protected)
  - `pkg` — packaged items with `{size, unit, drained/cups, type}`. Types: `'can'` (default), `'container'` (tofu), `'jar'` (marinara), `'carton'` (broth, egg white), `'pouch'` (tuna pouch), `'bulk'` (ground meats — skip shopping-list conversion)
  - `pkg.longShelfLife` — carton carries between trips; excluded from waste analysis and package nudge (egg white)
  - `produce: {perWhole, label}` — converts cup counts → whole-produce counts for the shopping list (bell pepper, broccoli, cucumber, zucchini, sweet potato, etc.)
- **DISCOURAGED_INGREDIENTS** — `['coconut milk']`. Phase 1 scoring adds a 150-point penalty per meal using one, so the randomizer picks them rarely unless needed for waste closure.
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
6. **Package nudge**: Per-meal nudge capped at ±0.25 cup / ±2 oz and ±50 kcal. Skips `longShelfLife` items.

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
   - **Carb% > 55**: -carb one grid step, +protein of equal kcal
   - **Fat% > 30**: -fat one grid step, +protein of equal kcal
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
2. **Phase 2**: Package analysis per trip (Mon–Wed / Thu–Sun) via `_analyzeTripPackages`.
3. **Phase 3**: Convergence loop (up to 6 iterations per trip) that greedily reduces total trip waste:
   - **Strategy A**: Swap non-package slots to meals that use the wasting ingredient. Scores every candidate by **total trip waste across all packages** (not just this one) so a swap that fixes tofu but opens bean waste gets rejected.
   - **Strategy B**: Mark as resolvable-by-nudge if per-meal nudge can close the gap (shopping optimizer handles the numbers).
   - **Strategy C**: Remove a single-use package meal only if the removal **strictly reduces** total trip waste. Preserves meals like `silken_tofu_smoothie` when Strategy A has paired them.
4. **Final**: Enforces shared schedule.
5. **Shopping optimizer**: Scales trip totals toward clean package boundaries with per-ingredient flex (`black beans/cannellini/marinara/chickpeas` +100%, `coconut milk` +75%).
6. **Retry loop**: 30 internal retries per `randomizeWeek` click, keeping the **best-waste state** (not the last one). Exits early on zero waste.
7. **`minAmt`**: Prevents adjuster from zeroing out packaged ingredients.
8. **Waste warnings**: Amber "⚠️ ½ can unused" on shopping list items with any remaining waste. Skipped for `longShelfLife` cartons.

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

**Scoring penalties**: `fatPenalty = (fatPct - 0.30) × 1000` if daily fat > 30%. `discouragedPenalty = 150 × (meals using any DISCOURAGED_INGREDIENT)`.

**Result quality** (measured 50 runs × 350 person-days each):
- Zero-waste rate ~100%
- Per-person per-day "all 6 primary goals met": Him ~100%, Her ~98%
- Perfect weeks (both people, all 14 days, all 6 goals, zero waste): ~85%
- Per-click time ~1s on desktop.

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

- `buildShoppingList(trip, who)` aggregates ingredients per trip (Mon-Wed, Thu-Sun). For each person/day/slot it runs `adjustIngredients` to get the **adjusted** per-person amount, then sums. (Leftover days are skipped — cook day carries the full batch.)
- Package optimizer scales totals toward clean package boundaries within per-ingredient flex.
- `shopQtyWithCount()` converts the ingredient qty into a shopping label using whichever the ingredient supports:
  - `pkg` → count of packages (e.g. "1 container (14oz)" for tofu, "1 carton (32oz)" for egg white)
  - `produce.perWhole` → whole-produce count (e.g. "3 cucumbers", "1 head broccoli")
  - `type:'bulk'` → raw quantity (no conversion)
- Waste warnings on any remaining package waste. Skipped for `longShelfLife` items.
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
- `getDayBalancedIngredients(p, d)` — cached map of `{slot: [{dbKey, amt, role, scalable, origAmt}, …]}` after per-slot adjust + whole-day macro balance.
- `getBalancedSlotIngredients(p, d, s)` — shortcut for one slot.
- `invalidateDayBalancedCache()` — invalidates when `invalidateLeftoverCache` runs.
- `lsGet(key, fallback)` / `lsSet(key, val)` — localStorage with JSON parse/stringify
- `lsGetRaw(key)` / `lsSetRaw(key, val)` — localStorage raw string access

## Cross-Tab Card Sync

Expanding/collapsing a meal card in the Him tab mirrors the same slot's state in the Her tab (and vice versa), so switching person tabs preserves both layout height and scroll position. Shared tab has independent state and still jumps to top on activation. Implemented in `toggleCard(k)` by splitting the key and setting `openCards[otherKey] = openCards[k]`.

## Key Files

- `index.html` — the entire app (single file, ~6860 lines)
- `manifest.json` — PWA manifest (standalone, dark theme)
- `sw.js` — service worker (network-first caching, GitHub API passthrough)
- `icon.jpeg` — app icon (favicon + apple-touch-icon + PWA icon)
- `CLAUDE.md` — this architecture doc
- `Archive/` — backup copies of previous versions
