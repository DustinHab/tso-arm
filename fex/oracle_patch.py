#!/usr/bin/env python3
"""Adds the oracle experiment to a FEX checkout (run in the FEX source root).

TSO_PLAIN_LIST=FILE names a file of guest instruction addresses (hex, one per line). Those instructions are
translated with plain memory accesses (ForceTSO disabled); all others keep the configured TSO setting.
rep movs/stos follow the same per-instruction decision.
"""
import pathlib
import sys


def patch(path, old, new, count=1):
    p = pathlib.Path(path)
    text = p.read_text()
    if new in text:
        return
    if text.count(old) != count:
        sys.exit(f"{path}: expected {count} occurrence(s) of:\n{old}")
    p.write_text(text.replace(old, new))


ctx = "FEXCore/Source/Interface/Context/Context.h"
patch(ctx,
      "  IntervalList<uint64_t> ForceTSOValidRanges;",
      "  fextl::set<uint64_t> PlainInstructions; // tso-arm oracle: translated without TSO\n"
      "  IntervalList<uint64_t> ForceTSOValidRanges;")

core = "FEXCore/Source/Interface/Core/Core.cpp"
patch(core,
      "bool ContextImpl::InitCore() {\n",
      "bool ContextImpl::InitCore() {\n"
      "  if (const char* PlainList = getenv(\"TSO_PLAIN_LIST\")) {\n"
      "    if (FILE* F = fopen(PlainList, \"r\")) {\n"
      "      char Line[64];\n"
      "      while (fgets(Line, sizeof(Line), F)) {\n"
      "        PlainInstructions.insert(strtoull(Line, nullptr, 16));\n"
      "      }\n"
      "      fclose(F);\n"
      "    }\n"
      "    LogMan::Msg::IFmt(\"tso-arm: {} plain instructions from {}\", PlainInstructions.size(), PlainList);\n"
      "  }\n")
patch(core,
      "          Thread->OpDispatcher->SetForceTSO(ForceTSO);\n",
      "          if (ForceTSO == IR::ForceTSOMode::NoOverride && PlainInstructions.contains(InstAddress)) {\n"
      "            ForceTSO = IR::ForceTSOMode::ForceDisabled;\n"
      "          }\n"
      "          Thread->OpDispatcher->SetForceTSO(ForceTSO);\n")
patch(core, "#include <cstdint>\n", "#include <cstdint>\n#include <cstdio>\n#include <cstdlib>\n")

disp = "FEXCore/Source/Interface/Core/OpcodeDispatcher.cpp"
patch(disp, "_MemSet(CTX->IsAtomicTSOEnabled(), Size,", "_MemSet(IsTSOEnabled(RegClass::GPR), Size,")
patch(disp, "_MemCpy(CTX->IsAtomicTSOEnabled(), Size,", "_MemCpy(IsTSOEnabled(RegClass::GPR), Size,")
print("patched")
