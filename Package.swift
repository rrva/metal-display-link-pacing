// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "PacingRepro",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "VirtualDisplayShim", path: "Sources/VirtualDisplayShim"),
    .executableTarget(
      name: "PacingRepro", dependencies: ["VirtualDisplayShim"], path: "Sources/PacingRepro"),
  ]
)
