# TODOS

## Selection sort DRY refactor
**What:** Extract a generic `sort_by(slice, less_proc)` helper to replace 5 identical O(n^2) selection sort implementations with inline swaps.
**Why:** Any sort behavior change requires editing 5 places (lines ~1529, 1937, 2011, 3075, 3760). DRY violation.
**Pros:** Single sort implementation, easier to upgrade to a better algorithm later.
**Cons:** Odin's generics require care; may need a macro or proc-group pattern.
**Context:** Found during eng review 2026-03-25. Not blocking any planned feature. Each instance sorts a different element type but identical logic. Could also consider using `core:slice.sort_by`.
**Depends on:** Nothing. Can be done independently.
