; RUN: llc -mtriple=x86_64-unknown-linux-goabi -stop-before=finalize-isel \
; RUN:   -o /dev/null \
; RUN:   -gogc-print-stackobjects %s 2>&1 | FileCheck %s
;
; Pointer-containing allocas whose addresses stay local are represented by the
; per-statepoint locals bitmap. Address values visible to calls, memory, or
; pointer merges additionally need a Go stack-object record.

%T = type { ptr, i64 }

@sink = external global ptr

declare void @safepoint()
declare void @escape(ptr)

define cc 113 void @precise() gc "go" {
entry:
  %local = alloca %T, align 8
  %field = getelementptr inbounds %T, ptr %local, i32 0, i32 0
  store ptr null, ptr %field, align 8
  call cc 113 void @safepoint()
  %v = load volatile ptr, ptr %field, align 8
  ret void
}
; CHECK: GoStackObject: precise precise{{ +}}%local = alloca %T

define cc 113 void @passed_to_call() gc "go" {
entry:
  %callarg = alloca %T, align 8
  call cc 113 void @escape(ptr %callarg)
  ret void
}
; CHECK: GoStackObject: passed_to_call call{{ +}}%callarg = alloca %T

define cc 113 void @stored_in_memory() gc "go" {
entry:
  %stored = alloca %T, align 8
  store ptr %stored, ptr @sink, align 8
  call cc 113 void @safepoint()
  ret void
}
; CHECK: GoStackObject: stored_in_memory stored{{ +}}%stored = alloca %T

define cc 113 void @merged(i1 %cond) gc "go" {
entry:
  %merged = alloca %T, align 8
  %selected = select i1 %cond, ptr %merged, ptr null
  %field = getelementptr inbounds %T, ptr %selected, i32 0, i32 0
  store ptr null, ptr %field, align 8
  call cc 113 void @safepoint()
  ret void
}
; CHECK: GoStackObject: merged phi-select{{ +}}%merged = alloca %T

define cc 113 void @frontend() gc "go" {
entry:
  %address_taken = alloca %T, align 8, !go.stackobject.gcdata !0
  call cc 113 void @escape(ptr %address_taken)
  ret void
}
; CHECK: GoStackObject: frontend frontend{{ +}}%address_taken = alloca %T

!0 = !{i64 16, i64 8, !"type:T"}
