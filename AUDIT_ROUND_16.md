# Audit Round 16 — V275–V307 (2026-08-07)

**Scope**: all changes V275→V307 and their intersections with older machinery: the R15 fix waves (V275–V280), user-declared batch membership (V282/V286/V306/V307), the fact model (V283/V284/V304), the UI conversion (V287–V305), rule 3 + the V307 move dialogs.

**Method**: the 13-finder agent wave died at session limits before returning results (R15 precedent, same failure mode). Completed as a primary-agent direct code-read audit (the R15 fallback method), prioritized by intersection risk. Every finding below is **code-confirmed with line numbers**; the CRITICAL is additionally **live-confirmed** with a pristine-boot browser reproducer. No fixes applied — findings only, per the standing rule.

**Coverage**: fully audited — fact×rule-3/moves, V307 dialog lifecycle, solo×orphan, materialize merge, leftoverLinks sync, orphan completeness, `_r3MoveChoice` lifecycle, INV23/25 gating, harness move-globals, pipeline drift V274→HEAD. Partially audited (candidate for a follow-up wave once agent limits reset): overlay auto-close matrix, ownership routing on the schedule detail view, pantry netting internals, V277 menu-op parity re-verification, today-prompt staleness, dialog z-order stack.

---

## A16-1 · CRITICAL — the manual-mutation surface is fact-unaware: orphaning and moves erase as-eaten history

**The promise**: "the past is fact, not plan" (V283, user-defined). Past days' as-eaten records must survive; manual changes to the past are allowed (the user correcting history), but side effects must not destroy *other* days' eaten records.

**(a) `changeMeal` on a fact anchor orphans EATEN leftover days — LIVE-CONFIRMED.**
`changeMeal`'s rule-3 capture (index.html:12287–12293) collects every time-shifted portion of the anchor's batch with no fact/date check, and `_r3ClearPortion` (12066–12074) deletes SEL/MANUAL_SET/USER_EDITED/overrides unconditionally. Fact state deliberately survives post-run (17618).
*Reproducer (pristine boot)*: him Mon-dinner cook + Tue-lunch + Wed-lunch leftovers; mid-week fact randomize (today=Wednesday → Mon+Tue fact, conservation extends fact to the whole batch). User changes Monday's meal (allowed — correcting history). Result: `SEL[him_Tuesday_lunch]` **DELETED** — the eaten Tuesday record (shrimp_coconut_curry) is gone, `_factKeys` still points at the now-empty slot, and the next mid-week randomize's fact capture will lock in the DEFAULTS/prompt fallback as fabricated history. `_bumpSlotTs` propagates the erasure to the partner device.

**(b) V307 "Clear those leftovers" is equally fact-blind** — same `_r3ClearPortion` path via the swapMeals orphan block (12259–12275), position-filtered only. Moving a batch cook whose preceding members include eaten days and choosing Clear erases them identically. Code-confirmed (same mechanism as (a); not separately live-probed).

**(c) Moving a fact slot strands its fact state.** swapMeals swaps SEL + verbatim cache rows, but `_factRows` stay keyed at the OLD slot (the V304 meal-guard then silences them — correct locally) and are never re-keyed to the new slot: the moved eaten meal's as-eaten amounts survive only until the first full cache invalidation, after which the rows *recompute* (the exact path-dependence V283 documented as "recomputation ≠ preservation"). `_factKeys` likewise aren't remapped — the stale key fact-locks whatever now sits in the old slot. Also nothing blocks moving an eaten meal to a FUTURE day (un-eating it), which the next randomize then re-captures wrongly in both directions.

**Consequence class**: fact-promise violation + fabricated history + sync propagation. Suggested shape of a fix (user decision): eaten-day guards on the orphan captures (skip or warn), fact re-keying on swap, and possibly a confirm on any manual mutation that would touch an eaten day other than the one the user is editing.

## A16-2 · MEDIUM — the V307 dialog survives every disarm path; a late button press executes against stale state

All five R15 l1/l2 disarm sites null `_movePending` — person-disable (6419), applyScheduleEdit (16042), randomizeWeek (17278), switchWeek (20175), mergeSyncData (20727) — but **none closes the r3 move dialog or clears `_r3Dlg`**. `_r3DlgAct` (12161) then calls `_r3ExecMove` → `swapMeals` with **no re-validation**: `_moveEligible` is not re-run and the armed state is not checked; `cfg.src`/`cfg.dest` are pre-mutation coordinates.
*Reachability*: the backdrop blocks user-initiated paths (week pills, settings), but a **background sync merge** lands while the dialog is open; the user then clicks "Clear those leftovers" and swapMeals executes on merged state with stale coordinates — wrong slots swapped, orphans computed against pre-merge geometry (data loss via the clear path).

