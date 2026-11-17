//===- X86GoFixupPostRegAlloc.cpp - Go ABI post-RA fixups -------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Copyright (c) 2025 ByteDance Ltd. and/or its affiliates.
//===----------------------------------------------------------------------===//
//
// Go ABI fixups after register allocation and stack-slot coloring, before PEI:
// remove phantom KeepAlive calls, select write-barrier helpers, and reuse the
// caller-reserved spill area for unchanged incoming register arguments.
//
//===----------------------------------------------------------------------===//

#include "MCTargetDesc/X86BaseInfo.h"
#include "X86.h"
#include "X86InstrInfo.h"
#include "X86Subtarget.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/CodeGen/LiveIntervals.h"
#include "llvm/CodeGen/LiveVariables.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineMemOperand.h"
#include "llvm/CodeGen/PseudoSourceValue.h"
#include "llvm/CodeGen/PseudoSourceValueManager.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstr.h"
#include "llvm/CodeGen/MachineOperand.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/StackMaps.h"
#include "llvm/CodeGen/TargetOpcodes.h"
#include "llvm/CodeGen/TargetRegisterInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Constants.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/raw_ostream.h"
#include <cassert>
#include <cstdint>
#include <iterator>

#define DEBUG_TYPE "x86-go-fixup-postregalloc"

using namespace llvm;

static cl::opt<bool> ReuseArgSpillArea(
    "go-reuse-arg-spill-area", cl::init(true), cl::Hidden,
    cl::desc("Reuse caller-reserved Go register argument spill slots"));

namespace {

class X86GoFixupPostRegAllocPass : public MachineFunctionPass {
public:
  X86GoFixupPostRegAllocPass() : MachineFunctionPass(ID) {
    initializeX86GoFixupPostRegAllocPassPass(*PassRegistry::getPassRegistry());
  }

  StringRef getPassName() const override { return "X86 Go Fixup PostRegAlloc"; }

  bool runOnMachineFunction(MachineFunction &MF) override;

  static char ID;

  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesCFG();
    MachineFunctionPass::getAnalysisUsage(AU);
  }

private:
  MachineFunction *MF = nullptr;

  bool rewriteGCWriteBarrier();
  bool reuseArgSpillArea();
};

} // end anonymous namespace

char X86GoFixupPostRegAllocPass::ID = 0;

FunctionPass *llvm::createX86GoFixupPostRegAlloc() { return new X86GoFixupPostRegAllocPass(); }
INITIALIZE_PASS(X86GoFixupPostRegAllocPass, DEBUG_TYPE, "X86 Fixup postregalloc pass", false,
                false)

bool X86GoFixupPostRegAllocPass::runOnMachineFunction(MachineFunction &fn) {
  MF = &fn;
  // This is used for Go function only.
  if (!MF->getFunction().hasGC() || MF->getFunction().getGC() != "go") {
    return false;
  }

  bool Changed = false;

  Changed |= rewriteGCWriteBarrier();
  Changed |= reuseArgSpillArea();

  return Changed;
}


