// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "JackfieldCore",
  platforms: [.iOS(.v13), .macOS(.v11)],
  products: [.library(name: "JackfieldCore", targets: ["JackfieldCore"])],
  targets: [
    .target(name: "JackfieldCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "JackfieldCoreTests", dependencies: ["JackfieldCore"]),
  ]
)
