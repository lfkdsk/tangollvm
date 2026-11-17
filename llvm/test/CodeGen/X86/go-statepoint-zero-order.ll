; RUN: llc -O3 -stop-before=callbrprepare %s -o - | FileCheck %s
; RUN: llc -O3 -filetype=obj %s -o %t.1
; RUN: llc -O3 -filetype=obj %s -o %t.2
; RUN: cmp %t.1 %t.2
; REQUIRES: x86-registered-target

target triple = "x86_64-unknown-linux-goabi"

declare cc 113 void @safepoint()
declare cc 113 void @use(ptr)

; CHECK-LABEL: preheader:
; CHECK-NEXT: store volatile [2 x ptr] zeroinitializer, ptr %second
; CHECK-NEXT: store volatile [2 x ptr] zeroinitializer, ptr %first
; Both slots must be zeroed before their addresses escape inside the loop.
define cc 113 void @slots(i1 %active) gc "go" !dbg !4 !go.funcinfo !0 {
entry:
  %first = alloca [2 x ptr], align 8, !go.stackobject.gcdata !8
  %second = alloca [2 x ptr], align 8, !go.stackobject.gcdata !8
  call cc 113 void @safepoint(), !dbg !9
  br i1 %active, label %preheader, label %exit
exit:
  ret void
preheader:
  br label %loop
loop:
  call cc 113 void @use(ptr %second), !dbg !9
  call cc 113 void @use(ptr %first), !dbg !9
  br label %loop
}

!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "slots.go", directory: "/")
!4 = distinct !DISubprogram(name: "slots", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!8 = !{i32 16, i32 16, !"runtime.gcbits.0300000000000000"}
!9 = !DILocation(line: 1, column: 1, scope: !4)
