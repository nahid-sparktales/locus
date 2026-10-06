xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 \
  -I /tmp/locus-audit-native-20261006/Build/Products/Debug \
  -I /tmp/locus-audit-native-20261006/SourcePackages/checkouts/swift-cmark/src/include \
  -I /tmp/locus-audit-native-20261006/SourcePackages/checkouts/swift-cmark/extensions/include \
  -I /tmp/locus-audit-native-20261006/SourcePackages/checkouts/swift-markdown/Sources/CAtomic/include \
  -F /tmp/locus-audit-native-20261006/Build/Products/Debug \
  /tmp/locus-audit-native-20261006/Build/Products/Debug/Locus.app/Contents/MacOS/Locus.debug.dylib \
  -Xlinker -rpath -Xlinker /tmp/locus-audit-native-20261006/Build/Products/Debug/Locus.app/Contents/MacOS \
  -Xlinker -rpath -Xlinker /tmp/locus-audit-native-20261006/Build/Products/Debug \
  /tmp/locus-native-findings-fixed-probe.swift -o /tmp/locus-native-findings-fixed-probe
