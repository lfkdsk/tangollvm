; RUN: llc -O3 -debug-x86-gogc-fixup-pointers -filetype=obj %s -o %t.1 2>&1 | FileCheck %s
; RUN: llc -O3 -filetype=obj %s -o %t.2
; RUN: cmp %t.1 %t.2
; REQUIRES: x86-registered-target

; Each loop carries two derived pointers across a call. Visit the statepoints
; in CFG postorder when collecting their live-out pointers for cloning.
; CHECK: Dump untracked pointer for pointers at STATEPOINT 3:
; CHECK-NEXT: Dump untracked pointer for pointers at STATEPOINT 1:

target triple = "x86_64-unknown-linux-goabi"
declare cc 113 void @consume(ptr, ptr)
declare cc 113 ptr @base()
define cc 113 void @pointers() gc "go" !dbg !4 !go.funcinfo !0 {
entry:
  %a = call cc 113 ptr @base(), !dbg !9
  %x = getelementptr i8, ptr %a, i64 1544
  %y = getelementptr i8, ptr %a, i64 1800
  br label %loop
loop:
  call cc 113 void @consume(ptr %x, ptr %y), !dbg !9
  %again = load volatile i1, ptr %a
  br i1 %again, label %loop, label %next
next:
  %b = call cc 113 ptr @base(), !dbg !9
  %u = getelementptr i8, ptr %b, i64 1544
  %v = getelementptr i8, ptr %b, i64 1800
  br label %loop2
loop2:
  call cc 113 void @consume(ptr %u, ptr %v), !dbg !9
  %more = load volatile i1, ptr %b
  br i1 %more, label %loop2, label %exit
exit:
  ret void
}
!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "pointers.go", directory: "/")
!4 = distinct !DISubprogram(name: "pointers", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!9 = !DILocation(line: 1, column: 1, scope: !4)
