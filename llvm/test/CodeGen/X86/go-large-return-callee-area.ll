; Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; Copyright (c) 2026 ByteDance Ltd. and/or its affiliates.

; The Go frontend only emits !go.callee.args.area when a Go-level call needs an
; outgoing argument area. Optimizations can regenerate memory intrinsics for a
; large struct copy; GoStatepoints lowers them to runtime.memmove /
; runtime.memclrNoHeapPointers calls whose area the frontend never accounted
; for. The pass must grow (or create) the area instead of aborting, while an
; unrelated call still trips the sanity check (see the -bad companion file).
; GoStatepoints runs before instruction selection, so a prologepilog dump is
; enough to exercise it and to observe the rewritten function metadata.

; RUN: llc -mtriple=x86_64-unknown-linux-goabi -stop-after=prologepilog -o - %s | FileCheck %s

%Config = type { [1024 x i8], i1 }

declare cc 113 ptr @newConfig()
declare ptr @llvm.go.preallocated.p0.p0.s_Configs(ptr, i64 immarg, i64 immarg, %Config, i1 immarg)
declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1 immarg)
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1 immarg)

; No !go.callee.args.area: only a zero-arg Go call exists at the source level.
; The 1024-byte copy is lowered to runtime.memmove (area 24), so the pass must
; create the metadata rather than report "bad callee args area: should be zero".
; CHECK: define gointernal void @updated(
; CHECK-SAME: !go.callee.args.area ![[MOVE:[0-9]+]]
define cc 113 void @updated() gc "go" !go.caller.args.area !0 {
  %result = call ptr @llvm.go.preallocated.p0.p0.s_Configs(ptr null, i64 0, i64 1025, %Config zeroinitializer, i1 true)
  %src = call cc 113 ptr @newConfig()
  call void @llvm.memmove.p0.p0.i64(ptr %result, ptr %src, i64 1024, i1 false)
  ret void
}

; A memset with a non-constant length becomes runtime.memclrNoHeapPointers
; (area 16); the declared area of 8 is too small and must be grown to 16.
; CHECK: define gointernal void @clear(
; CHECK-SAME: !go.callee.args.area ![[CLR:[0-9]+]]
define cc 113 void @clear(ptr %dst, i64 %len) gc "go" !go.callee.args.area !1 {
  call void @llvm.memset.p0.i64(ptr %dst, i8 0, i64 %len, i1 false)
  ret void
}

; The declared area (32) already covers the memmove area (24): leave it alone.
; CHECK: define gointernal void @keep_larger(
; CHECK-SAME: !go.callee.args.area ![[BIG:[0-9]+]]
define cc 113 void @keep_larger(ptr %dst, ptr %src) gc "go" !go.callee.args.area !2 {
  call void @llvm.memmove.p0.p0.i64(ptr %dst, ptr %src, i64 1024, i1 false)
  ret void
}

; Metadata node values (the pass creates ![[MOVE]], grows ![[CLR]], keeps ![[BIG]]).
; CHECK-DAG: ![[MOVE]] = !{i64 24, i64 24}
; CHECK-DAG: ![[CLR]] = !{i64 16, i64 16}
; CHECK-DAG: ![[BIG]] = !{i64 32, i64 32}

; The lowered helpers get real statepoints in the machine IR.
; CHECK-LABEL: name: {{.*}}updated
; CHECK: STATEPOINT {{.*}}@runtime.memmove
; CHECK-LABEL: name: {{.*}}clear
; CHECK: STATEPOINT {{.*}}@runtime.memclrNoHeapPointers
; CHECK-LABEL: name: {{.*}}keep_larger
; CHECK: STATEPOINT {{.*}}@runtime.memmove

!0 = !{i64 1032, i64 1032}
!1 = !{i64 8, i64 8}
!2 = !{i64 32, i64 32}
