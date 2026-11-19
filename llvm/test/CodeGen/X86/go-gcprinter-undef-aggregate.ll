; RUN: llc -relocation-model=static \
; RUN:   -mtriple=x86_64-unknown-linux-goabi -O3 --cost-kind=latency \
; RUN:   -tangollvm-lto=true -o - %s | FileCheck %s
; REQUIRES: x86-registered-target

; Full LTO can leave a field of a first-class aggregate (FCA) value undef on
; some control flow, e.g. an FCA built by insertvalue/extractvalue and merged
; by a PHI. GoStatepoints records the undef pointer fields in the statepoint
; and SelectionDAG/StackMaps serialize each as the 0xFEFEFEFE undef marker.
; When such markers follow a Direct stack slot, GoGCPrinter used to treat them
; as aggregate pointer-bitmap words and underflowed the locals index
; (assert(Idx >= j && "stack grows down")). The markers describe standalone
; undef operands instead: the live Direct slot must still be scanned and the
; markers must be ignored. Reduced from internal/poll.(*FD).ReadMsgInet4 in a
; full-scope full-LTO fmt program.

%"string$4" = type { ptr, i64 }

; Function Attrs: null_pointer_is_valid
define cc 113 { i64, i64, i64, ptr, ptr } @"internal/poll.(*FD).ReadMsgInet4"(i1 %0) #0 gc "go" !dbg !5 !go.funcinfo !9 {
b2:
  %iov.i.i = alloca %"string$4", i32 0, align 8
  br label %b19

b19:                                              ; preds = %b19, %b2
  store ptr %iov.i.i, ptr null, align 8
  %1 = insertvalue { i64, i64, i64, ptr, ptr } undef, i64 0, 0
  %2 = call cc 113 i1 null(ptr null, ptr null, ptr null)
  br i1 %0, label %b19, label %b27

b27:                                              ; preds = %b19
  %3 = extractvalue { i64, i64, i64, ptr, ptr } %1, 2
  ret { i64, i64, i64, ptr, ptr } zeroinitializer
}

attributes #0 = { null_pointer_is_valid }

!llvm.dbg.cu = !{!0, !2}
!llvm.module.flags = !{!4}

!0 = distinct !DICompileUnit(language: DW_LANG_Modula3, file: !1, producer: "TangoLLVM", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!1 = !DIFile(filename: "syscall", directory: "")
!2 = distinct !DICompileUnit(language: DW_LANG_Modula3, file: !3, producer: "TangoLLVM", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "internal/poll", directory: "")
!4 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "internal/poll.(*FD).ReadMsgInet4", scope: !6, file: !6, line: 306, type: !7, flags: DIFlagPrototyped, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!6 = !DIFile(filename: "fd_unix.go", directory: "")
!7 = !DISubroutineType(types: !8)
!8 = !{}
!9 = !{i32 72, i8 0, i8 0, i32 306}

; localspointermaps: 2 maps of 1 bit each; entry map is empty (00) and the
; statepoint map keeps the live alloca slot (01). A printer that drops the
; Direct slot while skipping the undef markers emits 00 for the second map.
; CHECK-LABEL: "internal/poll.(*FD).ReadMsgInet4..localspointermaps":
; CHECK-NEXT: .long 2
; CHECK-NEXT: .long 1
; CHECK-NEXT: .byte 0
; CHECK-NEXT: .byte 1
