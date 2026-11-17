#!/bin/sh
# Where FEX's opcode dispatcher chooses ordered (TSO) or plain memory IR.
cd ~/src/FEX/FEXCore/Source/Interface
grep -rn -E 'AutoTSO|IsAtomicTSOEnabled\(\)|IsVectorAtomicTSOEnabled\(\)|NonTSO' Core/OpcodeDispatcher.cpp Core/OpcodeDispatcher.h Core/OpcodeDispatcher/*.cpp IR/IREmitter.h IR/IREmitter.cpp 2>/dev/null | head -60
echo ---- IREmitter AutoTSO
grep -n -B2 -A22 'LoadMemAutoTSO(' IR/IREmitter.h | head -80