bool X86GoFixupPostRegAllocPass::rewriteGCWriteBarrier() {
  bool Changed = false;
  SmallVector<MachineInstr*, 8> ToBeRemoved;
  const X86InstrInfo *TII = MF->getSubtarget<X86Subtarget>().getInstrInfo();
  const X86RegisterInfo *TRI = MF->getSubtarget<X86Subtarget>().getRegisterInfo();
  // Need to remove call setup of KeepAlive
  unsigned FrameSetupOpcode = TII->getCallFrameSetupOpcode();
  unsigned FrameDestroyOpcode = TII->getCallFrameDestroyOpcode();
  for (auto &MBB : *MF)
    for (auto &MI : MBB) {
      if (!MI.isCall())
        continue;

      if (MI.getOpcode() == TargetOpcode::STATEPOINT)
        continue;

      MachineOperand &Callee = MI.getOperand(0);
      if (!Callee.isGlobal())
        continue;


      const Function *F = dyn_cast<Function>(Callee.getGlobal());
      assert(F != nullptr);

      if (F->getName() == "runtime.KeepAlive") {
        // We must do it after RegAlloc because RegAlloc may not
        // spill a dead VirtReg.
        ToBeRemoved.push_back(&MI);
        // We must remove three instructions
        // 1. CallFrameSetup
        // 2. CallFrameDestory
        // 3. PassArg to RBX
        // RAX is a undef value
        // TODO: we still waste RBX here
        auto It = MI.getIterator();
        bool SetupFound = false;
        bool DestoryFound = false;
        // We use R14 to avoid spill of RBX
        bool ArgDefFound = false;

        auto defineR14 = [&](MachineInstr &MI) {
          for (const MCPhysReg &SubReg : TRI->subregs_inclusive(X86::R14)) {
            if (MI.definesRegister(SubReg, nullptr))
              return true;
          }
          return false;
        };

        do {
          It = std::prev(It);
          if (!SetupFound && It->getOpcode() == FrameSetupOpcode) {
            ToBeRemoved.push_back(&*It);
            SetupFound = true;
            if (ArgDefFound)
              break;
          }
          if (!ArgDefFound && defineR14(*It)) {
            ArgDefFound = true;
            if (!It->isInlineAsm()) {
              // The only valid define of R14 is InlineAsm for calling ABI0
              ToBeRemoved.push_back(&*It);
            }
            if (SetupFound)
              break;
          }
          // Optimization may move arg pass before FrameSetup.
          // e.g., os.(*rawConn).Read
          // Try our best and search in the same basic block.
        } while (It != MBB.begin());

        It = std::next(MI.getIterator());
        while (It != MBB.end()) {
          if (It->getOpcode() == FrameDestroyOpcode) {
            DestoryFound = true;
            ToBeRemoved.push_back(&*It);
            break;
          }
          It = std::next(It);
        }
        if (!SetupFound || !DestoryFound) {
          // dbgs() << "Search results: " << ArgDefFound << " " << SetupFound << " " << DestoryFound << "\n";
          // MF->dump();
          report_fatal_error("incorrect cleanup of phantom call to runtime.KeepAlive");
        }
        continue;
      }

      if (F->getName() != StringRef("runtime.gcWriteBarrier"))
        continue;

      unsigned ImplicitSrcIdx = 0;
      const char * NewSymbol = nullptr;
      for (unsigned I = 1, E = MI.getNumOperands(); I < E; I++) {
        MachineOperand &MO = MI.getOperand(I);
        if (!MO.isReg())
          continue;
        switch (MO.getReg()) {
        default:
          continue;
        case X86::RDI:
          continue;
        case X86::RAX:
          break;
        case X86::RBX:
          NewSymbol = "runtime.gcWriteBarrierBX";
          break;
        case X86::RCX:
          NewSymbol = "runtime.gcWriteBarrierCX";
          break;
        case X86::RDX:
          NewSymbol = "runtime.gcWriteBarrierDX";
          break;
        case X86::RSI:
          NewSymbol = "runtime.gcWriteBarrierSI";
          break;
        case X86::R8:
          NewSymbol = "runtime.gcWriteBarrierR8";
          break;
        case X86::R9:
          NewSymbol = "runtime.gcWriteBarrierR9";
          break;
        case X86::RBP:
          NewSymbol = "runtime.gcWriteBarrierRBP";
          break;
        }
        if (ImplicitSrcIdx == 0) {
          ImplicitSrcIdx = I;
        } else {
          report_fatal_error("found two implicit src reg");
        }
      }

      if (ImplicitSrcIdx == 0) {
        dbgs() << MI;
        report_fatal_error("cannot find implicit src reg");
      }

      if (NewSymbol != nullptr) {
        Callee.ChangeToES(NewSymbol, Callee.getTargetFlags());
        Changed = true;
      }
    }

  if (!ToBeRemoved.empty()) {
    Changed = true;
    for (auto *MI : ToBeRemoved)
      MI->eraseFromParent();
  }

  return Changed;
}

