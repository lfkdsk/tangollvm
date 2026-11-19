; RUN: llc -mtriple=x86_64-linux-gnu < %s | FileCheck %s

define cc 113 i64 @split_leaf(i64 %x) "go-preserve-split"="true" gc "go" !go.caller.args.area !0 {
; CHECK-LABEL: split_leaf:
; CHECK: callq runtime.morestack_noctxt
  %y = add i64 %x, 1
  ret i64 %y
}

define cc 113 i64 @ordinary_leaf(i64 %x) gc "go" !go.caller.args.area !0 {
; CHECK-LABEL: ordinary_leaf:
; CHECK-NOT: morestack
; CHECK: retq
; CHECK-NOT: morestack
  %y = add i64 %x, 1
  ret i64 %y
}

!0 = !{i64 0, i64 0}
