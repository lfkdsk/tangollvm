; RUN: llc -relocation-model=static \
; RUN:   -mtriple=x86_64-unknown-linux-goabi -O3 --cost-kind=latency \
; RUN:   -tangollvm-lto=true -o - %s | FileCheck %s
; RUN: llc -relocation-model=static \
; RUN:   -mtriple=x86_64-unknown-linux-goabi -O3 --cost-kind=latency \
; RUN:   -tangollvm-lto=true -stop-before=callbrprepare -o - %s \
; RUN:   | FileCheck %s --check-prefix=IR
; REQUIRES: x86-registered-target

; GoStatepoints describes a live aggregate stack slot in the statepoint deopt
; operands as the slot, a header giving the number N of pointer-bitmap words
; (0x60B10000 | N), and the N 32-bit words. StackMaps lowers these operands,
; and also every undef operand (the 0xFEFEFEFE marker), to Constant
; locations; the header is what tells GoGCPrinter which Constants after the
; slot are its bitmap. Without it a bitmap word equal to 0xFEFEFEFE was read
; as an undef marker (the slot then lost the pointers of that word), undef
; markers after the last word were read as more words, and a spilled pointer
; followed by an undef marker was left out of the map.

%elem = type { i64, ptr, ptr, ptr, ptr, ptr, ptr, ptr }
%head = type { ptr, i64, i64, i64, i64, i64, i64, i64 }
%quad = type [4 x %elem]
%pair = type { [4 x %head], [4 x %elem] }
%small = type { i64, ptr }

; [4 x %elem] is 32 words with one integer before seven pointers in every
; 8-word element: its only bitmap word is 0xFEFEFEFE.
; IR-LABEL: define {{.*}}@main.leadingWord(
; IR: "deopt"(ptr %s, i32 1622212609, i32 -16843010)
; CHECK-LABEL: main.leadingWord..localspointermaps:
; CHECK-NEXT: .long 2
; CHECK-NEXT: .long 32
; CHECK-NEXT: .byte 0
; CHECK-NEXT: .byte 0
; CHECK-NEXT: .byte 0
; CHECK-NEXT: .byte 0
; CHECK-NEXT: .byte 254
; CHECK-NEXT: .byte 254
; CHECK-NEXT: .byte 254
; CHECK-NEXT: .byte 254
define cc 113 i64 @"main.leadingWord"(i1 %0) #0 gc "go" !dbg !5 !go.funcinfo !9 {
b2:
  %s = alloca %quad, align 8
  br label %b19

b19:                                              ; preds = %b19, %b2
  store ptr %s, ptr null, align 8
  %1 = call cc 113 i1 null(ptr null, ptr null, ptr null)
  br i1 %0, label %b19, label %b27

b27:                                              ; preds = %b19
  ret i64 0
}

; The second bitmap word of %pair is 0xFEFEFEFE (the first is 0x01010101).
; IR-LABEL: define {{.*}}@main.secondWord(
; IR: "deopt"(ptr %s, i32 1622212610, i32 16843009, i32 -16843010)
; CHECK-LABEL: main.secondWord..localspointermaps:
; CHECK-NEXT: .long 2
; CHECK-NEXT: .long 64
; CHECK-COUNT-8: .byte 0
; CHECK-NEXT: .byte 1
; CHECK-NEXT: .byte 1
; CHECK-NEXT: .byte 1
; CHECK-NEXT: .byte 1
; CHECK-NEXT: .byte 254
; CHECK-NEXT: .byte 254
; CHECK-NEXT: .byte 254
; CHECK-NEXT: .byte 254
define cc 113 i64 @"main.secondWord"(i1 %0) #0 gc "go" !dbg !10 !go.funcinfo !9 {
b2:
  %s = alloca %pair, align 8
  br label %b19

b19:                                              ; preds = %b19, %b2
  store ptr %s, ptr null, align 8
  %1 = call cc 113 i1 null(ptr null, ptr null, ptr null)
  br i1 %0, label %b19, label %b27

b27:                                              ; preds = %b19
  ret i64 0
}

