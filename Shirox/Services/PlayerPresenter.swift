//
//  PlayerPresenter.swift
//  Shirox
//
//  Created by 686udjie on 05/03/2026.
//

import SwiftUI
import AVFoundation
import Combine

#if os(iOS)
import UIKit
#endif

#if canImport(GoogleCast)
@preconcurrency import GoogleCast
#endif

/// Time to wait after sheet `onDismiss` fires before calling `presentPlayer` — the callback fires
/// when the sheet is committed to dismiss, not when the animation completes, so
/// `findTopViewController` would otherwise still see the sheet's VC in the hierarchy.
let streamSelectionDelay: TimeInterval = 0.35

@MainActor
final class PlayerPresenter: ObservableObject {
    static let shared = PlayerPresenter()

    #if os(iOS)
    @Published var orientationLock = UIInterfaceOrientationMask.portrait
    #endif

    /// Set by `presentRatingPromptIfNeeded` after the user finishes the last episode.
    /// Observed by `RootTabView` which presents the rating sheet via SwiftUI — using
    /// native `.sheet()` so dark mode and detent backgrounds match other sheets.
    @Published var pendingRatingContext: PlayerContext?

    #if os(iOS)
    private weak var playerVC: UIViewController?
    private var sourceView: UIView?
    /// Last interface orientation observed during a player session via device-orientation notifications.
    private var trackedPlayerOrientation: UIInterfaceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?
    #endif

    nonisolated private init() {}


    #if !os(iOS)

    func presentPlayer(stream: StreamResult, streams: [StreamResult] = [], context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil, onSequelNeeded: SequelLoader? = nil, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil, from sourceView: Any? = nil) {
        // TODO: implement this function for tv and macos
    }

    #else
    static func findTopViewController(_ viewController: UIViewController? = nil) -> UIViewController? {
        let root = viewController ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            // The app's own window, not whichever window happens to be first: the Cloudflare
            // bypass runs in a separate `.alert`-level window, and presenting the player on that
            // one puts it behind/inside a window that gets torn down.
            .compactMap { scene in
                scene.windows.first(where: { $0.isKeyWindow })
                    ?? scene.windows.first(where: { !$0.isHidden && $0.windowLevel == .normal })
                    ?? scene.windows.first
            }
            .first?.rootViewController

        if let presented = root?.presentedViewController, !presented.isBeingDismissed {
            return findTopViewController(presented)
        }

        if let navigationController = root as? UINavigationController {
            return findTopViewController(navigationController.visibleViewController ?? navigationController)
        }

        if let tabBarController = root as? UITabBarController,
           let selected = tabBarController.selectedViewController {
            return findTopViewController(selected)
        }

        return root
    }

    /// ~2 seconds at 100ms per attempt — long enough to outlast a sheet dismissal animation,
    /// short enough that a genuinely stuck hierarchy doesn't retry forever.
    private static let maxPresentRetries = 20
    /// Retries left for the in-flight `presentPlayer` attempt (see `presentPlayer`).
    private var presentRetriesRemaining = PlayerPresenter.maxPresentRetries

