; RUN: llc -mtriple=x86_64-linux-gnu -go-align-pgo-hot-loops < %s | FileCheck %s --check-prefixes=CHECK,ON
; RUN: llc -mtriple=x86_64-linux-gnu < %s | FileCheck %s --check-prefixes=CHECK,OFF
; RUN: sed '/^!llvm.module.flags/d' %s | llc -mtriple=x86_64-linux-gnu -go-align-pgo-hot-loops | FileCheck %s --check-prefixes=CHECK,NOPROF
; RUN: sed '/^!llvm.module.flags/d' %s | llc -mtriple=x86_64-linux-gnu -go-align-pgo-hot-loops -go-loop-align-bytes=64 | FileCheck %s --check-prefixes=CHECK,A64
; RUN: llc -mtriple=x86_64-linux-gnu -go-align-go-functions < %s | FileCheck %s --check-prefixes=CHECK,FUNC
; RUN: not --crash llc -mtriple=x86_64-linux-gnu -go-align-pgo-hot-loops -go-loop-align-bytes=8 < %s 2>&1 | FileCheck %s --check-prefix=BADVAL

; BADVAL: -go-loop-align-bytes must be a power of two between 16 and 64

; CHECK: .globl hot_go
; ON: .p2align 5, 0x90
; OFF: .p2align 4, 0x90
; NOPROF: .p2align 5, 0x90
; A64: .p2align 6, 0x90
; FUNC: .p2align 5, 0x90
; CHECK-LABEL: hot_go:
; ON: .p2align 5, 0x90
; OFF: .p2align 4, 0x90
; NOPROF: .p2align 5, 0x90
; A64: .p2align 6, 0x90
; FUNC: .p2align 4, 0x90
; CHECK-NEXT: .LBB{{[0-9]+}}_{{[0-9]+}}:{{.*}}%loop
define i64 @hot_go(ptr %p, i64 %n) nounwind gc "go" !prof !20 {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %v = load volatile i64, ptr %p
  %next = add i64 %i, 1
  %cond = icmp ult i64 %next, %n
  br i1 %cond, label %loop, label %exit, !prof !22
exit:
  ret i64 %v
}

; Profile present: a cold entry stays at the default 16 B even with the loop
; option. With no summary every innermost Go loop qualifies.
; CHECK: .globl cold_go
; ON: .p2align 4, 0x90
; OFF: .p2align 4, 0x90
; NOPROF: .p2align 5, 0x90
; A64: .p2align 6, 0x90
; FUNC: .p2align 5, 0x90
; CHECK-LABEL: cold_go:
; ON: .p2align 4, 0x90
; OFF: .p2align 4, 0x90
; NOPROF: .p2align 5, 0x90
; A64: .p2align 6, 0x90
; FUNC: .p2align 4, 0x90
; CHECK-NEXT: .LBB{{[0-9]+}}_{{[0-9]+}}:{{.*}}%loop
define i64 @cold_go(ptr %p, i64 %n) nounwind gc "go" !prof !21 {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %v = load volatile i64, ptr %p
  %next = add i64 %i, 1
  %cond = icmp ult i64 %next, %n
  br i1 %cond, label %loop, label %exit, !prof !22
exit:
  ret i64 %v
}

; Non-Go functions are never touched by either knob.
; CHECK: .globl hot_native
; ON: .p2align 4, 0x90
; OFF: .p2align 4, 0x90
; NOPROF: .p2align 4, 0x90
; A64: .p2align 4, 0x90
; FUNC: .p2align 4, 0x90
; CHECK-LABEL: hot_native:
; ON: .p2align 4, 0x90
; OFF: .p2align 4, 0x90
; NOPROF: .p2align 4, 0x90
; A64: .p2align 4, 0x90
; FUNC: .p2align 4, 0x90
; CHECK-NEXT: .LBB{{[0-9]+}}_{{[0-9]+}}:{{.*}}%loop
define i64 @hot_native(ptr %p, i64 %n) nounwind !prof !20 {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %v = load volatile i64, ptr %p
  %next = add i64 %i, 1
  %cond = icmp ult i64 %next, %n
  br i1 %cond, label %loop, label %exit, !prof !22
exit:
  ret i64 %v
}

; A hot entry can have an infrequently entered loop. Its cold header is
; skipped even without a profile, so no loop directive is emitted; only the
; function knob moves the entry.
; CHECK: .globl cold_loop
; ON: .p2align 4, 0x90
; OFF: .p2align 4, 0x90
; NOPROF: .p2align 4, 0x90
; A64: .p2align 4, 0x90
; FUNC: .p2align 5, 0x90
; CHECK-LABEL: cold_loop:
; ON-NOT: .p2align 5
; OFF-NOT: .p2align 5
; NOPROF-NOT: .p2align 5
; A64-NOT: .p2align 6
; FUNC-NOT: .p2align 5
; CHECK: .LBB{{[0-9]+}}_{{[0-9]+}}:{{.*}}%loop
define i64 @cold_loop(ptr %p, i1 %enter, i64 %n) nounwind gc "go" !prof !20 {
entry:
  br i1 %enter, label %loop, label %exit, !prof !23
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %v = load volatile i64, ptr %p
  %next = add i64 %i, 1
  %cond = icmp ult i64 %next, %n
  br i1 %cond, label %loop, label %exit, !prof !22
exit:
  %result = phi i64 [ 0, %entry ], [ %v, %loop ]
  ret i64 %result
}

!llvm.module.flags = !{!0}
!0 = !{i32 1, !"ProfileSummary", !1}
!1 = !{!2, !3, !4, !5, !6, !7, !8, !9}
!2 = !{!"ProfileFormat", !"SampleProfile"}
!3 = !{!"TotalCount", i64 1000000}
!4 = !{!"MaxCount", i64 100000}
!5 = !{!"MaxInternalCount", i64 100000}
!6 = !{!"MaxFunctionCount", i64 10000}
!7 = !{!"NumCounts", i64 100}
!8 = !{!"NumFunctions", i64 3}
!9 = !{!"DetailedSummary", !10}
!10 = !{!11, !12, !13}
!11 = !{i32 990000, i64 1000, i32 10}
!12 = !{i32 999999, i64 1, i32 100}
!13 = !{i32 1000000, i64 1, i32 100}
!20 = !{!"function_entry_count", i64 10000}
!21 = !{!"function_entry_count", i64 1}
!22 = !{!"branch_weights", i32 31, i32 1}
!23 = !{!"branch_weights", i32 1, i32 10000000}
