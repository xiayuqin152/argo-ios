// swift-tools-version:5.9
import PackageDescription

// Core logic for the Argo mobile companion. Shared Argo Foundation sources
// are regular files in LoomKitShared; see shared-sources.json for provenance.
// No private repository checkout or sibling Mac tree is required.
let package = Package(
    name: "ArgoMobileKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ArgoMobileKit", targets: ["ArgoMobileKit"]),
    ],
    targets: [
        .target(name: "ArgoMobileKit", path: "Sources/ArgoMobileKit"),
        .testTarget(name: "ArgoMobileKitTests", dependencies: ["ArgoMobileKit"], path: "Tests/ArgoMobileKitTests"),
    ]
)