    func presentPlayer(stream: StreamResult, streams: [StreamResult] = [], context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil, onSequelNeeded: SequelLoader? = nil, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil, from sourceView: UIView? = nil) {
        guard let topVC = Self.findTopViewController() else { return }

        // A player is already on screen (double-tap on an episode row, or a re-entrant launch
        // while the previous one is still animating in). Presenting a second one stacks two
        // AVPlayers, both holding audio focus. Checked against the window so a stale reference
        // can never wedge playback shut; a player on its way out falls through to the retry
        // below instead, so relaunching straight after a dismiss still works.
        if let existing = playerVC, existing.viewIfLoaded?.window != nil, !existing.isBeingDismissed { return }

        // UIKit silently refuses to present on a controller that is still presenting something
        // else — which is exactly what happens when the stream-picker sheet is still animating
        // out. Call sites schedule us on a fixed `streamSelectionDelay`, and when that delay
        // isn't long enough (slow device, heavy detail screen, a sheet that dismissed late) the
        // player just never appeared and the user was left staring at the episode list. Wait for
        // the hierarchy to settle instead of dropping the launch on the floor.
        if topVC.presentedViewController != nil || topVC.isBeingDismissed || topVC.isBeingPresented {
            guard presentRetriesRemaining > 0 else {
                Logger.shared.log("[Player] Presentation blocked and retries exhausted — giving up", type: "Error")
                presentRetriesRemaining = Self.maxPresentRetries
                return
            }
            presentRetriesRemaining -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.presentPlayer(stream: stream, streams: streams, context: context, onWatchNext: onWatchNext, onStreamExpired: onStreamExpired, onSequelNeeded: onSequelNeeded, onSequelAdvanced: onSequelAdvanced, onFinished: onFinished, from: sourceView)
            }
            return
        }
        // Settled — restore the full budget for the next launch.
        presentRetriesRemaining = Self.maxPresentRetries

        self.sourceView = sourceView

        let playerView = PlayerView(
            stream: stream,
            streams: streams,
            customDismiss: { [weak self] in self?.dismissPlayer() },
            context: context,
            onWatchNext: onWatchNext,
            onStreamExpired: onStreamExpired,
            onSequelNeeded: onSequelNeeded,
            onSequelAdvanced: onSequelAdvanced,
            onFinished: onFinished
        )
        .tint(.primary)
        .ignoresSafeArea()
        
        let hostingController = PlayerHostingController(rootView: playerView)
        hostingController.modalPresentationStyle = UIModalPresentationStyle.fullScreen

        let forceLandscape = UserDefaults.standard.bool(forKey: "forceLandscape")
        let lastRaw = UserDefaults.standard.integer(forKey: "lastLandscapeOrientation")
        let lastLandscape = UIInterfaceOrientation(rawValue: lastRaw)
        let preferredLandscape: UIInterfaceOrientation = (lastLandscape != nil && lastLandscape!.isLandscape) ? lastLandscape! : .landscapeRight