## A16-3 · MEDIUM — leftoverLinks sync is whole-array LWW, but V282 made groups authoritative batch definitions

Groups merge as a whole array per week via `leftoverLinksTs` (20504–20517, V140), and `autoSaveWeek` stamps that ts on **every** save whether or not groups changed (20094–20099) — while SEL/MANUAL_SET merge per-key. Household race: device A's ⇄ move materializes a beyond-window batch group; device B (not yet pulled) makes any unrelated edit afterwards → B's array ts is newer → B's group array (lacking A's group) wins whole-array on merge while A's SEL move survives per-key. The moved leftover now sits beyond the window with **no group** → detector Phase 0 doesn't know it → new-cook reclassification, shopping double-buy, INV14 — the exact class V282 exists to prevent, resurrected by sync. (V140's design was correct when groups were visual-only; V282 upgraded their authority without upgrading their sync granularity.)

## A16-4 · MEDIUM — INV23/INV25 blind spot: the Shared-tab combined rows are an edit surface with no invariant coverage

INV23's gate excludes shared batches outright: `!(lo23.shared || lo23.sameDayShared)` (8041–8043); INV25 similarly never walks the Shared-tab combined view. That was acceptable when the Shared tab was display-only — but V295/V304 made its combined rows **editable** (the only edit surface for same-day shared cooks, per the ownership rules). A rounding/divergence regression in `renderSharedCard`/`buildIngrEditRow('combined')` on that surface can never fire an invariant — the dead-invariant pattern (R14's recurring defect class) applied to the app's newest edit surface. V304's manual end-to-end check verified it once; nothing guards it going forward.

## A16-5 · LOW — move-clear can shrink a group to one slot; the validator keeps it

`_r3ClearPortion` splices cleared slots from groups; a Clear that removes all leftovers leaves `[cook]` alone. `_validateManualLinkGroups` (3235–3253) only removes **empty** groups — a 1-slot group persists, rendering a stray band on a single cell and hoarding a palette color under strict no-reuse — the same hoarding R15-l4 was built to stop (12241 comment).

## A16-6 · LOW — `_r3MoveChoice` is not throw-safe

`_r3ExecMove` (12134–12141) sets the choice, calls swapMeals, and resets after — no try/finally; swapMeals' own reset (12266) sits mid-body after two early returns. Any throw between set and consume leaves `'clear'` armed, and the **next** swapMeals call from anywhere orphans without a prompt. No throw path is currently known; per the repo's no-"can't happen" rule, recorded as a defensive gap.

## A16-7 · LOW — harness: `freshRestore` doesn't reset `_movePending`

Ops null it on their happy paths (24988–25219) and fact/edit-mode globals are reset per scenario (V304/V83c), but a mid-op throw between arm and complete leaks an armed move into subsequent restored scenarios (stray ⤓ eligibility, altered renders). `_r3Dlg` is unreachable under `_suppressR3MoveDialog`; `_r3MoveChoice` self-resets per swap — only `_movePending` needs the reset.

---

## Verified clean (checked, no finding)

- **Solo × orphan**: Phase 0 and Phase 1 both gate through `getMealId` (4795, 4840) → a disabled person's slots never become detector portions → orphan captures cannot touch preserved data. The SEL-strict validator (3247) keeps their group membership intact while disabled.
- **Materialize merge two-batch fusion**: `existingG` requires the group to contain the *anchor key* (12006–12008) and `anchorLo.portions` is a single detector batch — same-meal batches cannot fuse; the 6-cap is enforced at Phase-0 consumption (4804).
- **`_r3AnchorKeyOf` on sameDayShared leftovers**: correct (blocks a shared portion moving ahead of its cook slot).
- **Pipeline drift V274→HEAD**: 172 functions changed; exactly 17 are pipeline-family and every one maps 1:1 to a documented V275–V307 item (Phase 0 → V282; fact machinery → V283/V284; solo/carry gates → V279; `_lateSnackFor` mirrors → V279; INV3FactStranded → V283). **No undocumented pipeline change.**
- **`_movePending` disarm coverage** (for the armed-move state itself): all five l1/l2 sites present and correct — the gap is the *dialog* layer above it (A16-2), not the arm.
