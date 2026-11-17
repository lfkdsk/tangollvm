// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// End-to-end regression for caller spill-area reuse. Run with a built Tango
// toolchain and a fresh GOCACHE (SDK changes are not part of Go's cache key):
// GOEXPERIMENT=tangollvm go run -gcflags='all=-beast=llvm=3,optimize=3,inline=1' argspill-paramalias.go
// The address-taken parameter has its own fixed home. The independently live
// old pointer must not share that home when replace changes the parameter.
package main

import "runtime"

type object struct {
	value   int
	padding [64]byte
}

//go:noinline
func replace(pp **object) { *pp = &object{value: 22} }

//go:noinline
func check(p *object) (int, int) {
	old := p
	replace(&p)
	runtime.GC()
	return old.value, p.value
}

func main() {
	a, b := check(&object{value: 11})
	if a != 11 || b != 22 {
		panic("aliased parameter spill")
	}
	println("parameter alias: passed")
}
