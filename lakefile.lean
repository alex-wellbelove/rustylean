import Lake
open Lake DSL

package «unique-check» where
  leanOptions := #[⟨`autoImplicit, false⟩]

lean_lib UniqueCheck
lean_lib UniqueAttr
lean_lib UniqueAnalysis

@[default_target]
lean_exe «demo» where
  root := `Main

target ffi.o (pkg : NPackage __name__) : System.FilePath := do
  let oFile := pkg.buildDir / "ffi.o"
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "unique_check.c"
  buildFileAfterDep oFile srcJob fun srcFile => do
    compileO oFile srcFile #["-I", (← getLeanIncludeDir).toString, "-fPIC"]

extern_lib ffi (pkg : NPackage __name__) := do
  let name := nameToStaticLib "ffi"
  let ffiO ← fetch <| pkg.target ``ffi.o
  buildStaticLib (pkg.buildDir / "lib" / name) #[ffiO]
