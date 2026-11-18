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
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
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
#include "llvm/CodeGen/TangoLLVM.h"
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
//
// The incoming-value proof used to be a recursive backward walk with a
// per-query cycle-detection set.  On thrift-generated functions with thousands
// of blocks it rediscovered the same (block, register) states from every store
// site, making the pass superlinear (multi-hour llc on aweme/pack/common).
// It is now a linear forward dataflow computed once per argument register:
//
//   * a provenance set holds the physical registers that still carry the
//     argument register's entry value at the current instruction;
//   * a full-register COPY forwards the provenance, every other definition
//     (including regmask clobbers and sub-register writes) destroys it;
//   * a block entry is proven only when every predecessor proves the same
//     register, so the block entry state is the intersection of predecessors;
//   * blocks that can only be reached through a cycle never get an entry state
//     and keep an empty provenance set, the same conservative rejection as the
//     old "active node revisited" rule.
//
// The accepted/rejected set of spill slots is unchanged; only the proof cost.
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

  using RegVec = SmallVector<Register, 4>;
  // IncomingStore[MI] is set when MI stores a stack slot from a register that
  // still holds the current argument register's entry value.  The flow is
  // rebuilt lazily for every distinct argument register.
  DenseMap<const MachineInstr *, bool> IncomingStore;
  Register CachedArg;
  // Provenance sets at block entry and block exit.  A block appears in
  // EntryState once its entry proof is assigned, and in ExitState once it has
  // been processed; the two must stay distinct so a join never intersects an
  // unprocessed predecessor's default-constructed (empty) state.
  DenseMap<const MachineBasicBlock *, RegVec> EntryState, ExitState;

  // Apply one instruction to the provenance set.  Mirrors the old backward
  // step: only a plain full-register physical COPY keeps the value alive,
  // every other modifying instruction invalidates the overlapping regs.
  auto Transfer = [&](const MachineInstr &MI, RegVec &State) {
    auto Copy = TII->isCopyInstr(MI);
    bool FullCopy = Copy && Copy->Destination->isReg() &&
                    Copy->Source->isReg() &&
                    !Copy->Destination->getSubReg() &&
                    !Copy->Source->getSubReg() &&
                    Copy->Source->getReg().isPhysical();
    // A copy can forward provenance into a register not previously tracked,
    // so copies are inspected even when the destination is outside State.
    bool SrcProven =
        FullCopy && is_contained(State, Copy->Source->getReg());
    // The destination definition invalidates overlapping proven registers.
    llvm::erase_if(State, [&](Register R) {
      return MI.modifiesRegister(R, TRI);
    });
    if (SrcProven)
      State.push_back(Copy->Destination->getReg());
  };

  auto BuildDataFlow = [&](Register ArgReg) {
    IncomingStore.clear();
    EntryState.clear();
    ExitState.clear();
    CachedArg = ArgReg;

    MachineBasicBlock &Front = MF->front();
    EntryState[&Front].push_back(ArgReg);
    SmallVector<const MachineBasicBlock *, 32> Worklist;
    Worklist.push_back(&Front);
    while (!Worklist.empty()) {
      const MachineBasicBlock *B = Worklist.pop_back_val();
      if (ExitState.count(B))
        continue;
      RegVec State = EntryState[B];
      for (const MachineInstr &MI : *B)
        Transfer(MI, State);
      // Inserting the exit state marks B processed; its successors may now
      // use it in their join intersections.
      ExitState[B] = State;
      for (const MachineBasicBlock *Succ : B->successors()) {
        if (EntryState.count(Succ))
          continue;
        // A join gets an entry state only once every predecessor has been
        // processed (not merely reached); blocks fed by a backedge can never
        // satisfy this and stay without a state, the same conservative
        // rejection as the old active-node cycle rule.
        bool Ready = true;
        for (const MachineBasicBlock *Pred : Succ->predecessors())
          if (!ExitState.count(Pred)) {
            Ready = false;
            break;
          }
        if (!Ready)
          continue;
        RegVec Joined;
        for (const MachineBasicBlock *Pred : Succ->predecessors()) {
          const RegVec &PredState = ExitState.find(Pred)->second;
          if (Pred == *Succ->predecessors().begin()) {
            Joined = PredState;
            continue;
          }
          llvm::erase_if(Joined, [&](Register R) {
            return !is_contained(PredState, R);
          });
        }
        EntryState[Succ] = std::move(Joined);
        Worklist.push_back(Succ);
      }
    }

    // Second forward walk with point-accurate provenance records the answer
    // for every stack-slot store.  Blocks without an entry state (cycles,
    // unreachable blocks) keep an empty provenance set.
    for (const MachineBasicBlock &MBB : *MF) {
      RegVec State;
      if (EntryState.count(&MBB))
        State = EntryState.find(&MBB)->second;
      for (const MachineInstr &MI : MBB) {
        int Slot;
        unsigned Bytes = 0;
        Register Src = TII->isStoreToStackSlot(MI, Slot, Bytes);
        if (Src && is_contained(State, Src))
          IncomingStore[&MI] = true;
        Transfer(MI, State);
      }
    }
  };

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
    if (CachedArg != Reg)
      BuildDataFlow(Reg);
    MachineInstr *Spill = nullptr;
    int FI = 0;
    unsigned SpillBytes = 0;
    // RA may sink an entry spill onto one side of an entry branch (notably
    // main.handle).  The precomputed flow encodes the whole-CFG proof.
    for (auto &MBB : *MF) {
      for (auto &MI : MBB) {
        int Slot;
        unsigned Bytes = 0;
        Register Src = TII->isStoreToStackSlot(MI, Slot, Bytes);
        if (!Src || !IncomingStore.count(&MI))
          continue;
        Spill = &MI;
        FI = Slot;
        SpillBytes = Bytes;
        break;
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
        if (!Ref || MI.isDebugInstr() ||
            MI.getOpcode() == TargetOpcode::STATEPOINT)
          continue;
        int StoreFI;
        unsigned StoreBytes = 0;
        Register StoreSrc = TII->isStoreToStackSlot(MI, StoreFI, StoreBytes);
        if (StoreSrc && StoreFI == FI && StoreBytes == MFI.getObjectSize(FI) &&
            IncomingStore.count(&MI))
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
        SmallVector<MachineMemOperand *, 2> MemRefs;
        bool TagSpill = SpillBytes == Size && F.getMetadata("go.arginfo") &&
                        IncomingStore.contains(&MI);
        for (auto *MMO : MI.memoperands()) {
          if (auto *PSV = dyn_cast_or_null<FixedStackPseudoSourceValue>(
                  MMO->getPseudoValue())) {
            if (PSV->getFrameIndex() == FI) {
              MMO->setValue(NewPSV);
              if (TagSpill && MMO->isStore())
                MMO = MF->getMachineMemOperand(
                    MMO, MMO->getFlags() | TangoLLVMCodeGen::IncomingArgSpill);
            }
          }
          if (TagSpill)
            MemRefs.push_back(MMO);
        }
        if (TagSpill)
          MI.setMemRefs(*MF, MemRefs);
      }
    MFI.RemoveStackObject(FI);
    Changed = true;
  }
  return Changed;
}
