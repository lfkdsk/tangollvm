; REQUIRES: x86-registered-target
; RUN: llc -O3 -stop-after=finalize-isel %s -o - | FileCheck %s --implicit-check-not='CALL{{.*}}{{(floor|ceil|trunc|round|fma|sqrt|__udivti3|__mulodi4)}}'

target triple = "x86_64-unknown-linux-goabi"

declare double @llvm.sqrt.f64(double)
declare double @llvm.floor.f64(double)
declare double @llvm.ceil.f64(double)
declare double @llvm.trunc.f64(double)
declare double @llvm.round.f64(double)
declare double @llvm.fma.f64(double, double, double)
declare { i64, i64 } @llvm.go.div128(i64, i64, i64)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64)

; CHECK-LABEL: name: root
; CHECK: SQRTSD
define cc 113 double @root(double %x) gc "go" {
  %r = call double @llvm.sqrt.f64(double %x)
  ret double %r
}

; The front end checks SSE4.1 and FMA support before using these intrinsics.
; CHECK-LABEL: name: rounds_and_fma
; CHECK: ROUND
; CHECK: VFMADD
define cc 113 double @rounds_and_fma(double %x, double %y) #0 gc "go" {
  %floor = call double @llvm.floor.f64(double %x)
  %ceil = call double @llvm.ceil.f64(double %y)
  %trunc = call double @llvm.trunc.f64(double %x)
  %round = call double @llvm.round.f64(double %y)
  %sum = fadd double %trunc, %round
  %r = call double @llvm.fma.f64(double %floor, double %ceil, double %sum)
  ret double %r
}

; CHECK-LABEL: name: wide_divide
; CHECK: DIV64
define cc 113 { i64, i64 } @wide_divide(i64 %hi, i64 %lo, i64 %y) gc "go" {
  %r = call { i64, i64 } @llvm.go.div128(i64 %hi, i64 %lo, i64 %y)
  ret { i64, i64 } %r
}

; CHECK-LABEL: name: mul_overflow
; CHECK: IMUL64
define cc 113 i1 @mul_overflow(i64 %x, i64 %y) gc "go" {
  %r = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %x, i64 %y)
  %overflow = extractvalue { i64, i1 } %r, 1
  ret i1 %overflow
}

attributes #0 = { "target-features"="+sse4.1,+avx,+fma" }
