; RUN: llc -mtriple=x86_64-linux-gnu < %s | FileCheck %s

declare cc 113 void @callee()

define cc 113 void @system_stack() "go-cfunc"="true" "go-sym-morestack"="runtime.morestackc..abi0" gc "go" !go.caller.args.area !0 {
; CHECK-LABEL: system_stack:
; CHECK: callq runtime.morestackc..abi0
; CHECK: cmpq 24(%r14), %rsp
  call cc 113 void @callee()
  ret void
}

define cc 113 void @user_stack() gc "go" !go.caller.args.area !0 {
; CHECK-LABEL: user_stack:
; CHECK: callq runtime.morestack_noctxt
; CHECK: cmpq 16(%r14), %rsp
  call cc 113 void @callee()
  ret void
}

!0 = !{i64 0, i64 0}
