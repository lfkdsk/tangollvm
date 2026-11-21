; Test that GoStatepoints' GEP re-hoist clones GEPs in a deterministic order
; when a GEP has multiple first usages (two PHIs in split blocks plus a direct
; use in a separate loop region). The first-usage collection used to be a
; pointer-keyed DenseSet, whose iteration order depended on allocator
; addresses, so identical invocations with different output paths produced
; different .text (DET4, gofeed module 2701). The two object files below use
; different output paths on purpose.
;
; RUN: llc -O3 -debug-re-hoist-func=det4_rehoist_order -filetype=obj %s -o %t.1 2>&1 | FileCheck %s
; RUN: llc -O3 -filetype=obj %s -o %t.really.long.output.path.2.o
; RUN: cmp %t.1 %t.really.long.output.path.2.o
; REQUIRES: x86-registered-target

target triple = "x86_64-unknown-linux-goabi"

declare cc 113 void @consume(ptr, ptr)

; CHECK: ** GEP:   %g16 = getelementptr i8, ptr %a, i64 16
; CHECK: First Usage: Size = 3
; CHECK: process First Use

define cc 113 void @det4_rehoist_order(ptr %a) gc "go" !dbg !4 !go.funcinfo !0 {
entry:
  %g8 = getelementptr i8, ptr %a, i64 8
  %g16 = getelementptr i8, ptr %a, i64 16
  call cc 113 void @consume(ptr %a, ptr %a), !dbg !9
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %split2 ], [ %iv.next, %buse ]
  %iv.next = add i64 %iv, 1
  %c0 = load volatile i1, ptr %a
  br i1 %c0, label %b195, label %bmid

bmid:
  %cm = load volatile i1, ptr %a
  br i1 %cm, label %b233, label %bmid2

bmid2:
  %cm2 = load volatile i1, ptr %a
  br i1 %cm2, label %b271, label %buse

b195:
  %wb1 = load volatile i1, ptr %a
  br i1 %wb1, label %split2, label %split1

b233:
  %wb2 = load volatile i1, ptr %a
  br i1 %wb2, label %split2, label %split1

b271:
  %wb3 = load volatile i1, ptr %a
  br i1 %wb3, label %split2, label %split1

buse:
  %l16 = load i64, ptr %g16, align 8
  call cc 113 void @consume(ptr %g16, ptr %a), !dbg !9
  br label %loop

split1:
  %ph1 = phi ptr [ %a, %b195 ], [ %g8, %b233 ], [ %g16, %b271 ]
  store ptr null, ptr %ph1, align 8
  br label %split2

split2:
  %ph2 = phi ptr [ %a, %b195 ], [ %g8, %b233 ], [ %g16, %b271 ], [ %ph1, %split1 ]
  store ptr null, ptr %ph2, align 8
  %keep = icmp slt i64 %iv.next, 4
  br i1 %keep, label %loop, label %exit

exit:
  ret void
}

!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "det4.go", directory: "/")
!4 = distinct !DISubprogram(name: "det4_rehoist_order", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!9 = !DILocation(line: 1, column: 1, scope: !4)
