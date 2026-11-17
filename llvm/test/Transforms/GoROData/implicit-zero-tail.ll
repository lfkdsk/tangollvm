; RUN: opt -O3 -enable-go-global-init-opt -S %s | FileCheck %s

target triple = "x86_64-unknown-linux-goabi"

@options = external global { ptr, ptr }, !go.global !0, !go.rodata !1
@name = external global i8, !go.global !0

; The Go data contains a relocation for the first field and omits the zero
; bytes for the second field. The initializer pass must preserve this load.
define ptr @load_tail() {
; CHECK-LABEL: define {{.*}}@load_tail(
; CHECK: %[[TAIL:.*]] = load ptr, ptr getelementptr inbounds (i8, ptr @options, i64 8)
; CHECK: ret ptr %[[TAIL]]
  %tail = load ptr, ptr getelementptr inbounds ({ ptr, ptr }, ptr @options, i64 0, i32 1)
  ret ptr %tail
}

!0 = !{}
!1 = !{!"\00\00\00\00\00\00\00\00", !2}
!2 = !{i64 1, i64 0, i64 8, i64 0, !"name"}
