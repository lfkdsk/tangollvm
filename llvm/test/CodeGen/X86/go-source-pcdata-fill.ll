; RUN: llc -O0 -filetype=obj %s -o %t.o
; RUN: %python %S/Inputs/go_source_dump.py %t.o fill anchor call | FileCheck %s --check-prefixes=CHECK,NEIGHBOR
; RUN: llc -O0 -filetype=obj -go-source-fill=neighbor %s -o %t.neighbor.o
; RUN: cmp %t.o %t.neighbor.o
; RUN: llc -O0 -filetype=obj -go-source-fill=prev %s -o %t.prev.o
; RUN: %python %S/Inputs/go_source_dump.py %t.prev.o fill anchor call | FileCheck %s --check-prefixes=CHECK,PREV
; RUN: llc -O0 -filetype=obj -go-source-fill=decl %s -o %t.decl.o
; RUN: %python %S/Inputs/go_source_dump.py %t.decl.o fill anchor call | FileCheck %s --check-prefixes=CHECK,DECL
; RUN: llc -O0 -filetype=obj -go-source-fill=block %s -o %t.block.o
; RUN: %python %S/Inputs/go_source_dump.py %t.block.o fill anchor call | FileCheck %s --check-prefixes=CHECK,BLOCK
; RUN: llc -O0 -filetype=obj -go-source-fill=frame %s -o %t.frame.o
; RUN: %python %S/Inputs/go_source_dump.py %t.frame.o fill anchor call | FileCheck %s --check-prefixes=CHECK,FRAME
; RUN: %python %S/Inputs/go_source_dump.py %t.o blocks | FileCheck %s --check-prefix=BLOCKS-NEIGHBOR
; RUN: %python %S/Inputs/go_source_dump.py %t.block.o blocks | FileCheck %s --check-prefix=BLOCKS-BLOCK
; REQUIRES: x86-registered-target
;
; PCV2: Go file, line and inline-index tables for instructions without a
; source line. The declaration fallback (decl) sends every such instruction
; to its frame's declaration line and, without a DebugLoc, to the outermost
; frame. neighbor (the default) and prev fill them from located neighbors;
; block and frame are diagnostic restrictions of neighbor.
; Every mode keeps the declaration for the instructions before the first
; located one (the function entry), for calls (return addresses resolve to the
; call), and for an inline node's parent PC instruction.

target triple = "x86_64-unknown-linux-goabi"

@value = global i64 0

declare cc 113 void @ext()

; fill: unlocated stores between located ones (lines 11-15, callee lines
; 30-31 inlined at line 12, declaration lines 10 and 20).
;   - entry store: before any located instruction, declaration 10.
;   - 11 -> ? -> 11 and callee 30 -> ? -> 31: filled from the left.
;   - callee 31 -> ? -> outer 13: neighbor keeps the outermost frame and
;     takes 13; prev takes callee 31.
;   - outer 13 -> line-0 callee -> outer 14: neighbor keeps the callee frame
;     and its declaration 20; prev takes 13.
; CHECK-LABEL: fill file:
; NEIGHBOR-NEXT: fill line: 10 11 30 31 13 20 14 15
; NEIGHBOR-NEXT: fill inline: -1 0 -1 0 -1
; PREV-NEXT: fill line: 10 11 30 31 13 14 15
; PREV-NEXT: fill inline: -1 0 -1
; DECL-NEXT: fill line: 10 11 10 11 30 10 31 10 13 20 14 15
; DECL-NEXT: fill inline: -1 0 -1 0 -1 0 -1
; BLOCK-NEXT: fill line: 10 11 30 31 13 20 14 15
; BLOCK-NEXT: fill inline: -1 0 -1 0 -1
; FRAME-NEXT: fill line: 10 11 30 10 31 13 20 14 15
; FRAME-NEXT: fill inline: -1 0 -1 0 -1 0 -1
define cc 113 void @fill(i64 %arg) gc "go" !dbg !10 !go.funcinfo !0 {
entry:
  store volatile i64 0, ptr @value
  store volatile i64 1, ptr @value, !dbg !11
  store volatile i64 2, ptr @value
  store volatile i64 3, ptr @value, !dbg !11
  store volatile i64 4, ptr @value, !dbg !21
  store volatile i64 5, ptr @value
  store volatile i64 6, ptr @value, !dbg !22
  store volatile i64 7, ptr @value
  store volatile i64 8, ptr @value, !dbg !13
  store volatile i64 9, ptr @value, !dbg !23
  store volatile i64 10, ptr @value, !dbg !14
  ret void, !dbg !15
}

