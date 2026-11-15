import SwiftUI
import AVFoundation
import MediaPlayer

/// Makes the iPhone's volume buttons change the TV's volume while the app is open (the Sonos-app trick):
/// watch the phone's output volume, send volup/voldown for each step, then put the phone volume back in
/// the middle with a hidden system volume view (which also hides the volume HUD).
/// Only works while MrLTTec Control is in the foreground; iOS doesn't allow it in the background.
final class VolumeButtons: NSObject, ObservableObject {
    var onPress: ((Bool) -> Void)?   // true = up
    private var observation: NSKeyValueObservation?
    private var resetting = false
    private var last: Float = 0.5
    weak var slider: UISlider?

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch { return }
        last = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self = self, let v = change.newValue else { return }
            DispatchQueue.main.async { self.changed(v) }
        }
        // Start from the middle so both buttons always register.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.reset() }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func changed(_ v: Float) {
        if resetting {
            last = v
            return
        }
        if abs(v - last) < 0.001 { return }
        let up = v > last
        last = v
        onPress?(up)
        reset()
    }

    private func reset() {
        guard let s = slider else { return }
        resetting = true
        s.value = 0.5
        s.sendActions(for: .valueChanged)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.resetting = false
            self.last = AVAudioSession.sharedInstance().outputVolume
        }
    }
}

/// The hidden system volume view. Being on screen stops iOS from showing its own volume HUD.
struct HiddenVolumeView: UIViewRepresentable {
    let buttons: VolumeButtons

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        v.alpha = 0.011
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            buttons.slider = v.subviews.compactMap { $0 as? UISlider }.first
        }
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if buttons.slider == nil {
            buttons.slider = uiView.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}
