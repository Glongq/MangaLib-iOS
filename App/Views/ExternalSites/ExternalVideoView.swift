import AVKit
import SwiftUI

/// One visible player owns one asset. Leaving the card cancels all HTTP transfers.
@MainActor
private final class ExternalVideoPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var errorMessage: String?
    @Published private(set) var buffering = false
    @Published private(set) var hasPresentedFrame = false
    private var loader: ExternalVideoResourceLoader?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var generation = UUID()
    private var watched = 0.0
    private var lastTime: Double?
    var onState: (Bool, Bool) -> Void = { _, _ in }
    var onProgress: (Double) -> Void = { _ in }

    func start(_ video: ExternalVideo) {
        stop()
        let token = UUID()
        generation = token
        errorMessage = nil
        buffering = true
        watched = 0
        lastTime = nil
        let loader = ExternalVideoResourceLoader(video: video)
        self.loader = loader
        let item = AVPlayerItem(asset: loader.makeAsset())
        item.preferredForwardBufferDuration = 4
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Не удалось воспроизвести видео."
                    self.buffering = false
                    self.onState(false, false)
                }
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                let ready = self.player.currentItem?.status == .readyToPlay
                let playing = player.timeControlStatus == .playing
                if playing { self.hasPresentedFrame = true }
                self.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.onState(ready, playing)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                let current = time.seconds
                if let previous = self.lastTime, self.player.rate > 0 {
                    let delta = current - previous
                    // Seeking across the movie is not watch time.
                    if delta > 0 && delta <= 1.5 { self.watched += delta }
                }
                self.lastTime = current
                let duration = self.player.currentItem?.duration.seconds ?? 0
                if duration.isFinite && duration > 0 { self.onProgress(min(1, self.watched / duration)) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.player.seek(to: .zero) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, finished, self.generation == token else { return }
                        self.lastTime = nil
                        self.player.play()
                    }
                }
            }
        }
        player.play()
    }

    func stop() {
        generation = UUID()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        playbackObservation = nil
        player.replaceCurrentItem(with: nil)
        loader?.invalidate()
        loader = nil
        buffering = false
        hasPresentedFrame = false
        onState(false, false)
    }
}

private struct ExternalNativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

struct ExternalVideoView: View {
    let video: ExternalVideo
    let shouldPlay: Bool
    var onState: (Bool, Bool) -> Void = { _, _ in }
    var onProgress: (Double) -> Void = { _ in }
    @StateObject private var playback = ExternalVideoPlayback()
    @Environment(\.scenePhase) private var scenePhase

    private var active: Bool { shouldPlay && scenePhase == .active }

    var body: some View {
        ZStack {
            Color.black
            ExternalNativeVideoPlayer(player: playback.player)
            if !playback.hasPresentedFrame, let poster = video.posterURL {
                ExternalImage(url: poster) { Color.black }
                    .scaledToFit()
                    .allowsHitTesting(false)
            }
            if playback.buffering { ProgressView().tint(.white).allowsHitTesting(false) }
            if let error = playback.errorMessage {
                VStack(spacing: 12) {
                    Text(error).font(.footnote).multilineTextAlignment(.center)
                    Button("Повторить", systemImage: "arrow.clockwise") {
                        if active { playback.start(video) }
                    }
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .padding(20)
            }
        }
        .task(id: active) {
            playback.onState = onState
            playback.onProgress = onProgress
            if active { playback.start(video) }
            else { playback.stop() }
        }
        .onDisappear { playback.stop() }
    }
}

struct ExternalVideoViewer: View {
    let detail: ExternalGalleryDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let video = detail.video {
                ExternalVideoView(video: video, shouldPlay: true, onState: { ready, playing in
                    if ready && playing { ExternalHistoryStore.shared.record(detail) }
                })
            }
            Button("Закрыть", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(14)
                .background(.black.opacity(0.55), in: Circle())
                .padding(16)
        }
        .preferredColorScheme(.dark)
        .onDisappear { ExternalHistoryStore.shared.flush() }
    }
}
