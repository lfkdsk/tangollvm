; TangoLLVM full LTO runs `default<O3>,lto<O3>` in one opt invocation; both
; pipeline builders end with a CGProfilePass. Module::addModuleFlag never merges
; flags inside one module, so the second pass used to append a duplicate
; "CG Profile" flag and the verifier aborted with
; "module flag identifiers must be unique (or of 'require' type)".
; The pass must reuse the existing flag and extend its tuple instead.
;
; RUN: opt -passes=cg-profile,cg-profile -o %t.bc %s
; RUN: llvm-dis %t.bc -o - | FileCheck %s
; RUN: llvm-dis %t.bc -o - | grep -c '!"CG Profile"' | FileCheck %s --check-prefix=ONE
; ONE: 1

; CHECK: !llvm.module.flags = !{![[FLAG:[0-9]+]]}
; CHECK: ![[FLAG]] = !{i32 5, !"CG Profile", ![[TUP:[0-9]+]]}
; CHECK: ![[TUP]] = distinct !{![[EDGE:[0-9]+]], ![[EDGE]]}
; CHECK: ![[EDGE]] = !{ptr @foo, ptr @bar, i64 2753}

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define void @foo() !prof !0 {
  call void @bar()
  ret void
}

declare void @bar()

!0 = !{!"function_entry_count", i64 2753}
