#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
compile=(xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/ModuleCache" Sources/L10n.swift)
inputs=(Sources/InputFrames.swift Sources/InputSink.swift Sources/FunctionRow.swift)
"${compile[@]}" Sources/{FunctionRow,InputSink,QuartzOutput,KeyboardSources,TopRowCommands}.swift Tests/KeyboardTests.swift -o .build/KeyboardTests
.build/KeyboardTests
"${compile[@]}" "${inputs[@]}" Sources/LAN.swift Sources/PairingKey.swift Tests/CoreTests.swift -o .build/CoreTests
.build/CoreTests
"${compile[@]}" "${inputs[@]}" Sources/Transport.swift Tests/TLSFixture.swift -o .build/TLSFixture
python3 Tests/interop.py .build/TLSFixture
"${compile[@]}" "${inputs[@]}" Sources/LAN.swift Sources/PairingKey.swift Sources/Transport.swift Tests/Bindings.swift -o .build/Bindings
.build/Bindings || { code=$?; [[ $code == 77 ]] || exit "$code"; }
