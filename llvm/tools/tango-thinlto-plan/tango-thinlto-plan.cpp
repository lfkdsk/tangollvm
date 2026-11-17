// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/ModuleSummaryIndex.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/IPO/FunctionImport.h"
#include <map>
#include <vector>

using namespace llvm;

static cl::opt<std::string> Summary(cl::Positional, cl::Required);
static cl::opt<std::string> Output("output", cl::Required);
static cl::opt<unsigned> Budget("budget", cl::init(2000));

int main(int argc, char **argv) {
  cl::ParseCommandLineOptions(argc, argv);
  auto Result = getModuleSummaryIndexForFile(Summary);
  if (!Result) {
    logAllUnhandledErrors(Result.takeError(), errs());
    return 1;
  }

  auto &Index = **Result;
  DenseMap<StringRef, GVSummaryMapTy> Defined;
  Index.collectDefinedGVSummariesPerModule(Defined);
  // Modules with no definitions still own a backend action.
  for (auto &Module : Index.modulePaths())
    Defined.try_emplace(Module.getKey());

  // Keep definitions visible to Go assembly, linkname and fallback Go bodies.
  DenseMap<GlobalValue::GUID, const GlobalValueSummary *> Prevailing;
  for (auto &Entry : Index) {
    const GlobalValueSummary *First = nullptr;
    const GlobalValueSummary *Strong = nullptr;
    for (auto &S : Entry.second.SummaryList) {
      S->setLive(true);
      if (GlobalValue::isAvailableExternallyLinkage(S->linkage()))
        continue;
      if (!First)
        First = S.get();
      if (!Strong && !GlobalValue::isWeakForLinker(S->linkage()))
        Strong = S.get();
    }
    Prevailing[Entry.first] = Strong ? Strong : First;
  }

  DenseMap<StringRef, FunctionImporter::ImportMapTy> Imports;
  DenseMap<StringRef, FunctionImporter::ExportSetTy> Exports;
  ComputeCrossModuleImport(
      Index, Defined,
      [&](GlobalValue::GUID G, const GlobalValueSummary *S) {
        return Prevailing.lookup(G) == S;
      },
      Imports, Exports);

  std::vector<StringRef> Modules;
  for (const auto &Module : Defined)
    Modules.push_back(Module.first);
  llvm::sort(Modules);

  json::Array Plan;
  for (StringRef Module : Modules) {
    std::vector<std::pair<StringRef, GlobalValue::GUID>> Candidates;
    for (auto &Source : Imports[Module])
      for (auto &Import : Source.second)
        if (Import.second == GlobalValueSummary::ImportKind::Definition)
          Candidates.emplace_back(Source.first, Import.first);
    llvm::sort(Candidates);

    unsigned Instructions = 0;
    unsigned Functions = 0;
    FunctionImporter::ImportMapTy Bounded;
    for (auto [Source, GUID] : Candidates) {
      auto *S = dyn_cast_or_null<FunctionSummary>(Defined[Source].lookup(GUID));
      if (!S || Budget == 0 || S->instCount() > Budget - Instructions)
        continue;
      Instructions += S->instCount();
      ++Functions;
      Bounded[Source][GUID] = GlobalValueSummary::ImportKind::Definition;
    }

    std::map<std::string, GVSummaryMapTy> Summaries;
    GVSummaryPtrSet Declarations;
    gatherImportedSummariesForModule(Module, Defined, Bounded, Summaries,
                                     Declarations);
    SmallString<128> Path(Output.getValue());
    sys::path::append(Path, std::to_string(Plan.size()) + ".index.bc");
    std::error_code EC;
    raw_fd_ostream OS(Path, EC);
    if (EC) {
      errs() << Path << ": " << EC.message() << '\n';
      return 1;
    }
    writeIndexToFile(Index, OS, &Summaries, &Declarations);
    OS.close();
    if (OS.has_error()) {
      errs() << Path << ": " << OS.error().message() << '\n';
      OS.clear_error();
      return 1;
    }

    json::Array Sources;
    for (auto &Source : Summaries)
      if (Source.first != Module)
        Sources.push_back(Source.first);
    Plan.push_back(json::Object{{"module", Module},
                                {"index", Path.str()},
                                {"sources", std::move(Sources)},
                                {"functions", Functions}});
  }
  outs() << json::Value(std::move(Plan)) << '\n';
}