; anchor: the callee inlined at line 35 has no located outer instruction at
; or before line 35 except a line-0 one, so that instruction is the node's
; parent PC. It keeps the outermost frame and the declaration 33 in every
; mode; prev or neighbor filling would give it the callee frame or line 40,
; and the runtime would resolve the parent frame at the wrong line or inside
; the callee.
; CHECK-LABEL: anchor file:
; CHECK-NEXT: anchor line: 30 33 40 41
; CHECK-NEXT: anchor inline: 0 -1
define cc 113 void @anchor() gc "go" !dbg !30 !go.funcinfo !0 {
entry:
  store volatile i64 1, ptr @value, !dbg !36
  store volatile i64 2, ptr @value, !dbg !33
  store volatile i64 3, ptr @value, !dbg !34
  ret void, !dbg !35
}

; call: a call with a line-0 location keeps its declaration (50) in every
; mode, so a return address minus one still resolves to it; prev or neighbor
; filling would give it line 51. The stack check and the morestack call are
; located at the declaration line.
; CHECK-LABEL: call file:
; CHECK-NEXT: call line: 50 51 50 51 53 50
; CHECK-NEXT: call inline: -1
define cc 113 void @call() gc "go" !dbg !50 !go.funcinfo !0 {
entry:
  store volatile i64 1, ptr @value, !dbg !51
  call cc 113 void @ext(), !dbg !52
  store volatile i64 2, ptr @value, !dbg !51
  ret void, !dbg !53
}

; blocks: the unlocated branch at the end of the entry block and the
; unlocated store at the top of the next block lie between two stores of the
; same inlined callee. neighbor joins the callee frame; block keeps the
; declaration because the run crosses a block boundary.
; BLOCKS-NEIGHBOR: blocks line: 60 61 62
; BLOCKS-NEIGHBOR-NEXT: blocks inline: 0 -1
; BLOCKS-BLOCK: blocks line: 60 70 61 62
; BLOCKS-BLOCK-NEXT: blocks inline: 0 -1 0 -1
define cc 113 void @blocks(i1 %c) gc "go" !dbg !70 !go.funcinfo !0 {
entry:
  store volatile i64 1, ptr @value, !dbg !73
  br i1 %c, label %next, label %other
next:
  store volatile i64 2, ptr @value
  store volatile i64 3, ptr @value, !dbg !74
  ret void, !dbg !72
other:
  ret void, !dbg !72
}

!go.version = !{!9}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 8, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "fill.go", directory: "/")
!5 = !DISubroutineType(types: !6)
!6 = !{}
!9 = !{!"go1.22.12"}
!10 = distinct !DISubprogram(name: "fill", scope: !3, file: !3, line: 10, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!11 = !DILocation(line: 11, scope: !10)
!12 = !DILocation(line: 12, scope: !10)
!13 = !DILocation(line: 13, scope: !10)
!14 = !DILocation(line: 14, scope: !10)
!15 = !DILocation(line: 15, scope: !10)
!20 = distinct !DISubprogram(name: "callee", scope: !3, file: !3, line: 20, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!21 = !DILocation(line: 30, scope: !20, inlinedAt: !12)
!22 = !DILocation(line: 31, scope: !20, inlinedAt: !12)
!23 = !DILocation(line: 0, scope: !20, inlinedAt: !12)
!30 = distinct !DISubprogram(name: "anchor", scope: !3, file: !3, line: 33, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!32 = !DILocation(line: 35, scope: !30)
!33 = !DILocation(line: 0, scope: !30)
!34 = !DILocation(line: 40, scope: !30)
!35 = !DILocation(line: 41, scope: !30)
!36 = !DILocation(line: 30, scope: !20, inlinedAt: !32)
!50 = distinct !DISubprogram(name: "call", scope: !3, file: !3, line: 50, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!51 = !DILocation(line: 51, scope: !50)
!52 = !DILocation(line: 0, scope: !50)
!53 = !DILocation(line: 53, scope: !50)
!70 = distinct !DISubprogram(name: "blocks", scope: !3, file: !3, line: 70, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!71 = !DILocation(line: 65, scope: !70)
!72 = !DILocation(line: 62, scope: !70)
!73 = !DILocation(line: 60, scope: !20, inlinedAt: !71)
!74 = !DILocation(line: 61, scope: !20, inlinedAt: !71)
