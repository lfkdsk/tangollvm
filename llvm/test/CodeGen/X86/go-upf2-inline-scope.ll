; RUN: opt -passes=always-inline -S %s | FileCheck %s
;
; UPF2: inlining a go.allunsafe callee into a caller that is not itself
; runtime/nosplit must no longer copy the whole-function attribute onto the
; caller. The callee identity is recorded in go.allunsafe.inline instead, so
; the backend can keep only the inlined scope non-preemptible. Both emitted
; attribute values take the scoped path; a caller that is already allunsafe
; keeps the whole-function policy; a scope list on an intermediate callee is
; propagated through nested inlining.

target triple = "x86_64-unknown-linux-goabi"

; CHECK-LABEL: define gointernal i64 @normal_caller(
; CHECK-SAME: !go.allunsafe.inline [[SCOPED:![0-9]+]]
; CHECK-NOT: "go.allunsafe"
; CHECK: }
define cc 113 i64 @normal_caller(i64 %x) gc "go" !dbg !13 {
entry:
  %r1 = call cc 113 i64 @nosplit_callee(i64 %x), !dbg !15
  %r2 = call cc 113 i64 @asyncdisabled_callee(i64 %r1), !dbg !16
  %s = add i64 %r2, 3
  ret i64 %s
}

; CHECK-LABEL: define gointernal i64 @runtime_caller(
; CHECK-SAME: #0
; CHECK-NOT: !go.allunsafe.inline
; CHECK: }
define cc 113 i64 @runtime_caller(i64 %x) #0 gc "go" !dbg !17 {
entry:
  %r = call cc 113 i64 @nosplit_callee(i64 %x), !dbg !19
  ret i64 %r
}

; The intermediate function already carries a scope list (as if a previous
; inline step recorded it). Inlining it must merge the list into the outer
; caller instead of dropping it.
; CHECK-LABEL: define gointernal i64 @outer_caller(
; CHECK-SAME: !go.allunsafe.inline [[NESTED:![0-9]+]]
; CHECK-NOT: "go.allunsafe"
; CHECK: }
define cc 113 i64 @outer_caller(i64 %x) gc "go" !dbg !23 {
entry:
  %r = call cc 113 i64 @intermediate(i64 %x), !dbg !25
  ret i64 %r
}

; The already-unsafe caller keeps its whole-function attribute group.
; CHECK: attributes #0 = { alwaysinline "go.allunsafe"="CompilingRuntimeOrNoSplit" }

; Both attribute values are recorded by subprogram name on one list.
; CHECK: [[SCOPED]] = !{!"nosplit_callee", !"asyncdisabled_callee"}
; Nested inlining propagates the intermediate callee's recorded scope.
; CHECK: [[NESTED]] = !{!"nosplit_callee"}

define cc 113 i64 @nosplit_callee(i64 %x) #0 gc "go" !dbg !7 {
entry:
  %a = add i64 %x, 1, !dbg !9
  ret i64 %a, !dbg !9
}

define cc 113 i64 @asyncdisabled_callee(i64 %x) #1 gc "go" !dbg !10 {
entry:
  %a = mul i64 %x, 2, !dbg !12
  ret i64 %a, !dbg !12
}

define cc 113 i64 @intermediate(i64 %x) #2 gc "go" !dbg !20 !go.allunsafe.inline !30 {
entry:
  %a = add i64 %x, 1, !dbg !22
  ret i64 %a, !dbg !22
}

attributes #0 = { alwaysinline "go.allunsafe"="CompilingRuntimeOrNoSplit" }
attributes #1 = { alwaysinline "go.allunsafe"="AsyncPreemptDisabled" }
attributes #2 = { alwaysinline }

!llvm.module.flags = !{!0}
!llvm.dbg.cu = !{!1}

!0 = !{i32 2, !"Debug Info Version", i32 3}
!1 = distinct !DICompileUnit(language: DW_LANG_Go, file: !2, producer: "lit",
                             isOptimized: true, emissionKind: FullDebug)
!2 = !DIFile(filename: "upf2.ll", directory: "/")
!3 = !DISubroutineType(types: !4)
!4 = !{}
!7 = distinct !DISubprogram(name: "nosplit_callee", scope: !2, file: !2, line: 1, type: !3, spFlags: DISPFlagDefinition, unit: !1)
!9 = !DILocation(line: 2, scope: !7)
!10 = distinct !DISubprogram(name: "asyncdisabled_callee", scope: !2, file: !2, line: 5, type: !3, spFlags: DISPFlagDefinition, unit: !1)
!12 = !DILocation(line: 6, scope: !10)
!13 = distinct !DISubprogram(name: "normal_caller", scope: !2, file: !2, line: 9, type: !3, spFlags: DISPFlagDefinition, unit: !1)
!15 = !DILocation(line: 10, scope: !13)
!16 = !DILocation(line: 11, scope: !13)
!17 = distinct !DISubprogram(name: "runtime_caller", scope: !2, file: !2, line: 14, type: !3, spFlags: DISPFlagDefinition, unit: !1)
!19 = !DILocation(line: 15, scope: !17)
!20 = distinct !DISubprogram(name: "intermediate", scope: !2, file: !2, line: 18, type: !3, spFlags: DISPFlagDefinition, unit: !1)
!22 = !DILocation(line: 19, scope: !20)
!23 = distinct !DISubprogram(name: "outer_caller", scope: !2, file: !2, line: 22, type: !3, spFlags: DISPFlagDefinition, unit: !1)
!25 = !DILocation(line: 23, scope: !23)
!30 = !{!"nosplit_callee"}
