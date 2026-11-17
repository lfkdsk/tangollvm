; Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; Copyright (c) 2026 ByteDance Ltd. and/or its affiliates.

; Growing the outgoing area is only safe for compiler-generated runtime
; helpers (runtime.memmove / runtime.memclrNoHeapPointers / panic bounds).
; A regular Go call that needs an area the frontend did not declare is still a
; frontend bug and must keep failing the sanity check.

; RUN: not --crash llc -mtriple=x86_64-unknown-linux-goabi -filetype=obj -o /dev/null %s 2>&1 | FileCheck %s
; CHECK: bad callee args area

declare cc 113 void @other.call()

define cc 113 void @unexpected() gc "go" {
  call cc 113 void @other.call() #0
  ret void
}

attributes #0 = { "go.caller.area"="8" }
