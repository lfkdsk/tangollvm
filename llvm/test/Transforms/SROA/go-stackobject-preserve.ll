; RUN: opt < %s -passes='sroa<modify-cfg>' -S | FileCheck %s
;
; LTOPANIC1: an alloca carrying frontend Go stack-object metadata must survive
; SROA/mem2reg in a Go (gc "go") function. The runtime stack copier resolves
; interior stack pointers through the frame slot described by this record, so
; promoting the alloca to SSA and dropping go.stackobject.gcdata would emit a
; mismatched stack-object record and leave a stale interior pointer after a
; stack move. A plain promotable alloca without the metadata is still promoted.

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S64-v128:64:64-z1"
target triple = "x86_64-unknown-linux-goabi"

%T = type { ptr, i64 }

declare cc 113 void @safepoint()

; The metadata-bearing alloca is only used by direct, matching loads/stores,
; so without the guard it is mem2reg-promotable.
define cc 113 void @go_stackobject_kept(i64 %v) gc "go" {
entry:
  %obj = alloca %T, align 8, !go.stackobject.gcdata !0
  %field = getelementptr inbounds %T, ptr %obj, i32 0, i32 1
  store i64 %v, ptr %field, align 8
  call cc 113 void @safepoint()
  %read = load i64, ptr %field, align 8
  %plain = alloca i64, align 8
  store i64 %read, ptr %plain, align 8
  ret void
}
; CHECK-LABEL: define gointernal void @go_stackobject_kept
; CHECK: %obj = alloca %T, align 8, !go.stackobject.gcdata ![[MD:[0-9]+]]
; CHECK-NOT: %plain = alloca
; CHECK: ret void

; The guard is Go-specific: the same alloca in a non-Go function promotes.
define void @plain_function_promoted(i64 %v) {
entry:
  %obj = alloca %T, align 8, !go.stackobject.gcdata !0
  %field = getelementptr inbounds %T, ptr %obj, i32 0, i32 1
  store i64 %v, ptr %field, align 8
  %read = load i64, ptr %field, align 8
  store i64 %read, ptr @sink, align 8
  ret void
}
; CHECK-LABEL: define void @plain_function_promoted
; CHECK-NOT: alloca %T

@sink = external global i64

!0 = !{i64 16, i64 8, !"type:T"}
; CHECK: ![[MD]] = !{i64 16, i64 8, !"type:T"}
