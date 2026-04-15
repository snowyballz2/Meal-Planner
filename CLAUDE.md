# Family Meal Planner — Architecture Summary

Single-file HTML/JS PWA (`index.html`, ~6120 lines) for two people ("Him"/"Her") with nutrition tracking, shopping lists, package waste elimination, and cloud sync. Installable on mobile via `manifest.json` + `sw.js` service worker.

## Data Layer

- **NUTRI_DB** — ingredient database. Units: tbsp/cup/oz/each/slice/scoop (no tsp). Key flags: `halfSnap` (½ tbsp increments), `wholeOnly` (whole numbers only, eggs), `minAmt` (floor — beans 0.5 cup, ground meat 8 oz, avocado 0.25, oils/nut butters protected from zeroing). `pkg` field for packaged items (cans, cartons, jars) with `drained`/`cups`/`size`/`unit`/`type`. `type:'bulk'` skips shopping display conversion. Egg whites are stored as liquid carton (cups); display shows egg-equivalent count e.g. `½ cup (4)` and `cup (6)` in swap dropdown.
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

## Calorie Adjuster (rewritten)

Clean 2-step uniform scale replaces the previous ratio-war approach:

1. **Skip-if-close**: If recipe is within 15% or 80 kcal of budget, no adjustment is applied.
2. **Uniform scale**: All scalable ingredients scale by the same factor (capped at 1.75× uniform scale-up on some meals to prevent absurd portions; package system then nudges amounts).
3. **Fat-drop + backfill**: When a meal's fat % exceeds the limit, biggest fat contributor is dropped/reduced and calories are refilled with protein/carb items. Egg wholes auto-swap to egg whites when fat % exceeds limit.
4. **Post-snap trim**: Reduce highest-calorie items when over budget after snapping. Trim can reduce fat items below original.
5. **Directional snapping** (single pass at end): scalable items snap via `Math.round` (avocado/each items snap to 0.5; eggs snap to whole). 50% carb floor everywhere — carbs never removed in trim passes.
6. **Package nudge**: Per-meal nudge capped at ±0.25 cup / ±2 oz and ±50 kcal to prevent drift. Coconut milk frozen during scale-up in high-fat meals.

Shared meals: each person gets their own portion (averaging reverted).

## Page State Persistence

Session state survives refresh via `sessionStorage['mealPlannerPageState']`: `topTab`, `person`, `day`, `activeWeek`, `scrollY`, `openCards`, `sharedSchedOpen`. Saved on `beforeunload`, restored at init. Scroll position restored after render via `setTimeout`.

## Package Waste Elimination

Zero-waste system across the full pipeline:

1. **Randomizer Phase 1**: Anchors package meals (beans, coconut milk, marinara, tofu, ground meats) into shared-schedule slots as shared + leftover pairs.
2. **Phase 2**: Fills remaining slots with non-package meals only.
3. **Phase 3**: Replaces unpaired package meals in shared slots.
4. **Final**: Enforces shared schedule (runs absolutely last).
5. **Shopping optimizer**: Scales trip totals to clean package boundaries. Per-ingredient flex ranges (beans/marinara +100%, coconut +75%). Equal portions for shared meals.
6. **Retry loop**: Re-randomizes up to 10 times until zero waste achieved.
7. **`minAmt`**: Prevents calorie adjuster from zeroing out packaged ingredients (beans 0.5 cup, coconut 0.25 cup, tofu 7 oz, ground meats 8 oz).
8. **Waste warnings**: Amber "⚠️ ½ can unused" on shopping list items with any remaining waste.

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

`randomizeWeek()` with retry wrapper → `_randomizeWeekCore()`:

- **Pre-phase**: Clears old skips, locks eat-out slots, applies schedule eat-outs.
- **Phase 1**: Anchors package meals into shared-schedule slots with leftover pairing. Cap: 3 per trip.
- **Phase 2**: Fills remaining slots with non-package meals. 2-day buffer prevents repeats (including cross-week from last week data).
- **Phase 3**: Replaces unpaired package meals in shared slots with non-package alternatives.
- **Final**: Enforces shared schedule — all `'shared'` slots get matching him/her meals.
- **Trip optimization**: `optimizeTripWaste()` tries random swaps within Mon-Wed and Thu-Sun trips.
- **Randomize popup**: Him/Her toggles to choose who to randomize.
- **Scoring**: Per-person daily meal pick is scored by `calDiff + fatPenalty`. Fat penalty = `(fatPct - 0.30) × 1000` when daily fat exceeds 30%. Early-exit when `calDiff ≤ 100 && fatPct ≤ 0.30`. (Earlier protein penalty was removed — vegetarian meals had protein boosted directly instead.)

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

- `buildShoppingList()` aggregates ingredients per trip (Mon-Wed, Thu-Sun).
- Package optimizer scales totals to clean package boundaries with per-ingredient flex ranges.
- Equal split for shared meals (same pot = same portions).
- `shopQtyWithCount()` converts to package counts. `type:'bulk'` skips conversion.
- Waste warnings on any remaining package waste.
- Both view shows combined totals only (no him/her split).

## Recipes Tab

Three collapsible sections:
- **New Recipe**: Compact form with slot/person chips, bordered ingredient list, steps textarea.
- **New Ingredient**: 2-row compact form (Name/Unit/Role + Kcal/Pro/Fat/Carb).
- **Edit Recipes**: Slot/meal picker with inline preview. Edit mode shows quantity dropdowns. Assign saves as custom override (clones built-in meals).

**Meal categories**: Dropdowns group meals by category. Lunch/dinner dropdowns additionally expose a **Vegetarian** group. Recent meal additions: 10 lean recipes (ground turkey/chicken, beans, lentils, shrimp), 7 lean breakfast options (all under 30% fat, no oils/avocado), 6 lighter snacks.

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
- `computeCardMacros(port, person, day, s, cookServings, showBanner)` — adjusted macros + ingredient HTML
- `lsGet(key, fallback)` / `lsSet(key, val)` — localStorage with JSON parse/stringify
- `lsGetRaw(key)` / `lsSetRaw(key, val)` — localStorage raw string access

## Key Files

- `index.html` — the entire app (single file, ~6120 lines)
- `manifest.json` — PWA manifest (standalone, dark theme)
- `sw.js` — service worker (network-first caching, GitHub API passthrough)
- `icon.jpeg` — app icon (favicon + apple-touch-icon + PWA icon)
- `CLAUDE.md` — this architecture doc
- `Archive/` — backup copies of previous versions
