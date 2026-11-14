#!/bin/sh
# Compiles and runs the SQL lexer / autocomplete tests (no database needed).
set -eu
cd "$(dirname "$0")/.."
mkdir -p target
swiftc -O -module-cache-path target/swift-module-cache \
  macos/SQLLexer.swift macos/SQLVocabulary.swift macos/SQLCompletion.swift macos/ValueFormatter.swift macos/Tests/main.swift \
  -o target/editor-tests
target/editor-tests