        // iOS 18+ Zoom Transition — skip when launching in landscape because the zoom
        // animation runs in portrait and the subsequent rotation causes a visible flash.
        if #available(iOS 18.0, *), let sourceView = sourceView, !forceLandscape {
            hostingController.preferredTransition = .zoom { _ in
                return sourceView
            }
        }

        self.playerVC = hostingController

        // Set the lock before presentation so supportedInterfaceOrientations is correct
        // from the very first frame. preferredInterfaceOrientationForPresentation on
        // PlayerHostingController returns the last landscape side, so iOS
        // will present the VC directly in that side.
        self.orientationLock = forceLandscape ? .landscape : .allButUpsideDown
        // Seed the tracker with where the player will actually open. Seeding it with a landscape
        // side unconditionally meant a player opened and closed in portrait (without ever
        // rotating, so no orientation notification corrected it) looked landscape to
        // dismissPlayer — which then skipped the dismiss animation and persisted a
        // `lastLandscapeOrientation` the user never chose.
        trackedPlayerOrientation = forceLandscape ? preferredLandscape : snapshotCurrentOrientation()
        startTrackingOrientation()

        topVC.present(hostingController, animated: true)
    }

    func dismissPlayer() {
        guard let playerVC = playerVC else { return }
        let wasLandscape = trackedPlayerOrientation.isLandscape
        // Save the side one last time before dismissing
        if wasLandscape {
            UserDefaults.standard.set(trackedPlayerOrientation.rawValue, forKey: "lastLandscapeOrientation")
        }
        stopTrackingOrientation()
        // Reset orientation without animation before dismissing.
        // UIView.performWithoutAnimation suppresses the system rotation animation on the
        // root VC so the app snaps to portrait instantly instead of animating.
        orientationLock = .portrait
        UIView.performWithoutAnimation { refreshSupportedOrientations() }
        playerVC.dismiss(animated: !wasLandscape) { [weak self] in
            self?.playerVC = nil
            self?.sourceView = nil
        }
    }

    /// Called after the player view has already been manually animated off screen (drag-to-dismiss).
    func dragDismiss() {
        guard let playerVC = playerVC else { return }
        if trackedPlayerOrientation.isLandscape {
            UserDefaults.standard.set(trackedPlayerOrientation.rawValue, forKey: "lastLandscapeOrientation")
        }
        stopTrackingOrientation()
        orientationLock = .portrait
        UIView.performWithoutAnimation { refreshSupportedOrientations() }
        playerVC.dismiss(animated: false) { [weak self] in
            self?.playerVC = nil
            self?.sourceView = nil
        }
    }

    // MARK: - Rating prompt

    /// Called from PlayerView.onDisappear when the user finished the last episode.
    /// Centralized here so every player launch path (DetailView, ContinueWatching, AniListDetail)
    /// gets the rating prompt without each call site needing to pass an `onFinished` closure.
    func presentRatingPromptIfNeeded(context: PlayerContext) {
        let enabled = UserDefaults.standard.object(forKey: "rateOnFinish") as? Bool ?? true
        Logger.shared.log("[Rating] presentRatingPromptIfNeeded: enabled=\(enabled) aniListID=\(context.aniListID.map(String.init) ?? "nil") malID=\(context.malID.map(String.init) ?? "nil")", type: "Debug")
        guard enabled else { return }
        guard context.aniListID != nil || context.malID != nil else {
            Logger.shared.log("[Rating] presentRatingPromptIfNeeded: no IDs — bail", type: "Debug")
            return
        }
        Task { @MainActor in
            var aniScore: Double = 0
            var malScore: Double = 0
            if let aid = context.aniListID, AniListAuthManager.shared.isLoggedIn {
                if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                    aniScore = raw.score
                }
            }
            if let mid = context.malID, MALAuthManager.shared.isLoggedIn {
                if let entry = try? await MALProvider.shared.fetchEntry(mediaId: mid) {
                    malScore = entry.score
                }
            }
            Logger.shared.log("[Rating] presentRatingPromptIfNeeded: aniScore=\(aniScore) malScore=\(malScore)", type: "Debug")
            guard aniScore == 0 && malScore == 0 else {
                Logger.shared.log("[Rating] presentRatingPromptIfNeeded: already rated — skip", type: "Debug")
                return
            }
            Logger.shared.log("[Rating] presentRatingPromptIfNeeded: setting pendingRatingContext", type: "Debug")
            self.pendingRatingContext = context
        }
    }

    /// Called by the SwiftUI sheet's onSave to push the score to AniList/MAL.
    func submitRating(_ score: Double, for context: PlayerContext) {
        Task { @MainActor in
            if let aid = context.aniListID, AniListAuthManager.shared.isLoggedIn,
               let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                try? await AniListLibraryService.shared.updateEntry(mediaId: aid, status: raw.status, progress: raw.progress, score: score)
            }
            if let mid = context.malID, MALAuthManager.shared.isLoggedIn,
               let entry = try? await MALProvider.shared.fetchEntry(mediaId: mid) {
                do {
                    try await MALProvider.shared.updateEntry(mediaId: mid, status: entry.status, progress: entry.progress, score: score)
                } catch {
                    Logger.shared.log("[Rating] MAL score update failed: \(error)", type: "Error")
                }
            }
        }
    }

    // MARK: - Orientation tracking

    private func startTrackingOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let mapped = self?.snapshotCurrentOrientation()
                // Only update for concrete orientations (ignore faceUp/faceDown/unknown).
                if let o = mapped, o != .unknown {
                    self?.trackedPlayerOrientation = o
                    if o.isLandscape {
                        UserDefaults.standard.set(o.rawValue, forKey: "lastLandscapeOrientation")
                    }
                }
            }
        }
    }

    private func stopTrackingOrientation() {
        if let obs = orientationObserver {
            NotificationCenter.default.removeObserver(obs)
            orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// Converts the live device orientation to an interface orientation.
    /// Returns the last scene orientation as a fallback for flat/unknown positions.
    private func snapshotCurrentOrientation() -> UIInterfaceOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:      return .landscapeRight
        case .landscapeRight:     return .landscapeLeft
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        default:
            return (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
        }
    }

    func resetToAppOrientation(shouldRotate: Bool = false) {
        #if !targetEnvironment(macCatalyst)
        updateOrientationLock(.portrait, shouldRotate: shouldRotate)
        #endif
    }

    func updateOrientationLock(_ orientation: UIInterfaceOrientationMask, shouldRotate: Bool = false) {
        #if !targetEnvironment(macCatalyst)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }

        self.orientationLock = orientation

        if shouldRotate {
            let preferredRotation: UIInterfaceOrientationMask
            if orientation == .landscape {
                preferredRotation = .landscapeRight
            } else if orientation == .portrait {
                preferredRotation = .portrait
            } else {
                preferredRotation = orientation
            }
            requestRotation(to: preferredRotation)
        }

        refreshSupportedOrientations()
        #endif
    }

    func requestRotation(to orientation: UIInterfaceOrientationMask) {
        #if !targetEnvironment(macCatalyst)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if #available(iOS 16, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
        } else {
            let value: Int
            switch orientation {
            case .portrait: value = UIInterfaceOrientation.portrait.rawValue
            case .landscapeLeft: value = UIInterfaceOrientation.landscapeLeft.rawValue
            case .landscapeRight: value = UIInterfaceOrientation.landscapeRight.rawValue
            default: value = UIInterfaceOrientation.portrait.rawValue
            }
            UIDevice.current.setValue(value, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
        #endif
    }

    func refreshSupportedOrientations() {
        if #available(iOS 16, *) {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }
    #endif
}

// MARK: - Cast Manager

@MainActor
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()
    
    @Published var isConnected = false
    @Published var currentDeviceName: String?
    @Published var isPlaying = false
    @Published var currentPosition: Double = 0
    @Published var duration: Double = 0
    
    private var progressTimer: Timer?
    private var volumeObserver: NSKeyValueObservation?

    private override init() {
        super.init()
        #if canImport(GoogleCast)
        setupCast()
        #endif
    }
    
    private func setupCast() {
        #if canImport(GoogleCast)
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        
        let controller = GCKCastContext.sharedInstance().defaultExpandedMediaControlsViewController
        controller.setButtonType(.rewind30Seconds, at: 0)
        controller.setButtonType(.playPauseToggle, at: 1)
        controller.setButtonType(.forward30Seconds, at: 2)
        controller.setButtonType(.none, at: 3)
        
        GCKCastContext.sharedInstance().sessionManager.add(self)
        updateState()
        #endif
    }
    
    private func updateState() {
        #if canImport(GoogleCast)
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        isConnected = session != nil
        currentDeviceName = session?.device.friendlyName

        // Keep the app alive in the background so CastProxyServer keeps serving
        // segments after the screen locks; iOS otherwise suspends us ~30s in.
        #if os(iOS)
        if isConnected {
            BackgroundKeepAlive.shared.acquire("cast")
        } else {
            BackgroundKeepAlive.shared.release("cast")
        }
        #endif

        if let remoteMediaClient = session?.remoteMediaClient {
            remoteMediaClient.add(self)
            updateMediaStatus(remoteMediaClient.mediaStatus)
            startVolumeObservation()
        } else {
            stopProgressTimer()
            stopVolumeObservation()
            isPlaying = false
            currentPosition = 0
            duration = 0
        }
        #endif
    }

    private func startVolumeObservation() {
        #if os(iOS)
        guard volumeObserver == nil else { return }
        let audioSession = AVAudioSession.sharedInstance()
        volumeObserver = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                #if canImport(GoogleCast)
                GCKCastContext.sharedInstance().sessionManager.currentCastSession?.setDeviceVolume(session.outputVolume)
                #endif
            }
        }
        #endif
    }

    private func stopVolumeObservation() {
        volumeObserver?.invalidate()
        volumeObserver = nil
    }
    
    #if canImport(GoogleCast)
    private func updateMediaStatus(_ status: GCKMediaStatus?) {
        guard let status = status else { return }
        isPlaying = status.playerState == .playing || status.playerState == .buffering
        duration = status.mediaInformation?.streamDuration ?? 0
        currentPosition = status.streamPosition
        
        if isPlaying {
            startProgressTimer()
        } else {
            stopProgressTimer()
        }
    }
    #endif
    
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentPosition()
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func updateCurrentPosition() {
        #if canImport(GoogleCast)
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
           let remoteMediaClient = session.remoteMediaClient {
            currentPosition = remoteMediaClient.approximateStreamPosition()
        }
        #endif
    }
    
    func play() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.play()
        #endif
    }
    
    func pause() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.pause()
        #endif
    }
    
    func seek(to time: Double) {
        #if canImport(GoogleCast)
        let options = GCKMediaSeekOptions()
        options.interval = time
        options.resumeState = .unchanged
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.seek(with: options)
        #endif
    }
    
    func skip(by seconds: Double) {
        #if canImport(GoogleCast)
        let newTime = currentPosition + seconds
        seek(to: max(0, newTime))
        #endif
    }
    
    func disconnect() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        #endif
    }
    
    func stopCasting() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        #endif
    }
    
    func castMedia(url: URL, title: String, posterUrl: String?, subtitleURL: URL? = nil, startTime: Double = 0) {
        #if canImport(GoogleCast)
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }

        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        if let posterUrl = posterUrl, let posterURL = URL(string: posterUrl) {
            metadata.addImage(GCKImage(url: posterURL, width: 480, height: 720))
        }

        let isHLS = url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.contains(".m3u8")
        Logger.shared.log("[Cast] URL: \(Logger.redact(url)), isHLS: \(isHLS)", type: "Stream")
        let mediaInfoBuilder = GCKMediaInformationBuilder(contentURL: url)
        mediaInfoBuilder.streamType = isHLS ? .unknown : .buffered
        mediaInfoBuilder.contentType = isHLS ? "application/x-mpegURL" : "video/mp4"
        mediaInfoBuilder.metadata = metadata

        if let subtitleURL {
            let textTrack = GCKMediaTrack(
                identifier: 0,
                contentIdentifier: subtitleURL.absoluteString,
                contentType: "text/vtt",
                type: .text,
                textSubtype: .subtitles,
                name: "Subtitles",
                languageCode: "en",
                customData: nil
            )
            mediaInfoBuilder.mediaTracks = [textTrack].compactMap { $0 }
        }

        let mediaInfo = mediaInfoBuilder.build()

        guard let remoteMediaClient = session.remoteMediaClient else { return }
        remoteMediaClient.add(self)

        let requestDataBuilder = GCKMediaLoadRequestDataBuilder()
        requestDataBuilder.mediaInformation = mediaInfo
        requestDataBuilder.startTime = startTime
        if subtitleURL != nil { requestDataBuilder.activeTrackIDs = [0] }
        let request = remoteMediaClient.loadMedia(with: requestDataBuilder.build())
        request.delegate = self
        #endif
    }
}

#if canImport(GoogleCast)
extension CastManager: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        MainActor.assumeIsolated { updateState() }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        MainActor.assumeIsolated { updateState() }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        MainActor.assumeIsolated { updateState() }
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        // GCKMediaStatus is an immutable snapshot; wrap it so the region-isolation
        // checker allows the send across the actor boundary.
        struct StatusBox: @unchecked Sendable { let value: GCKMediaStatus? }
        let box = StatusBox(value: mediaStatus)
        Task { @MainActor in self.updateMediaStatus(box.value) }
    }
}

extension CastManager: GCKRequestDelegate {
    nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        Logger.shared.log("[Cast] Request failed: \(error.localizedDescription)", type: "Error")
    }
}
#endif
