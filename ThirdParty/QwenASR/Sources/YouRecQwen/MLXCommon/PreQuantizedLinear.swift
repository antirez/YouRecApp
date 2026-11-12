// From soniqo/speech-swift a57702e6f523fa36ac5532d2bdc5f35f701a052c (Apache-2.0).
// YouRec adaptation: flattened module imports; Qwen-only offline runtime.
// Loader, input contract and cancellation changes are documented in PROVENANCE.md.
import Foundation
import MLX
import MLXNN

extension QuantizedLinear {
    /// A quantized linear layer whose weight, scales and biases are lazy zero
    /// placeholders to be filled in from safetensors — the `QuantizedLinear`
    /// counterpart of `PreQuantizedEmbedding`.
    ///
    /// `QuantizedLinear(inputDimensions, outputDimensions, ...)` draws a random
    /// weight and quantizes it lazily. The three outputs of that one
    /// `MLX.quantized` op are siblings that keep each other alive, and
    /// `update(parameters:)` overwrites them in place, which bypasses the
    /// sibling release in `mlx::core::array::~array` (ml-explore/mlx#4710).
    /// The unevaluated graph of every such layer therefore outlived the model,
    /// on every load. The checkpoint replaces all three arrays anyway, so
    /// nothing is lost by starting from placeholders.
    public static func preQuantized(
        _ inputDimensions: Int,
        _ outputDimensions: Int,
        bias: Bool = false,
        groupSize: Int = 64,
        bits: Int = 4
    ) -> QuantizedLinear {
        let packedInputDimensions = inputDimensions * bits / 32
        let groupCount = inputDimensions / groupSize
        let layer = QuantizedLinear(
            weight: MLXArray.zeros([outputDimensions, packedInputDimensions], dtype: .uint32),
            bias: bias ? MLXArray.zeros([outputDimensions], dtype: .bfloat16) : nil,
            scales: MLXArray.zeros([outputDimensions, groupCount], dtype: .bfloat16),
            biases: MLXArray.zeros([outputDimensions, groupCount], dtype: .bfloat16),
            groupSize: groupSize,
            bits: bits)
        layer.freeze()
        return layer
    }
}
