; RUN: split-file %s %t
; RUN: cd %t
; RUN: opt -module-summary a.ll -o a.bc
; RUN: opt -module-summary b.ll -o b.bc
; RUN: llvm-lto -thinlto-action=thinlink -o index.bc a.bc b.bc
; RUN: tango-thinlto-plan index.bc -output=. -budget=0 | FileCheck %s --check-prefix=ZERO
; RUN: opt -passes=function-import -import-all-index -summary-file=0.index.bc -S a.bc | FileCheck %s --check-prefix=NOIMPORT
; RUN: tango-thinlto-plan index.bc -output=. -budget=1 | FileCheck %s --check-prefix=ONE
; RUN: opt -passes=function-import -import-all-index -summary-file=0.index.bc -S a.bc | FileCheck %s --check-prefix=IMPORT

; ZERO: "functions":0,"index":"./0.index.bc","module":"a.bc","sources":[]
; ONE: "functions":1,"index":"./0.index.bc","module":"a.bc","sources":["b.bc"]
; NOIMPORT: declare i32 @callee()
; IMPORT: define available_externally i32 @callee()

;--- a.ll
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"
declare i32 @callee()
define i32 @caller() {
  %x = call i32 @callee()
  ret i32 %x
}

;--- b.ll
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"
define i32 @callee() {
  ret i32 42
}
