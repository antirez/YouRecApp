// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "YouRecQwen", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "YouRecQwen", targets: ["YouRecQwen"])], dependencies: [.package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4")], targets: [.target(name: "YouRecQwen", dependencies: [.product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"), .product(name: "MLXFast", package: "mlx-swift"), .product(name: "MLXRandom", package: "mlx-swift")])])
