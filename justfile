name := 'swiftpaste'
swiftc := 'xcrun -sdk macosx swiftc'
swift_args := '-I . -Osize'

# compile into binary
build:
  {{swiftc}} {{swift_args}} -o {{name}}-arm -target arm64-apple-macos11     {{name}}.swift
  {{swiftc}} {{swift_args}} -o {{name}}-x86 -target x86_64-apple-macos10.15 {{name}}.swift
  lipo -create -output {{name}} {{name}}-arm {{name}}-x86

# run from script
run:
  swift -I . {{name}}.swift
