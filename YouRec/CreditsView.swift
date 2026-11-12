import SwiftUI
import UIKit

struct CreditsView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YouRec").font(.title2.bold())
                    Text("Copyright (C) 2026 by Salvatore Sanfilippo.\nSource code released under the MIT License.")
                }
                .accessibilityElement(children: .combine)
                .padding(.vertical, 4)
                NavigationLink("Full license notices") { LicenseNoticesView() }
                    .accessibilityIdentifier("credits.notices")
            }
            Section("Audio restoration") {
                credit("RNNoise", "Jean-Marc Valin and the Xiph.Org contributors created the speech denoiser. It includes KISS FFT by Mark Borgerding.", "BSD 3-Clause, with BSD 2-Clause components")
                credit("DeepFilterNet3", "Speech enhancement by Hendrik Schröter and contributors. Kyle Howells provided the streaming runtime and Core ML conversion.", "MIT for the model. MIT or Apache 2.0 for the runtime.")
                credit("LavaSR v2", "Yatharth Sharma’s model restores high-frequency speech detail. Its converted network uses the Vocos architecture by Hubert Siuzdak.", "Apache 2.0 for LavaSR. MIT for Vocos.")
                credit("VoiceFixer", "Studio voice restoration by Haohe Liu and contributors. YouRec converted the model to Core ML.", "MIT for the code. Creative Commons Attribution 4.0 (CC BY 4.0) for the model weights.")
            }
            Section("Subtitles") {
                credit("Qwen3-ASR-0.6B", "Speech recognition by the Qwen team. The optional download uses aufklarer’s 4-bit MLX conversion and tokenizer.", "Apache 2.0")
                credit("speech-swift", "YouRec uses Soniqo’s Swift implementation to run Qwen on the iPhone.", "Apache 2.0")
            }
            Section("Libraries") {
                credit("ZIPFoundation", "Thomas Zoechling and contributors built the library used to import and export project archives.", "MIT")
                credit("MLX, MLX C and MLX Swift", "Apple and the MLX contributors provide the on-device inference engine and language bindings.", "MIT")
                credit("metal-cpp", "Apple’s C++ interface to Metal.", "Apache 2.0")
                credit("Swift Numerics", "Apple and the Swift Numerics contributors provide the numerical types used by MLX Swift.", "Apache 2.0 with Runtime Library Exception")
                credit("PocketFFT", "Fourier transforms by Martin Reinecke and Peter Bell, used by MLX.", "BSD 3-Clause")
                credit("Metal math", "MLX’s exponential function includes code by Norbert Juffa.", "BSD 2-Clause")
                credit("fmt", "C++ formatting by Victor Zverovich and contributors.", "MIT")
                credit("JSON for Modern C++", "JSON handling by Niels Lohmann and contributors. Embedded source credits appear in the full notices.", "MIT, with an Apache 2.0 contribution")
            }
            Section("Fonts") {
                NavigationLink("Title and subtitle fonts") {
                    List(TitleTypeface.families.filter { $0.id != "system" }, id: \.id) { face in
                        NavigationLink(face.name) {
                            if let file = Bundle.main.url(forResource: "OFL", withExtension: "txt", subdirectory: "TitleFonts/" + face.id),
                               let notice = try? String(contentsOf: file, encoding: .utf8) {
                                LicenseText(text: notice).navigationTitle(face.name).navigationBarTitleDisplayMode(.inline)
                            }
                        }
                    }.navigationTitle("Fonts")
                }
                Text("All seven font families are distributed under the SIL Open Font License 1.1. Select a family to read its copyright and license.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Platform") {
                credit("Apple frameworks and SF Symbols", "YouRec uses Apple’s camera, audio, graphics, machine learning and interface technologies.", "Apple SDK and SF Symbols license terms")
            }
            Section("Development") {
                credit("Model conversion tools", "YouRec’s build scripts use PyTorch, torchaudio, coremltools, NumPy and PyYAML on the Mac to prepare the audio models.", "BSD 3-Clause for PyTorch, coremltools and NumPy. BSD 2-Clause for torchaudio. MIT for PyYAML.")
                credit("Eileen Collins portrait", "NASA photograph distributed by scikit-image and used in YouRec’s automated camera tests.", "Public domain")
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func credit(_ name: String, _ contribution: String, _ license: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.headline)
            Text(contribution)
            Text(license).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct LicenseNoticesView: View {
    private static let notices: String? = {
        guard let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let thirdParty = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let projectText = try? String(contentsOf: license, encoding: .utf8),
              let thirdPartyText = try? String(contentsOf: thirdParty, encoding: .utf8) else { return nil }
        return projectText + "\n\n" + thirdPartyText
    }()

    var body: some View {
        Group {
            if let notices = Self.notices {
                LicenseText(text: notices)
            } else {
                ContentUnavailableView("License notices unavailable", systemImage: "doc.text")
            }
        }
        .navigationTitle("License notices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// TextKit supports selection, source links, and Dynamic Type in long legal documents.
private struct LicenseText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.dataDetectorTypes = .link
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        view.text = text
        view.accessibilityIdentifier = "credits.licenseText"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}
