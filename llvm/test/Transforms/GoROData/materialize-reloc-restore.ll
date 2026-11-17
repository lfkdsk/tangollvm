; Same materialize/restore requirement for the relocation path: the metadata
; is as long as the LLVM allocation, so materialization proceeds and builds a
; ".mat" struct embedding the relocated symbol. The ".old" declaration must be
; kept alive across the optimization pipeline until the restore pass runs.
;
; RUN: opt -O3 -enable-go-global-init-opt -S -o /dev/null --print-after-all %s 2>&1 | FileCheck %s --check-prefix=MATERIALIZED
; RUN: opt -O3 -enable-go-global-init-opt -S %s | FileCheck %s

target triple = "x86_64-unknown-linux-goabi"

@options = external global { ptr, ptr }, !go.rodata !1
@name = external global i8, !go.global !0

define ptr @load_tail() {
; MATERIALIZED-LABEL: IR Dump After GORoDataInitializerPass
; MATERIALIZED: @options.old = external {{.*}}global { ptr, ptr }
; MATERIALIZED-SAME: !go.global
; MATERIALIZED-SAME: !go.rodata.keepold
; MATERIALIZED: @options.mat = linkonce_odr
; MATERIALIZED: @"options$newalias" = alias
  %tail = load ptr, ptr getelementptr inbounds ({ ptr, ptr }, ptr @options, i64 0, i32 1)
  ret ptr %tail
}

; After restore the original Go declaration is back with its metadata and no
; materialization artifact remains. (The tail load reads all-zero bytes and is
; legitimately folded to null by GoRODataPass.)
; CHECK-NOT: .old
; CHECK-NOT: .mat
; CHECK-NOT: $newalias
; CHECK: @options = external {{.*}}global { ptr, ptr }, !go.rodata
; CHECK-LABEL: @load_tail(
; CHECK: ret ptr null
; CHECK-NOT: .old
; CHECK-NOT: .mat
; CHECK-NOT: $newalias

!0 = !{}
!1 = !{!"\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00", !2}
!2 = !{i64 1, i64 0, i64 8, i64 0, !"name"}
