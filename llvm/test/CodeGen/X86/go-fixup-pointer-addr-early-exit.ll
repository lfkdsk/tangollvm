; RUN: llc -O3 -filetype=obj %s -o %t.1
; RUN: llc -O3 -filetype=obj %s -o %t.2
; RUN: cmp %t.1 %t.2
; RUN: llc -O3 -debug-x86-gogc-fixup-pointers -filetype=obj %s -o %t.3 2>&1 | FileCheck %s
; REQUIRES: x86-registered-target

; Regression test for the quadratic isPointerAddr use-list walk in the
; X86 Go Fixup PreRegAlloc pass. The pass decides whether an address Value is
; a "pointer to pointer" by scanning every use for pointer/non-pointer loads
; and stores. A single non-pointer access makes the answer permanently false,
; so the fixed pass exits the scan immediately instead of walking the whole
; (potentially huge) use list. The early exit must preserve the exact pointer
; classification, hence byte-identical objects across two compilations.

target triple = "x86_64-unknown-linux-goabi"
declare cc 113 void @safepoint()

; Mixed access: a pointer store and a non-pointer (i64) load through %box make
; isPointerAddr(%box) false via the sticky-non-pointer early exit. The i64 load
; result must not be inferred as a GC pointer.
; CHECK-LABEL: Start to collect pointers for mixed_addr
define cc 113 i64 @mixed_addr(ptr %box, ptr %g) gc "go" !dbg !4 !go.funcinfo !0 {
entry:
  store ptr %g, ptr %box, align 8
  %np = load i64, ptr %box, align 8
  call cc 113 void @safepoint(), !dbg !9
  ret i64 %np
}

; Pure pointer address: %slot only sees pointer accesses, so the full scan
; completes and returns true; the loaded pointer is classified as a Pointer.
; CHECK-LABEL: Start to collect pointers for pure_ptr_addr
; CHECK: Pointer
define cc 113 ptr @pure_ptr_addr(ptr %slot) gc "go" !dbg !14 !go.funcinfo !0 {
entry:
  store ptr null, ptr %slot, align 8
  %p = load ptr, ptr %slot, align 8
  call cc 113 void @safepoint(), !dbg !19
  ret ptr %p
}

!go.version = !{!7}
!llvm.module.flags = !{!1}
!llvm.dbg.cu = !{!2}
!0 = !{i32 0, i8 0, i8 0, i32 1}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Go, file: !3, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!3 = !DIFile(filename: "addr.go", directory: "/")
!4 = distinct !DISubprogram(name: "mixed_addr", scope: !3, file: !3, line: 1, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !{!"go1.22.12"}
!9 = !DILocation(line: 1, column: 1, scope: !4)
!14 = distinct !DISubprogram(name: "pure_ptr_addr", scope: !3, file: !3, line: 2, type: !5, spFlags: DISPFlagDefinition, unit: !2)
!19 = !DILocation(line: 2, column: 1, scope: !14)
