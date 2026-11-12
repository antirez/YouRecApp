import SwiftUI
import UIKit

// The button only opens the inspector. Direct gain manipulation belongs to the
// waveform, where its amplitude can respond under the user's finger.
struct QuickVolumeControl: UIViewRepresentable {
    var value: Double?
    var enabled: Bool
    var headroom: AudioHeadroom?
    var tap: () -> Void
    func makeUIView(context: Context) -> GainButton { GainButton() }
    func updateUIView(_ view: GainButton, context: Context) { view.configure(self) }
}

final class GainButton: UIControl {
    private var model: QuickVolumeControl?
    private var touchStart = CGPoint.zero
    private var tapStillValid = false
    private let title = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "speaker.wave.2"))
    override init(frame: CGRect) {
        super.init(frame: frame)
        title.text = "Volume"; title.font = .systemFont(ofSize: 10, weight: .medium); title.textColor = .white; title.textAlignment = .center
        icon.contentMode = .scaleAspectFit; icon.tintColor = .white; addSubview(icon); addSubview(title)
        layer.cornerRadius = 12; backgroundColor = UIColor(white: 0.12, alpha: 1)
        isAccessibilityElement = true; accessibilityLabel = "Volume"; accessibilityIdentifier = "audio.quickGain"
        accessibilityHint = "Open volume controls. You can also swipe an audio waveform up or down."
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { CGSize(width: 56, height: 44) }
    override func layoutSubviews() { super.layoutSubviews(); icon.frame = CGRect(x: 0, y: 5, width: bounds.width, height: 20); title.frame = CGRect(x: 0, y: 27, width: bounds.width, height: 14) }
    func configure(_ model: QuickVolumeControl) {
        self.model = model; isEnabled = model.enabled; isUserInteractionEnabled = isEnabled; alpha = isEnabled ? 1 : 0.35
        accessibilityTraits = isEnabled ? [.button] : [.button, .notEnabled]
        accessibilityValue = model.value.map { String(format: "%+.1f dB", $0) + (model.headroom?.clips(at: $0) == true ? ", Clipping" : "") } ?? "Mixed"
    }
    override func beginTracking(_ touch:UITouch,with event:UIEvent?)->Bool {
        touchStart=touch.location(in:self);tapStillValid=isEnabled;return isEnabled
    }
    override func continueTracking(_ touch:UITouch,with event:UIEvent?)->Bool {
        let point=touch.location(in:self)
        if hypot(point.x-touchStart.x,point.y-touchStart.y)>8 {tapStillValid=false}
        return true
    }
    override func endTracking(_ touch:UITouch?,with event:UIEvent?) {
        defer {tapStillValid=false}
        guard tapStillValid,let touch,bounds.contains(touch.location(in:self)) else {return}
        model?.tap()
    }
    override func cancelTracking(with event:UIEvent?) {tapStillValid=false}
    override func accessibilityActivate() -> Bool { guard isEnabled else { return false }; model?.tap(); return true }
}

// A single unobtrusive readout, never an inspector or a sheet.
final class WaveformGainReadout: UILabel {
    init() {
        super.init(frame: .zero)
        font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        textAlignment = .center; textColor = .white
        backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        layer.cornerRadius = 12; layer.borderWidth = 1; clipsToBounds = true
        isUserInteractionEnabled = false; isAccessibilityElement = true
        accessibilityIdentifier = "audio.waveformGainReadout"
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(level: Double?, clipping: Bool, cancelling: Bool, point: CGPoint, in window: UIWindow) {
        if superview !== window { window.addSubview(self) }
        text = cancelling ? "Cancel" : level.map { String(format: "%+.1f dB", $0) } ?? "Mixed"
        textColor = clipping && !cancelling ? .systemRed : .white
        layer.borderColor = (clipping && !cancelling ? UIColor.systemRed : UIColor.systemCyan).cgColor
        accessibilityValue = clipping && !cancelling ? "Clipping" : ""
        frame = CGRect(x: min(window.bounds.width-window.safeAreaInsets.right-108, max(window.safeAreaInsets.left+8, point.x-110)),
                       y: min(window.bounds.height-window.safeAreaInsets.bottom-40, max(window.safeAreaInsets.top+8, point.y-48)), width: 100, height: 32)
    }
}
