import AVFoundation

/// Joue le son produit par le moteur. Le moteur écrit dans un tampon circulaire,
/// le système audio vient y lire au rythme du haut-parleur.
final class AudioOutput {
    let ring: OpaquePointer
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var interruptionObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?

    init(sampleRate: Double, ring: OpaquePointer) {
        self.ring = ring
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            PTAudioRingRead(ring, left, right, Int(frameCount))
            return noErr
        }
        self.source = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

#if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.start()
        }
#endif
        // Écouteurs branchés ou débranchés, AirPods connectés… : iOS arrête alors le moteur audio
        // (nouvelle sortie, nouvelle fréquence) ; on le relance aussitôt.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            PTLogLine("Sortie audio changée : relance du son")
            self?.start()
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }

    func start() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // « ambient » : le son respecte le bouton silencieux et se mélange aux autres apps.
        try? session.setCategory(.ambient, mode: .default)
        try? session.setPreferredIOBufferDuration(0.01)
        try? session.setActive(true)
#endif
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                PTLogLine("Son indisponible : \(error.localizedDescription)")
            }
        }
    }

    /// Jeu en pause : le son est coupé (il ne tourne plus à vide), repris par `start`.
    func pause() {
        engine.pause()
    }

    func stop() {
        engine.stop()
    }
}
