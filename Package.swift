// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "PacingRepro",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "PacingRepro", path: "Sources/PacingRepro")
  ]
)
