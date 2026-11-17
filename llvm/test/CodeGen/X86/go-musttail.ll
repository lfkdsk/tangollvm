; RUN: llc -O3 -stop-before=callbrprepare %s -o - | FileCheck %s --check-prefix=IR
; RUN: llc -O3 %s -o - | FileCheck %s --check-prefix=ASM
; REQUIRES: x86-registered-target

target triple = "x86_64-unknown-linux-goabi"

declare cc 113 void @safepoint()
declare cc 113 ptr @callee(ptr)

; IR-LABEL: define gointernal ptr @wrapper(
; IR: call gointernal token {{.*}}@llvm.experimental.gc.statepoint{{.*}} "deopt"(ptr %receiver)
; IR: %result = musttail call gointernal ptr @callee(ptr
; IR-NEXT: ret ptr %result
; ASM-LABEL: wrapper:
; ASM: callq safepoint
; ASM: popq %rbp
; ASM: jmp callee
define cc 113 ptr @wrapper(ptr %receiver) gc "go" !dbg !4 !go.funcinfo !0 {
entry:
  call cc 113 void @safepoint(), !dbg !8
  %result = musttail call cc 113 ptr @callee(ptr %receiver), !dbg !8
  ret ptr %result, !dbg !8
}

; ASM-LABEL: leaf_wrapper:
; ASM-NOT: callq
; ASM: jmp callee
; ASM-NOT: runtime.morestack
define cc 113 ptr @leaf_wrapper(ptr %receiver) gc "go" !dbg !10 !go.funcinfo !0 {
entry:
  %result = musttail call cc 113 ptr @callee(ptr %receiver), !dbg !11
  ret ptr %result, !dbg !11
}

!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "wrapper.go", directory: "/")
!4 = distinct !DISubprogram(name: "wrapper", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!8 = !DILocation(line: 1, column: 1, scope: !4)
!10 = distinct !DISubprogram(name: "leaf_wrapper", scope: !3, file: !3, line: 2, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!11 = !DILocation(line: 2, column: 1, scope: !10)
