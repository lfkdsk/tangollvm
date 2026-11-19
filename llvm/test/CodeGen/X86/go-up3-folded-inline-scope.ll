; RUN: llc -O3 -mtriple=x86_64-unknown-linux-goabi -filetype=obj %s -o %t.o
; RUN: %python %S/Inputs/go_unsafe_dump.py %t.o mixed pruned stripped | FileCheck %s
; RUN: llc -O3 -mtriple=x86_64-unknown-linux-goabi -go-debug-unsafe-fallback %s -o /dev/null 2>&1 | FileCheck %s --check-prefix=LOG
; REQUIRES: x86-registered-target
;
; UP3: a name recorded in go.allunsafe.inline whose DISubprogram scope no
; longer exists anywhere in the IR cannot own a machine instruction (the
; inlined body folded before codegen), so the record is pruned instead of
; taking the UPF2 conservative whole-function fallback. A name that still has
; IR/MI scopes is retained and keeps driving the scoped -2 marks. When the
; whole function has no instruction debug locations (stripped), absence cannot
; be trusted as folding and the conservative whole-function fallback stays.

target triple = "x86_64-unknown-linux-goabi"

declare cc 113 void @safepoint()

; mixed: "folded_callee" has no IR scope and is pruned; "inlined_nosplit"
; survives, so only its inlined add/store region is -2, caller code stays -1,
; and no whole-function fallback happens.
; CHECK: mixed: [0, {{[0-9]+}}) -1
; CHECK: mixed: [{{[0-9]+}}, {{[0-9]+}}) -2
; CHECK: mixed: [{{[0-9]+}}, {{[0-9]+}}) -1
; CHECK-NOT: mixed: [0, {{[0-9]+}}) -2
define cc 113 void @mixed(ptr %p) gc "go" !dbg !4 !go.funcinfo !0
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

; pruned: the only recorded callee has zero IR scopes, so after pruning no
; constraint remains and every emitted instruction stays preemptible (-1).
; The function is a leaf, which legitimately ends with an empty unsafe set.
; CHECK: pruned: [0, {{[0-9]+}}) -1
; CHECK-NOT: pruned:.* -2

; stripped: the recorded callee scope is absent AND the function carries no
; instruction debug locations at all. Folding cannot be distinguished from
; stripped debug info, so nothing is pruned and the conservative
; whole-function -2 policy is retained.
; CHECK: stripped: [0, {{[0-9]+}}) -2
; CHECK-NOT: stripped:.* -1
define cc 113 void @pruned(ptr %p) #1 gc "go" !dbg !15 !go.funcinfo !0
    !go.allunsafe.inline !20 {
entry:
  %a = load volatile i64, ptr %p, align 8, !dbg !16
  %b = add i64 %a, 1, !dbg !16
  store volatile i64 %b, ptr %p, align 8, !dbg !16
  ret void
}

; No instruction carries a !dbg: debug info is unavailable, so the missing
; scope must not be interpreted as a folded body.
define cc 113 void @stripped(ptr %p) #1 gc "go" !dbg !25 !go.funcinfo !0
    !go.allunsafe.inline !20 {
entry:
  %a = load volatile i64, ptr %p, align 8
  %b = add i64 %a, 1
  store volatile i64 %b, ptr %p, align 8
  ret void
}

; LOG-NOT: GoUnsafeFallback.*mixed
; LOG-NOT: GoUnsafeFallback.*pruned
; LOG-NOT: GoUnsafeScopePruned{{.*}}stripped
; LOG: GoUnsafeScopePruned{{.*}}mixed{{.*}}folded_callee
; LOG: GoUnsafeScopePruned{{.*}}pruned{{.*}}folded_callee
; LOG: GoUnsafeFallback{{.*}}inline-scope{{.*}}stripped

attributes #1 = { "go-leaf"="true" "go-no-split"="true" "go-no-frame-checked"="true" }

!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "scoped.go", directory: "/")
!4 = distinct !DISubprogram(name: "mixed", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!9 = !DILocation(line: 1, column: 1, scope: !4)
!10 = !{!"folded_callee", !"inlined_nosplit"}
!11 = distinct !DISubprogram(name: "inlined_nosplit", scope: !3, file: !3, line: 10, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!12 = !DILocation(line: 11, column: 3, scope: !11, inlinedAt: !14)
!13 = !DILocation(line: 12, column: 3, scope: !11, inlinedAt: !14)
!14 = distinct !DILocation(line: 20, column: 2, scope: !4)
!15 = distinct !DISubprogram(name: "pruned", scope: !3, file: !3, line: 30, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!16 = !DILocation(line: 31, column: 1, scope: !15)
!20 = !{!"folded_callee"}
!25 = distinct !DISubprogram(name: "stripped", scope: !3, file: !3, line: 40, type: !5, spFlags: DISPFlagDefinition, unit: !2)