; A { i64, ptr } slot (bitmap word 2) and an FCA whose two pointer fields are
; undef are live across the call: the slot's word is followed by two undef
; markers, which must neither be read as bitmap words nor stop the word.
; IR-LABEL: define {{.*}}@main.undefAfterWord(
; IR: "deopt"(ptr %s, i32 1622212609, i32 2, ptr %{{[0-9]+}}, ptr %{{[0-9]+}})
; CHECK-LABEL: main.undefAfterWord..localspointermaps:
; CHECK-NEXT: .long 2
; CHECK-NEXT: .long 2
; CHECK-NEXT: .byte 0
; CHECK-NEXT: .byte 2
define cc 113 { i64, i64, i64, ptr, ptr } @"main.undefAfterWord"(i1 %0) #0 gc "go" !dbg !11 !go.funcinfo !9 {
b2:
  %s = alloca %small, align 8
  br label %b19

b19:                                              ; preds = %b19, %b2
  store ptr %s, ptr null, align 8
  %1 = insertvalue { i64, i64, i64, ptr, ptr } undef, i64 0, 0
  %2 = call cc 113 i1 null(ptr null, ptr null, ptr null)
  br i1 %0, label %b19, label %b27

b27:                                              ; preds = %b19
  %3 = extractvalue { i64, i64, i64, ptr, ptr } %1, 2
  ret { i64, i64, i64, ptr, ptr } zeroinitializer
}

; %pp (reloaded on every iteration) and %q are spilled and live across the
; call; the undef fields of %1 come between them in the deopt operands, so the
; spill slot of %pp is followed by undef markers. Both slots hold pointers.
; IR-LABEL: define {{.*}}@main.pointerBeforeUndef(
; IR: "deopt"(ptr %pp, ptr %{{[0-9]+}}, ptr %{{[0-9]+}}, ptr %q)
; CHECK-LABEL: main.pointerBeforeUndef..localspointermaps:
; CHECK-NEXT: .long 3
; CHECK-NEXT: .long 2
; CHECK-NEXT: .byte 0
; CHECK-NEXT: .byte 3
; CHECK-NEXT: .byte 0
declare cc 113 void @sinkp(ptr)

define cc 113 { i64, i64, i64, ptr, ptr } @"main.pointerBeforeUndef"(i1 %0, ptr %pp) #0 gc "go" !dbg !12 !go.funcinfo !9 {
b2:
  br label %b19

b19:                                              ; preds = %b19, %b2
  %1 = insertvalue { i64, i64, i64, ptr, ptr } undef, i64 0, 0
  %q = load ptr, ptr %pp, align 8
  %2 = call cc 113 i1 null(ptr null, ptr null, ptr null)
  br i1 %0, label %b19, label %b27

b27:                                              ; preds = %b19
  call cc 113 void @sinkp(ptr %q)
  %3 = extractvalue { i64, i64, i64, ptr, ptr } %1, 2
  ret { i64, i64, i64, ptr, ptr } zeroinitializer
}

attributes #0 = { null_pointer_is_valid }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!4}

!0 = distinct !DICompileUnit(language: DW_LANG_Modula3, file: !1, producer: "TangoLLVM", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!1 = !DIFile(filename: "main", directory: "")
!4 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "main.leadingWord", scope: !6, file: !6, line: 10, type: !7, flags: DIFlagPrototyped, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DIFile(filename: "main.go", directory: "")
!7 = !DISubroutineType(types: !8)
!8 = !{}
!9 = !{i32 72, i8 0, i8 0, i32 10}
!10 = distinct !DISubprogram(name: "main.secondWord", scope: !6, file: !6, line: 20, type: !7, flags: DIFlagPrototyped, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = distinct !DISubprogram(name: "main.undefAfterWord", scope: !6, file: !6, line: 30, type: !7, flags: DIFlagPrototyped, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!12 = distinct !DISubprogram(name: "main.pointerBeforeUndef", scope: !6, file: !6, line: 40, type: !7, flags: DIFlagPrototyped, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0)
