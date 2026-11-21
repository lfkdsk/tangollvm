; RUN: opt < %s -passes='sroa<modify-cfg>' -S | FileCheck --check-prefixes=CHECK,CHECK-SROA %s
; RUN: opt < %s -passes=mem2reg -S | FileCheck %s
; RUN: opt < %s -passes=instcombine -S | FileCheck --check-prefixes=CHECK,CHECK-IC %s
;
; LTOPANIC1/SROA1: an alloca carrying frontend Go stack-object metadata must
; survive every promotion/removal path in a Go (gc "go") function: SROA
; (including secondary worklist enqueues while splitting a neighboring alloca),
; mem2reg (isAllocaPromotable) and InstCombine's alloca removal
; (isAllocSiteRemovable). The runtime stack copier resolves interior stack
; pointers through the frame slot described by this record, so promoting the
; alloca to SSA and dropping go.stackobject.gcdata would emit a mismatched
; stack-object record and leave a stale interior pointer after a stack move.
; Plain allocas without the metadata are still optimized normally.

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S64-v128:64:64-z1"
target triple = "x86_64-unknown-linux-goabi"

%T = type { ptr, i64 }

declare cc 113 void @safepoint()
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

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

; A plain splittable alloca feeds an annotated destination through a memcpy.
; SROA splits the source and enqueues the annotated destination via its
; secondary worklist, bypassing an entry-block-only guard. The metadata alloca
; must survive and never appear as .sroa partitions (regression for the first
; fix, which only skipped the annotated alloca in the entry scan).
define cc 113 i64 @go_stackobject_memcpy_split(ptr %p, i64 %v) gc "go" {
entry:
  %src = alloca %T, align 8
  %dst = alloca %T, align 8, !go.stackobject.gcdata !0
  store ptr %p, ptr %src, align 8
  %sfield = getelementptr inbounds %T, ptr %src, i32 0, i32 1
  store i64 %v, ptr %sfield, align 8
  call cc 113 void @safepoint()
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 16, i1 false)
  %dfield = getelementptr inbounds %T, ptr %dst, i32 0, i32 1
  %read = load i64, ptr %dfield, align 8
  call cc 113 void @safepoint()
  ret i64 %read
}
; CHECK-LABEL: define gointernal i64 @go_stackobject_memcpy_split
; CHECK: %dst = alloca %T, align 8, !go.stackobject.gcdata
; CHECK-NOT: alloca .*\.sroa\.
; CHECK: ret i64

; Whole-type direct loads/stores make this alloca mem2reg-promotable. The
; isAllocaPromotable guard must keep it as a frame slot in a Go function.
define cc 113 void @go_direct_m2r(ptr %p, i64 %v, ptr %out) gc "go" {
entry:
  %o = alloca %T, align 8, !go.stackobject.gcdata !0
  %v0 = insertvalue %T poison, ptr %p, 0
  %v1 = insertvalue %T %v0, i64 %v, 1
  store %T %v1, ptr %o, align 8
  call cc 113 void @safepoint()
  %r = load %T, ptr %o, align 8
  store %T %r, ptr %out, align 8
  ret void
}
; CHECK-LABEL: define gointernal void @go_direct_m2r
; CHECK: %o = alloca %T, align 8, !go.stackobject.gcdata
; CHECK: ret void

; The guard is Go-specific: the same alloca in a non-Go function is removed by
; SROA (which can scalarize the inner GEP) and by InstCombine.
define void @plain_function_promoted(i64 %v) {
entry:
  %obj = alloca %T, align 8, !go.stackobject.gcdata !0
  %field = getelementptr inbounds %T, ptr %obj, i32 0, i32 1
  store i64 %v, ptr %field, align 8
  %read = load i64, ptr %field, align 8
  store i64 %read, ptr @sink, align 8
  ret void
}
; CHECK-SROA-LABEL: define void @plain_function_promoted
; CHECK-SROA-NOT: alloca %T
; CHECK-IC-LABEL: define void @plain_function_promoted
; CHECK-IC-NOT: alloca %T

; A direct-use alloca in a non-Go function is mem2reg-promotable (the GEP form
; above is only scalarizable by SROA), proving the mem2reg guard is Go-specific.
define i64 @plain_direct_promoted(i64 %v) {
entry:
  %o = alloca i64, align 8
  store i64 %v, ptr %o, align 8
  %r = load i64, ptr %o, align 8
  ret i64 %r
}
; CHECK-LABEL: define i64 @plain_direct_promoted
; CHECK-NOT: alloca i64
; CHECK: ret i64

@sink = external global i64

!0 = !{i64 16, i64 8, !"type:T"}
; CHECK: ![[MD]] = !{i64 16, i64 8, !"type:T"}
