; The Go frontend emits read-only string symbols as external i8 declarations
; carrying only !go.rodata bytes. With materialization enabled the initializer
; renames them to ".old" and routes uses through a "$newalias" onto a ".mat"
; definition. The intervening optimization pipeline runs Go-aware GlobalDCE,
; which used to erase the unused ".old" declaration so GORoDataRestorePass
; tripped its "old global value should live" assertion.
;
; RUN: opt -O3 -enable-go-global-init-opt -S -o /dev/null --print-after-all %s 2>&1 | FileCheck %s --check-prefix=MATERIALIZED
; RUN: opt -O3 -enable-go-global-init-opt -S %s | FileCheck %s

target triple = "x86_64-unknown-linux-goabi"

@"go:string.\22n\22" = external global i8, !go.rodata !0

; Keep the symbol address live so the restored declaration survives the
; final GlobalDCE and the pipeline output is observable.
define ptr @string_addr() {
; MATERIALIZED-LABEL: IR Dump After GORoDataInitializerPass
; MATERIALIZED: @"go:string.\22n\22.old" = external global i8
; MATERIALIZED-SAME: !go.global
; MATERIALIZED-SAME: !go.rodata.keepold
; MATERIALIZED: @"go:string.\22n\22.mat" = linkonce_odr
; MATERIALIZED: @"go:string.\22n\22$newalias" = alias
  ret ptr @"go:string.\22n\22"
}

; The restore pass must re-point the alias at the original declaration and
; remove every materialization artifact.
; CHECK-NOT: .old
; CHECK-NOT: .mat
; CHECK-NOT: $newalias
; CHECK: @"go:string.\22n\22" = external global i8, !go.rodata
; CHECK-LABEL: @string_addr(
; CHECK: ret ptr @"go:string.\22n\22"
; CHECK-NOT: .old
; CHECK-NOT: .mat
; CHECK-NOT: $newalias

!0 = !{!"n"}
