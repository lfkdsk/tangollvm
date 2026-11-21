; RUN: llc -relocation-model=static \
; RUN:   -mtriple=x86_64-unknown-linux-goabi -O3 --cost-kind=latency \
; RUN:   -tangollvm-lto=true -o - %S/Inputs/go-gcprinter-mixed-undef-bitmap.bc | FileCheck %s
; REQUIRES: x86-registered-target

; Sample PGO (and, per the earlier full-LTO case, cross-function optimization)
; can reshape control flow so that a first-class aggregate value has undef
; pointer fields on the path reaching a statepoint. In the reduced function
; service_mesh/shmipc.(*Session).pollingLoop.func1 the statepoint on the
; logger.prefix call carries the deopt sequence
;
;   ptr <aggregate alloca>, i32 2, ptr <undef FCA field>, ptr <undef FCA field>
;
; which SelectionDAG/StackMaps lower to a Direct stack slot, one real 32-bit
; pointer-bitmap word, and two standalone 0xFEFEFEFE undef markers.
; GoGCPrinter's aggregate loop used to consume every trailing Constant as a
; bitmap word and walk the locals index by 32 slots per marker, underflowing
; the unsigned index and tripping BitVector::set "access in bound". A marker
; describes an operand with no stack slot, so it must be ignored without
; moving the aggregate slot index; the real bitmap word must still be emitted.
;
; Before the fix llc aborts inside AsmPrinter::emitStackMaps; with the fix it
; completes and emits the per-statepoint locals pointer maps (16 statepoints
; in this fixture, each map 4 bits / 1 byte wide).

; CHECK-LABEL: "code.byted.org/service_mesh/shmipc.(*Session).pollingLoop.func1..localspointermaps":
; CHECK-NEXT: .long 16
; CHECK-NEXT: .long 4
