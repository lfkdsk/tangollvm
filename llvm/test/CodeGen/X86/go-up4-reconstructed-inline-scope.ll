; RUN: llc -O3 -mtriple=x86_64-unknown-linux-goabi -filetype=obj %s -o %t.o
; RUN: %python %S/Inputs/go_unsafe_dump.py %t.o fold linezero | FileCheck %s
; RUN: llc -O3 -mtriple=x86_64-unknown-linux-goabi -go-debug-unsafe-fallback -go-no-inline-scope-reconstruct %s -o /dev/null 2>&1 | FileCheck %s --check-prefix=KILL
; REQUIRES: x86-registered-target
;
; UP4: a recorded inlined unsafe callee can disappear from machine debug
; locations although its IR body is alive. Two backend shapes do this:
;   1. isel memory-operand folding fuses the inlined load into a caller
;      instruction, keeping only the caller frame (fold, exact-frame tier);
;   2. a machine instruction carrying a line-0 caller frame (linezero,
;      subprogram-only tier).
; IR-anchored frame reconstruction marks only the affected machine range -2
; instead of taking the UPF2 whole-function fallback. The stripped-debug
; negative case stays in go-up3-folded-inline-scope.ll.

target triple = "x86_64-unknown-linux-goabi"

; fold: the inlined "inlined_nosplit" body is a plain load feeding the
; caller's multiply. isel folds it into a memory-operand IMUL whose location
; keeps only the caller frame (line 20); the inlined load's scope is
; orphaned. Reconstruction attributes the IMUL region via the
; (caller SP, line 20) exact frame, while caller-only instructions stay
; preemptible.
; CHECK: fold: [0, {{[0-9]+}}) -1
; CHECK: fold: [{{[0-9]+}}, {{[0-9]+}}) -2
; CHECK: fold: [{{[0-9]+}}, {{[0-9]+}}) -1
; CHECK-NOT: fold: [0, {{[0-9]+}}) -2
define cc 113 void @fold(ptr %p, ptr %p2, i64 %k) gc "go" !dbg !4
    !go.funcinfo !0 !go.allunsafe.inline !10 {
entry:
  %anchor = load volatile i64, ptr %p2, align 8, !dbg !9
  %v = load i64, ptr %p, align 8, !dbg !12
  %m = mul i64 %v, %k, !dbg !14
  store volatile i64 %m, ptr %p2, align 8, !dbg !14
  %s = add i64 %anchor, 1, !dbg !9
  store volatile i64 %s, ptr %p2, align 8, !dbg !9
  ret void, !dbg !9
}

; linezero: the folded multiply carries a line-0 caller frame (the shape
; machine sinking produces). Exact-frame matching cannot apply, so the
; subprogram-only tier attributes the inlined callee at frame granularity.
; CHECK: linezero: [0, {{[0-9]+}}) -2
define cc 113 void @linezero(ptr %p, ptr %p2, i64 %k) gc "go" !dbg !24
    !go.funcinfo !0 !go.allunsafe.inline !10 {
entry:
  %v = load i64, ptr %p, align 8, !dbg !28
  %m = mul i64 %v, %k, !dbg !29
  store volatile i64 %m, ptr %p2, align 8, !dbg !29
  ret void, !dbg !29
}

; With reconstruction enabled the scoped -2 ranges above prove no
; whole-function fallback happens; the kill switch restores it.
; KILL: GoUnsafeFallback{{.*}}inline-scope{{.*}}fold
; KILL: GoUnsafeFallback{{.*}}inline-scope{{.*}}linezero

!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "scoped.go", directory: "/")
!4 = distinct !DISubprogram(name: "fold", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!9 = !DILocation(line: 1, column: 1, scope: !4)
!10 = !{!"inlined_nosplit"}
!11 = distinct !DISubprogram(name: "inlined_nosplit", scope: !3, file: !3, line: 10, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!12 = !DILocation(line: 11, column: 3, scope: !11, inlinedAt: !14)
!14 = distinct !DILocation(line: 20, column: 2, scope: !4)
!24 = distinct !DISubprogram(name: "linezero", scope: !3, file: !3, line: 2, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!27 = distinct !DILocation(line: 30, column: 2, scope: !24)
!28 = !DILocation(line: 11, column: 3, scope: !11, inlinedAt: !27)
!29 = !DILocation(line: 0, scope: !24)
