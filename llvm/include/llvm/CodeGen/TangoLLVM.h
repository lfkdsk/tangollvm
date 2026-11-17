//==- TangoLLVM.h - constants and functions for TangoLLVM  ----------*-C++-*-==//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Copyright (c) 2025 ByteDance Ltd. and/or its affiliates.

#ifndef LLVM_CODEGEN_TANGOLLVM_H_
#define LLVM_CODEGEN_TANGOLLVM_H_

#include <llvm/TangoLLVM/TangoLLVM.h>
#include <llvm/CodeGen/MachineInstr.h>
#include <llvm/CodeGen/MachineMemOperand.h>


namespace llvm {


class TangoLLVMCodeGen {

public:
  // Identifies a store proven to write an incoming argument to its ABI slot.
  static constexpr auto IncomingArgSpill = MachineMemOperand::MOTargetFlag1;

  static bool isMoreStackCall(const MachineInstr &MI) {
    if (!MI.isCall())
      return false;
    // see X86FrameLowering.cpp
    // must be a call
    // callee must be the first operand
    const MachineOperand &MO = MI.getOperand(0);
    StringRef morestackSymbol = TangoLLVM::getMoreStackSymbol(MI.getParent()->getParent()->getFunction());
    if (!MO.isSymbol() || morestackSymbol != MO.getSymbolName())
      return false;

    return true;
  }

  static bool isDeferReturnCall(const MachineInstr &MI) {
    if (!MI.isCall())
      return false;
    // see X86FrameLowering.cpp
    // must be a call
    // callee must be the first operand
    const MachineOperand &MO = MI.getOperand(0);
    if (!MO.isSymbol() || strcmp(MO.getSymbolName(), "runtime.deferreturn") != 0)
      return false;

    return true;
  }

};


} // end namespace llvm

#endif // LLVM_CODEGEN_TANGOLLVM_H_
