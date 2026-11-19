; RUN: llc -O0 < %s | FileCheck %s
; REQUIRES: x86-registered-target
;
; A line-zero instruction in an inline keeps its inline index and uses the
; callee declaration. The physical instruction without a debug location
; uses the outer function declaration.

target triple = "x86_64-unknown-linux-goabi"

@value = global i64 0

define cc 113 void @source(i64 %arg) gc "go" !dbg !4 !go.funcinfo !0 {
entry:
  store volatile i64 %arg, ptr @value, !dbg !8
  store volatile i64 2, ptr @value
  ret void, !dbg !7
}

; CHECK-LABEL: source..pcline1:
; CHECK: .long 20
; CHECK: .long 1
; CHECK: .long 5
; CHECK-LABEL: source..pcinline1:
; CHECK: .long 0
; CHECK: .long -1

!go.version = !{!9}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 8, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "source.go", directory: "/")
!4 = distinct !DISubprogram(name: "source", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 5, scope: !4)
!8 = !DILocation(line: 0, scope: !10, inlinedAt: !11)
!9 = !{!"go1.22.12"}
!10 = distinct !DISubprogram(name: "callee", scope: !3, file: !3, line: 20, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!11 = !DILocation(line: 3, scope: !4)