// Runs after StackSlotColoring: negative fixed FIs must never reach LiveStacks.
bool X86GoFixupPostRegAllocPass::reuseArgSpillArea() {
  const Function &F = MF->getFunction();
  auto *Args = F.getMetadata("go.caller.args.area");
  if (!ReuseArgSpillArea || !Args || MF->empty() ||
      F.getCallingConv() != CallingConv::Go_Internal ||
      F.getFnAttribute("go-no-frame-checked").getValueAsString() == "true")
    return false;
  auto &MFI = MF->getFrameInfo();
  const auto *TII = MF->getSubtarget<X86Subtarget>().getInstrInfo();
  const auto *TRI = MF->getSubtarget<X86Subtarget>().getRegisterInfo();
  static const unsigned IntRegs[] = {X86::RAX, X86::RBX, X86::RCX,
      X86::RDI, X86::RSI, X86::R8, X86::R9, X86::R10, X86::R11};
  static const unsigned FloatRegs[] = {X86::XMM0, X86::XMM1, X86::XMM2,
      X86::XMM3, X86::XMM4, X86::XMM5, X86::XMM6, X86::XMM7,
      X86::XMM8, X86::XMM9, X86::XMM10, X86::XMM11, X86::XMM12,
      X86::XMM13, X86::XMM14};
  bool Changed = false;
  if (Args->getNumOperands() < 2 || (Args->getNumOperands() - 2) % 4)
    return false;
  for (unsigned A = 2; A < Args->getNumOperands(); A += 4) {
    auto Read = [&](unsigned I) {
      return cast<ConstantInt>(cast<ConstantAsMetadata>(
          Args->getOperand(I))->getValue())->getSExtValue();
    };
    int64_t Idx = Read(A), Offset = Read(A + 1), Size = Read(A + 2);
    if (!Idx || Idx < -15 || Idx > 9 || Size <= 0 || Offset < 8)
      continue;
    unsigned Reg = Idx > 0 ? IntRegs[Idx - 1] : FloatRegs[-Idx - 1];
    bool LiveIn = false;
    for (auto LI : MF->front().liveins())
      LiveIn |= TRI->regsOverlap(LI.PhysReg, Reg);
    if (!LiveIn)
      continue;
    MachineInstr *Spill = nullptr;
    int FI = 0;
    unsigned SpillBytes = 0;
    // RA may sink an entry spill onto one side of an entry branch (notably
    // main.handle). Follow only single-predecessor chains, proving the source
    // unchanged on the entire path from entry. Do not cross joins or cycles.
    for (auto &MBB : *MF) {
      for (auto &MI : MBB) {
        int Slot;
        unsigned Bytes = 0;
        Register Src = TII->isStoreToStackSlot(MI, Slot, Bytes);
        if (!Src || !TRI->regsOverlap(Src, Reg))
          continue;
        bool Original = true;
        SmallPtrSet<const MachineBasicBlock *, 8> Seen;
        const MachineBasicBlock *Block = &MBB;
        MachineBasicBlock::const_instr_iterator End = MI.getIterator();
        while (true) {
          if (!Seen.insert(Block).second) {
            Original = false;
            break;
          }
          for (auto It = Block->instr_begin(); It != End; ++It)
            if (It->modifiesRegister(Reg, TRI))
              Original = false;
          if (!Original || Block == &MF->front())
            break;
          if (Block->pred_size() != 1) {
            Original = false;
            break;
          }
          Block = *Block->pred_begin();
          End = Block->instr_end();
        }
        if (Original) {
          Spill = &MI;
          FI = Slot;
          SpillBytes = Bytes;
          break;
        }
      }
      if (Spill)
        break;
    }
    if (!Spill || FI < 0 || MFI.isDeadObjectIndex(FI) ||
        !MFI.isSpillSlotObjectIndex(FI) || MFI.getObjectAllocation(FI) ||
        SpillBytes != MFI.getObjectSize(FI) ||
        MFI.getObjectSize(FI) > Size || MFI.getObjectAlign(FI) > Align(8) ||
        uint64_t(Offset - 8) % MFI.getObjectAlign(FI).value())
      continue;
    // Address-taken parameters may already use go.preallocated fixed objects.
    // Their writes must not alias an independently live RA spill of the old
    // parameter value. This also avoids introducing overlapping fixed PSVs.
    bool Overlap = false;
    for (int Other = MFI.getObjectIndexBegin(); Other < 0; ++Other) {
      if (MFI.isDeadObjectIndex(Other))
        continue;
      int64_t Begin = MFI.getObjectOffset(Other);
      Overlap |= Begin < Offset - 8 + MFI.getObjectSize(FI) &&
                 Offset - 8 < Begin + MFI.getObjectSize(Other);
    }
    if (Overlap)
      continue;
    // Accept only plain full-slot accesses. In particular, reject address-taking
    // and every other store, including slots merged by stack-slot coloring.
    bool Legal = true;
    for (auto &MBB : *MF) {
      for (auto &MI : MBB) {
        bool Ref = false;
        for (auto &MO : MI.operands())
          Ref |= MO.isFI() && MO.getIndex() == FI;
        for (auto *MMO : MI.memoperands())
          if (auto *PSV = dyn_cast_or_null<FixedStackPseudoSourceValue>(
                  MMO->getPseudoValue()))
            Ref |= PSV->getFrameIndex() == FI;
        if (!Ref || &MI == Spill || MI.isDebugInstr() ||
            MI.getOpcode() == TargetOpcode::STATEPOINT)
          continue;
        int LoadFI;
        if (MI.mayStore() || !TII->isLoadFromStackSlot(MI, LoadFI) ||
            LoadFI != FI)
          Legal = false;
      }
    }
    if (!Legal)
      continue;
    // Fixed-object offset zero denotes entry SP+8 (past the return address).
    int NewFI = MFI.CreateFixedSpillStackObject(
        MFI.getObjectSize(FI), Offset - 8);
    MFI.setObjectAlignment(NewFI, MFI.getObjectAlign(FI));
    const auto *NewPSV = MF->getPSVManager().getFixedStack(NewFI);
    for (auto &MBB : *MF)
      for (auto &MI : MBB) {
        for (auto &MO : MI.operands())
          if (MO.isFI() && MO.getIndex() == FI)
            MO.setIndex(NewFI);
        for (auto *MMO : MI.memoperands())
          if (auto *PSV = dyn_cast_or_null<FixedStackPseudoSourceValue>(
                  MMO->getPseudoValue()))
            if (PSV->getFrameIndex() == FI)
              MMO->setValue(NewPSV);
      }
    MFI.RemoveStackObject(FI);
    Changed = true;
  }
  return Changed;
}
