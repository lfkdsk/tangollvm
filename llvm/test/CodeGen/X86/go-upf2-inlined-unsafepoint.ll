; RUN: llc -O3 -mtriple=x86_64-unknown-linux-goabi -filetype=obj %s -o %t.o
; RUN: %python %S/Inputs/go_unsafe_dump.py %t.o scoped fallback | FileCheck %s
; REQUIRES: x86-registered-target
;
; UPF2 backend: go.allunsafe.inline names callees whose inlined bodies must
; stay non-preemptible. X86GoFixupPreRegAlloc marks exactly the machine
; instructions whose inlined-at debug scope is one of those subprograms;
; caller-owned instructions stay preemptible (-1). A recorded name with no
; matching scope takes the conservative whole-function fallback.

target triple = "x86_64-unknown-linux-goabi"

declare cc 113 void @safepoint()

; Recorded callee "missing_callee" has no instruction scope in this function,
; so the conservative fallback marks every instruction non-preemptible.
; Recorded callee "missing_callee" has no instruction scope in this function,
; so the conservative fallback marks every instruction non-preemptible.
; CHECK: fallback: [0, {{[0-9]+}}) -2
; CHECK-NOT: fallback:.* -1

; Volatile accesses to distinct slots keep the inlined-scope add/store alive
; through optimization (merging would erase the inlinedAt locations). The
; first instruction and the trailing pair belong to the caller (-1); the
; add/store between them is emitted inside the inlined "inlined_nosplit"
; scope (-2). Dumper output is alphabetical, so fallback checks come first.
; CHECK: scoped: [0, {{[0-9]+}}) -1
; CHECK: scoped: [{{[0-9]+}}, {{[0-9]+}}) -2
; CHECK: scoped: [{{[0-9]+}}, {{[0-9]+}}) -1
define cc 113 void @scoped(ptr %p) gc "go" !dbg !4 !go.funcinfo !0
    !go.allunsafe.inline !10 {
entry:
  %p2 = getelementptr i64, ptr %p, i64 1
  %a = load volatile i64, ptr %p, align 8, !dbg !9
  call cc 113 void @safepoint(), !dbg !9
  %b = add i64 %a, 1, !dbg !12
  store volatile i64 %b, ptr %p, align 8, !dbg !13
  %c = add i64 %b, 2, !dbg !9
  store volatile i64 %c, ptr %p2, align 8, !dbg !9
  ret void
}

; Recorded callee "missing_callee" has no instruction scope in this function,
; so the conservative fallback marks every instruction non-preemptible.
define cc 113 void @fallback(ptr %p) gc "go" !dbg !15 !go.funcinfo !0
    !go.allunsafe.inline !20 {
entry:
  %a = load i64, ptr %p, align 8, !dbg !16
  %b = add i64 %a, 1, !dbg !16
  store i64 %b, ptr %p, align 8, !dbg !16
  ret void
}

!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "scoped.go", directory: "/")
!4 = distinct !DISubprogram(name: "scoped", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!9 = !DILocation(line: 1, column: 1, scope: !4)
!10 = !{!"inlined_nosplit"}
!11 = distinct !DISubprogram(name: "inlined_nosplit", scope: !3, file: !3, line: 10, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!12 = !DILocation(line: 11, column: 3, scope: !11, inlinedAt: !14)
!13 = !DILocation(line: 12, column: 3, scope: !11, inlinedAt: !14)
!14 = distinct !DILocation(line: 20, column: 2, scope: !4)
!15 = distinct !DISubprogram(name: "fallback", scope: !3, file: !3, line: 30, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!16 = !DILocation(line: 31, column: 1, scope: !15)
!20 = !{!"missing_callee"}
