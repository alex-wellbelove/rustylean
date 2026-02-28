/-
  UniqueCheck: Runtime uniqueness checking for Lean 4

  Lean 4 has no compile-time uniqueness guarantees. FFI resource handles
  (sockets, DB connections) can be silently aliased, leading to use-after-free
  segfaults. This module provides a runtime safety net: loud errors instead
  of silent corruption.

  The core primitive `isExclusiveFFI` is implemented via a C shim that uses
  `b_lean_obj_arg` (borrowed parameter) to check the refcount without
  incrementing it. It returns `BaseIO Bool` rather than pure `Bool` to
  prevent the compiler from CSE-ing multiple calls — the refcount is
  mutable runtime state that changes between checks.
-/


/-- FFI: check if a value is exclusively referenced (RC == 1).
    Uses borrowed parameter in C (`b_lean_obj_arg`) so the check itself
    doesn't bump the refcount. Returns `BaseIO Bool` because the refcount
    is mutable state — a pure signature would let the compiler merge calls. -/
@[extern "lean_unique_check_is_exclusive"]
opaque isExclusiveFFI {α : Type} (a : @& α) : BaseIO Bool

-- ============================================================================
-- § 1. ensureExclusive — panics if aliased
-- ============================================================================

/-- Check that `a` is uniquely referenced. Throws `IO.Error` if the value
    is aliased (refcount > 1). Returns the value unchanged. -/
def ensureExclusive {α : Type} (label : String) (a : @& α) : IO α := do
  if ← isExclusiveFFI a then return a
  else throw (IO.Error.userError
    s!"uniqueness violation: `{label}` is aliased (refcount > 1)")

-- ============================================================================
-- § 2. assertExclusive — alias for ensureExclusive
-- ============================================================================

/-- Alias for `ensureExclusive`. Checks that `a` is uniquely referenced
    and throws `IO.Error` if not. -/
def assertExclusive {α : Type} (label : String) (a : @& α) : IO α :=
  ensureExclusive label a

-- ============================================================================
-- § 3. withResource — bracket pattern
-- ============================================================================

/-- Safe acquire/use/release pattern that checks exclusivity before releasing.
    Catches "resource smuggling" where `action` stores a reference to the
    resource, which would cause use-after-free on release. -/
def withResource {α β : Type}
    (acquire : IO α) (release : α → IO Unit) (label : String)
    (action : α → IO β) : IO β := do
  let resource ← acquire
  let result ← action resource
  -- If action smuggled a reference, resource's RC > 1
  if !(← isExclusiveFFI resource) then
    throw (IO.Error.userError
      s!"uniqueness violation: `{label}` was smuggled out of withResource")
  release resource
  pure result
