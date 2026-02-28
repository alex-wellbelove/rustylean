/-
  UniqueAttr: registers the @[unique] tag attribute for types that require
  unique ownership (no aliasing). Used by UniqueAnalysis to detect
  compile-time uniqueness violations.
-/
import Lean

open Lean in
initialize uniqueAttr : TagAttribute ←
  registerTagAttribute `unique "marks a type as requiring unique ownership (no aliasing)"

def hasUniqueAttr (env : Lean.Environment) (typeName : Lean.Name) : Bool :=
  uniqueAttr.hasTag env typeName
