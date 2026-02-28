/-
  UniqueAnalysis: LCNF compiler pass for compile-time uniqueness analysis.

  Key insight: LCNF erases types to `lcAny`, so we cannot determine uniqueness
  from variable types. Instead, we look up the callee's **original** type from
  the environment to determine which parameter positions expect @[unique] types.

  When a variable is passed to a unique-consuming position, it is "consumed".
  If the same variable is consumed again, that's a use-after-consume violation (V2).

  The pass runs after the first `simp` (which inlines monadic bind into cases),
  so the IR is in a nice flat form with explicit cases on EST.Out.
-/
import UniqueAttr
import Lean.Compiler.LCNF.PassManager
import Lean.Compiler.LCNF.Passes
import Lean.Compiler.LCNF.PhaseExt

open Lean Lean.Compiler.LCNF

namespace UniqueAnalysis

/-- Check if a type expression directly refers to a @[unique] type name.
    Only checks the head constant — does not look through type variables. -/
def exprMentionsUnique (env : Environment) (type : Expr) : Bool :=
  match type.getAppFn with
  | .const name _ => hasUniqueAttr env name
  | _ => false

/-- Extract the domain types from a forall/pi type, paired with their positions.
    Returns an array of (position, domain_type) pairs. -/
def extractForallDomains (type : Expr) : Array (Nat × Expr) :=
  go type 0 #[]
where
  go (t : Expr) (idx : Nat) (acc : Array (Nat × Expr)) : Array (Nat × Expr) :=
    match t with
    | .forallE _ d b _ => go b (idx + 1) (acc.push (idx, d))
    | _ => acc

/-- For a function with the given original type, return the set of parameter
    positions (0-indexed) that have @[unique] domain types. -/
def getUniqueParamPositions (env : Environment) (type : Expr) : Array Nat :=
  (extractForallDomains type).filterMap fun (idx, domType) =>
    if exprMentionsUnique env domType then some idx else none

/-- Analysis state: tracks which fvarIds have been consumed (passed as an
    owned argument to a function expecting a @[unique] parameter). -/
structure AnalysisState where
  /-- Map from consumed fvarId to the callee name that consumed it. -/
  consumed : Std.HashMap FVarId Name := {}
  /-- Map from fvarId to its binder name (for diagnostics). -/
  names : Std.HashMap FVarId Name := {}

abbrev AnalysisM := StateRefT AnalysisState CompilerM

/-- Record a binder name for an fvarId. -/
def recordName (fvarId : FVarId) (name : Name) : AnalysisM Unit :=
  modify fun s => { s with names := s.names.insert fvarId name }

/-- Get a display name for a variable. -/
def displayName (fvarId : FVarId) : AnalysisM Name := do
  return (← get).names[fvarId]?.getD fvarId.name

/-- Check if a variable has been consumed. -/
def isConsumed (fvarId : FVarId) : AnalysisM Bool :=
  return (← get).consumed.contains fvarId

/-- Mark a variable as consumed by a given callee. -/
def markConsumed (fvarId : FVarId) (calleeName : Name) : AnalysisM Unit :=
  modify fun s => { s with consumed := s.consumed.insert fvarId calleeName }

/-- Analyze a function call `calleeName args` for uniqueness violations.
    Looks up the callee's original type to find which positions are @[unique]. -/
def analyzeCall (calleeName : Name) (args : Array Arg)
    (fnDeclName : Name) : AnalysisM Unit := do
  let env ← getEnv
  let some ci := env.find? calleeName | return ()
  let uniquePositions := getUniqueParamPositions env ci.type
  for pos in uniquePositions do
    if h : pos < args.size then
      match args[pos] with
      | .fvar argFvarId =>
        let prevConsumer := (← get).consumed[argFvarId]?
        if let some prevCallee := prevConsumer then
          let argName ← displayName argFvarId
          logWarning m!"[unique] use-after-consume in `{fnDeclName}`: unique value `{argName}` was already consumed by `{prevCallee}`, now passed to `{calleeName}`"
        markConsumed argFvarId calleeName
      | _ => pure ()

/-- Walk LCNF Code recursively, analyzing for uniqueness violations. -/
partial def analyzeCode (code : Code) (fnDeclName : Name) : AnalysisM Unit := do
  match code with
  | .let decl k =>
    -- Record the binder name for diagnostics
    recordName decl.fvarId decl.binderName
    -- Analyze the value
    match decl.value with
    | .const calleeName _ args =>
      analyzeCall calleeName args fnDeclName
    | .fvar _ _ =>
      -- Indirect call through fvar — skip (avoid false positives)
      pure ()
    | _ => pure ()
    analyzeCode k fnDeclName
  | .fun funDecl k =>
    recordName funDecl.fvarId funDecl.binderName
    analyzeCode funDecl.value fnDeclName
    analyzeCode k fnDeclName
  | .jp funDecl k =>
    recordName funDecl.fvarId funDecl.binderName
    analyzeCode funDecl.value fnDeclName
    analyzeCode k fnDeclName
  | .cases cases =>
    for alt in cases.alts do
      match alt with
      | .alt _ params body =>
        for p in params do
          recordName p.fvarId p.binderName
        analyzeCode body fnDeclName
      | .default body =>
        analyzeCode body fnDeclName
      -- Note: we don't restore state between branches because in the
      -- common sequential pattern (cases on IO result), the branches
      -- are mutually exclusive and only one continues. For a more
      -- precise analysis, we'd need to merge branch states.
  | .return _ | .unreach _ | .jmp _ _ => pure ()

/-- Analyze a single LCNF declaration. -/
def analyzeDecl (decl : Decl) : CompilerM Unit := do
  let st : AnalysisState := {}
  -- Record parameter names
  let st := decl.params.foldl (init := st) fun s p =>
    { s with names := s.names.insert p.fvarId p.binderName }
  match decl.value with
  | .code code =>
    let _ ← (analyzeCode code decl.name).run st
  | .extern _ => pure ()

/-- The compiler pass: runs analysis on each declaration, emitting warnings
    but returning declarations unchanged. -/
def uniqueAnalysisPassImpl (decls : Array Decl) : CompilerM (Array Decl) := do
  for decl in decls do
    analyzeDecl decl
  return decls

end UniqueAnalysis

/-- Install the uniqueness analysis pass after the first `simp` in the base phase.
    At this point, monadic bind has been inlined into cases on EST.Out,
    giving us flat sequential code to analyze. -/
@[cpass] unsafe def uniqueAnalysisInstaller : PassInstaller :=
  .installAfter .base `simp fun _ => {
    phase := .base
    name := `uniqueAnalysis
    run := UniqueAnalysis.uniqueAnalysisPassImpl
  }
