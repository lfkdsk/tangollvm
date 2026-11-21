; Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; Copyright (c) 2026 ByteDance Ltd. and/or its affiliates.

; The Go frontend emits one llvm.go.preallocated per stack slot, with its first
; operand being the alloca that owns the slot. A by-value receiver copied into
; a field of another stack object produces
;
;   %p = alloca Inner
;   call go.preallocated(Inner)(ptr %p, ...)
;   memcpy(gep %opts, Field, ptr %p, sizeof Inner)
;
; MemCpyOptimizer's call-slot optimization used to forward the preallocated
; operand from %p to the field GEP, leaving a non-alloca operand that
; GoStatepoints cannot legalize and that aborts instruction selection with
; "all associated alloca must be eliminated before gc-statepoints"
; (CockroachDB pkg/util/tracing remoteParent.apply). The guard keeps the
; frontend alloca as the preallocated operand.

; RUN: opt < %s -O3 -S | FileCheck %s
; REQUIRES: x86-registered-target

target triple = "x86_64-unknown-linux-goabi"

%Inner = type { i64, i64, ptr }
%Outer = type { ptr, %Inner, i64 }

declare ptr @llvm.go.preallocated.p0.p0.s_Inners(ptr, i64 immarg, i64 immarg, %Inner, i1 immarg)
declare ptr @llvm.go.preallocated.p0.p0.s_Outers(ptr, i64 immarg, i64 immarg, %Outer, i1 immarg)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr, ptr, i64, i1 immarg)

define cc 113 void @f() gc "go" {
entry:
  %opts = alloca %Outer, align 8
  %0 = call ptr @llvm.go.preallocated.p0.p0.s_Outers(ptr %opts, i64 24, i64 40, %Outer zeroinitializer, i1 false)
  %p = alloca %Inner, align 8
  %pa = call ptr @llvm.go.preallocated.p0.p0.s_Inners(ptr %p, i64 0, i64 24, %Inner zeroinitializer, i1 false)
  %out = call ptr @llvm.go.preallocated.p0.p0.s_Outers(ptr null, i64 64, i64 40, %Outer zeroinitializer, i1 true)
  %dst = getelementptr i8, ptr %opts, i64 8
  call void @llvm.memcpy.inline.p0.p0.i64(ptr %dst, ptr %p, i64 24, i1 false)
  call void @llvm.memcpy.inline.p0.p0.i64(ptr %out, ptr %opts, i64 40, i1 false)
  ret void
}

; The Inner alloca must survive and remain the operand of its preallocated.
; CHECK-LABEL: define gointernal void @f(
; CHECK: [[P:%[A-Za-z0-9._]+]] = alloca %Inner
; CHECK: call ptr @llvm.go.preallocated{{.*}}s_Inners(ptr nonnull [[P]],
; The field-copy memcpy is kept rather than folded into the preallocated.
; CHECK: call void @llvm.memcpy.inline
