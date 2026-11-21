; REQUIRES: x86-registered-target
; RUN: opt -S -mtriple=x86_64-unknown-linux-goabi -passes='mergeicmps,loop(loop-idiom),instcombine' %s | FileCheck %s --check-prefix=GO
; RUN: sed 's/cc 113 //g' %s | opt -S -mtriple=x86_64-unknown-linux-gnu -passes='mergeicmps,loop(loop-idiom),instcombine' | FileCheck %s --check-prefix=C
; RUN: llc -O3 -stop-after=finalize-isel %s -o - | FileCheck %s --check-prefix=ISEL --implicit-check-not='CALL{{.*}}@{{(memcmp|bcmp|memcpy|memmove|memset|runtime\.memequal)}}'

target triple = "x86_64-unknown-linux-goabi"

; Three adjacent words, as in a Go struct containing [16]byte and int.
; GO-LABEL: define {{.*}} @equal24(
; GO: icmp eq i64
; GO-NOT: @memcmp
; GO-NOT: @bcmp
; GO: ret i1
; C-LABEL: define {{.*}} @equal24(
; C: call i32 @{{bcmp|memcmp}}({{.*}}i64 24)
define cc 113 i1 @equal24(ptr dereferenceable(24) %a, ptr dereferenceable(24) %b) gc "go" {
entry:
  %a0 = load i64, ptr %a, align 8
  %b0 = load i64, ptr %b, align 8
  %eq0 = icmp eq i64 %a0, %b0
  br i1 %eq0, label %second, label %end

second:
  %pa1 = getelementptr inbounds i8, ptr %a, i64 8
  %pb1 = getelementptr inbounds i8, ptr %b, i64 8
  %a1 = load i64, ptr %pa1, align 8
  %b1 = load i64, ptr %pb1, align 8
  %eq1 = icmp eq i64 %a1, %b1
  br i1 %eq1, label %third, label %end

third:
  %pa2 = getelementptr inbounds i8, ptr %a, i64 16
  %pb2 = getelementptr inbounds i8, ptr %b, i64 16
  %a2 = load i64, ptr %pa2, align 8
  %b2 = load i64, ptr %pb2, align 8
  %eq2 = icmp eq i64 %a2, %b2
  br label %end

end:
  %eq = phi i1 [ false, %entry ], [ false, %second ], [ %eq2, %third ]
  ret i1 %eq
}

; Nonzero byte fills have no equivalent in Go's zero-only memclr helper.
; GO-LABEL: define {{.*}} @fill(
; GO: store i8 91
; GO-NOT: @llvm.memset
; GO: ret void
; C-LABEL: define {{.*}} @fill(
; C: call void @llvm.memset
define cc 113 void @fill(ptr %dst, i64 %n) gc "go" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %p = getelementptr inbounds i8, ptr %dst, i64 %i
  store i8 91, ptr %p, align 1
  %next = add nuw i64 %i, 1
  %finished = icmp eq i64 %next, %n
  br i1 %finished, label %done, label %loop

done:
  ret void
}

; GO-LABEL: define {{.*}} @copy_bytes(
; GO: store i8
; GO-NOT: @llvm.memcpy
; GO-NOT: @llvm.memmove
; GO: ret void
; C-LABEL: define {{.*}} @copy_bytes(
; C: call void @llvm.memcpy
define cc 113 void @copy_bytes(ptr noalias %dst, ptr noalias %src, i64 %n) gc "go" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %p = getelementptr inbounds i8, ptr %src, i64 %i
  %q = getelementptr inbounds i8, ptr %dst, i64 %i
  %byte = load i8, ptr %p, align 1
  store i8 %byte, ptr %q, align 1
  %next = add nuw i64 %i, 1
  %finished = icmp eq i64 %next, %n
  br i1 %finished, label %done, label %loop

done:
  ret void
}

; The small fixed-size Go helper is still expanded in the backend.
; ISEL-LABEL: name: word_equal
; ISEL: {{(CMP64|SUB64)}}
declare cc 113 i1 @runtime.memequal(ptr, ptr, i64)

define cc 113 i1 @word_equal(ptr %a, ptr %b) gc "go" {
  %equal = call cc 113 i1 @runtime.memequal(ptr %a, ptr %b, i64 8)
  ret i1 %equal
}

; Model an explicit external call to verify InstCombine cannot introduce
; strlen and a copy based on C runtime semantics on the Go target.
; GO-LABEL: define ptr @append_suffix(
; GO-NOT: @strlen
; GO-NOT: @llvm.memcpy
; GO: call ptr @strcat
; GO: ret ptr
; C-LABEL: define ptr @append_suffix(
; C: call i64 @strlen
; C: store i16 120
@suffix = private constant [2 x i8] c"x\00"
declare ptr @strcat(ptr, ptr)

define ptr @append_suffix(ptr %dst) {
  %result = call ptr @strcat(ptr %dst, ptr @suffix)
  ret ptr %result
}
