// OpenVision - SessionRecorder.swift
// Records the glasses point-of-view (video) plus the phone microphone (audio) into a single
// .mp4 and saves it to the Photos library — for demo clips of "what I'm looking at and the
// answer I'm getting back."
//
// Design notes:
//  • Video comes from the glasses stream as CMSampleBuffers (see GlassesManager.onVideoSampleBuffer),
//    muxed straight into an AVAssetWriter — no re-encode of the pixels beyond H.264.
//  • Audio comes from THIS service's OWN AVAudioEngine mic tap, deliberately independent of
//    AudioCaptureService / the realtime backends (in live-video mode those own the mic, so we
//    can't rely on them). Because the audio session is `.playAndRecord` + `.defaultToSpeaker`,
//    the AI's spoken (TTS) reply plays out the speaker and the mic picks it up — so the recording
//    contains the scene sound AND the assistant's answer, "as experienced".
//      Tradeoffs (acceptable for demo clips): speaker-captured audio is roomy, not studio-clean;
//      if TTS is routed to a Bluetooth headset it won't be captured; Bluetooth adds slight AV lag.
//  • Both tracks are timestamped on ONE host clock so they stay in sync.
//
// All AVAssetWriter mutation happens on a private serial queue; video frames arrive on the main
// actor and audio buffers on the audio render thread, so both are hopped onto that queue.

import Foundation
import AVFoundation
import Photos
import CoreMedia

enum RecorderError: LocalizedError {
    case inputUnavailable
    case tapFailed(String)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: return "Microphone input unavailable"
        case .tapFailed(let reason): return "Mic tap failed: \(reason)"
        }
    }
}

final class SessionRecorder: ObservableObject {

    static let shared = SessionRecorder()

    /// Whether a recording is currently in progress (published on the main thread for the UI).
    @Published private(set) var isRecording = false

    /// Called on the main thread after `stop()` finishes, with the saved asset URL (or nil on failure).
    var onFinished: ((URL?) -> Void)?

    // MARK: - Writer state (touched only on `writerQueue`)

    private let writerQueue = DispatchQueue(label: "com.openvision.session-recorder")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private let hostClock = CMClockGetHostTimeClock()
    /// Host time of the first video frame; the writer session starts at .zero, everything else is
    /// stamped relative to this. `nil` until the first video frame creates the writer.
    private var sessionStart: CMTime?
    private var outputURL: URL?
    private var finished = false

    // MARK: - Audio capture (own engine)

    /// Recreated (not just restarted) on every mic re-arm: a stopped engine keeps reporting the
    /// pre-route-change input format, and installing a tap with that stale format fails forever.
    private var audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    /// Canonical output format we feed to the writer: mono Int16, 44.1kHz — trivial to package as
    /// a CMSampleBuffer and fine for AAC transcode.
    private let audioOutFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 44_100,
                                               channels: 1,
                                               interleaved: true)!

    private init() {}

    // MARK: - Public API

    /// Begin recording. Video frames must then be forwarded via `appendVideoSampleBuffer(_:)`.
    /// The writer is created lazily on the first video frame (once we know the pixel dimensions).
    func start() throws {
        guard !isRecording else { return }

        let dir = FileManager.default.temporaryDirectory
        let name = "OpenVision-\(Int(CMClockGetTime(hostClock).seconds * 1000)).mp4"
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        writerQueue.sync {
            self.outputURL = url
            self.writer = nil
            self.videoInput = nil
            self.pixelAdaptor = nil
            self.audioInput = nil
            self.sessionStart = nil
            self.finished = false
        }

        try startMic()

        DispatchQueue.main.async { self.isRecording = true }
        NSLog("[Recorder] Started → %@", url.lastPathComponent)
    }

    /// Stop recording, finalize the file, and save it to Photos. `onFinished` fires on the main
    /// thread with the saved URL (or nil on failure).
    func stop() {
        guard isRecording else { return }

        // Tear the mic down first so no more audio is enqueued.
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        DispatchQueue.main.async { self.isRecording = false }

        writerQueue.async {
            guard let writer = self.writer, !self.finished else {
                // Nothing was ever written (e.g. no frames arrived) — report failure cleanly.
                self.finish(url: nil)
                return
            }
            self.finished = true
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                if writer.status == .completed, let url = self.outputURL {
                    self.saveToPhotos(url)
                } else {
                    NSLog("[Recorder] finishWriting failed: %@", String(describing: writer.error))
                    self.finish(url: nil)
                }
            }
        }
    }

    // MARK: - Video

    /// Forward a glasses video frame into the recording. Safe to call from the main actor.
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CMClockGetTime(hostClock)
        writerQueue.async {
            self.handleVideo(pixelBuffer: pixelBuffer, now: now)
        }
    }

    private func handleVideo(pixelBuffer: CVPixelBuffer, now: CMTime) {
        if writer == nil {
            createWriter(firstPixelBuffer: pixelBuffer, firstFrameTime: now)
        }
        guard let adaptor = pixelAdaptor, let input = videoInput,
              let start = sessionStart, input.isReadyForMoreMediaData else { return }
        let pts = CMTimeSubtract(now, start)
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    private func createWriter(firstPixelBuffer: CVPixelBuffer, firstFrameTime: CMTime) {
        guard let url = outputURL,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            NSLog("[Recorder] Failed to create AVAssetWriter")
            return
        }

        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)

        // Video input (H.264).
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        let srcAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(firstPixelBuffer)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput,
                                                           sourcePixelBufferAttributes: srcAttrs)
        if writer.canAdd(vInput) { writer.add(vInput) }

        // Audio input (AAC).
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) { writer.add(aInput) }

        guard writer.startWriting() else {
            NSLog("[Recorder] startWriting failed: %@", String(describing: writer.error))
            return
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = vInput
        self.pixelAdaptor = adaptor
        self.audioInput = aInput
        self.sessionStart = firstFrameTime
        NSLog("[Recorder] Writer ready (%dx%d)", width, height)
    }

    // MARK: - Audio

    private func startMic() throws {
        try installMicTap()
        registerConfigObserver()
    }

    /// Observe configuration changes on the CURRENT engine instance. Must be re-registered every
    /// time the engine is recreated, since the notification is delivered per engine object.
    private func registerConfigObserver() {
        if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
        // When another audio consumer (e.g. a live-video backend) starts or the route changes, the
        // shared input is reconfigured and our engine silently stops delivering buffers. Re-arm the
        // tap on the new format so recording keeps capturing audio through that transition.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine, queue: .main) { [weak self] _ in
                self?.restartMicAfterConfigChange()
        }
    }

    private func installMicTap() throws {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)   // defensive: never install over an existing tap
        let nativeFormat = input.outputFormat(forBus: 0)

        // During a route transition the input can briefly report a dead (0 Hz) or stale format.
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }
        audioConverter = AVAudioConverter(from: nativeFormat, to: audioOutFormat)

        // installTap throws an ObjC exception (uncatchable from Swift) on a format mismatch —
        // which DOES happen when a route change (e.g. TTS starting on the glasses' HFP route)
        // lands between reading `nativeFormat` and installing. Catch it like VoiceCommandService
        // does and surface it as a Swift error so the caller can retry after the route settles.
        if let reason = OVCatchException({ [weak self] in
            input.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { buffer, _ in
                self?.handleMic(buffer)
            }
        }) {
            throw RecorderError.tapFailed(reason)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func restartMicAfterConfigChange() {
        guard isRecording else { return }
        // The engine stops itself on a configuration change; rebuild the tap on the new input
        // format and restart. Don't re-arm immediately — installing a tap mid-transition is what
        // crashed with a format-mismatch exception. Wait for the route to settle, then retry a
        // few times. A short audio gap at the transition is expected and acceptable.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        scheduleMicRearm(attempt: 1)
    }

    private func scheduleMicRearm(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isRecording else { return }
            do {
                // Fresh engine: the stopped one reports the stale pre-change format (48 kHz vs the
                // route's real 16 kHz HFP), which made every install attempt mismatch. A new engine
                // reads the live route. Re-register the observer — it's bound per engine instance.
                self.audioEngine = AVAudioEngine()
                self.registerConfigObserver()
                try self.installMicTap()
                NSLog("[Recorder] Mic re-armed after audio config change (attempt %d)", attempt)
            } catch {
                NSLog("[Recorder] Mic re-arm attempt %d failed: %@", attempt, error.localizedDescription)
                if attempt < 3 {
                    self.scheduleMicRearm(attempt: attempt + 1)
                }
                // After 3 failures give up on audio: video keeps recording, and the next
                // configuration change will trigger a fresh re-arm cycle anyway.
            }
        }
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        // Stamp at arrival on the shared host clock so audio lines up with video.
        let now = CMClockGetTime(hostClock)
        guard let converter = audioConverter else { return }

        let ratio = audioOutFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: audioOutFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, statusPtr in
            if supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if let convError { NSLog("[Recorder] audio convert error: %@", convError); return }
        guard outBuffer.frameLength > 0 else { return }

        writerQueue.async {
            self.appendAudio(outBuffer, now: now)
        }
    }

    private func appendAudio(_ buffer: AVAudioPCMBuffer, now: CMTime) {
        // Drop audio that arrives before the first video frame has opened the session.
        guard let input = audioInput, let start = sessionStart, !finished,
              input.isReadyForMoreMediaData else { return }
        var pts = CMTimeSubtract(now, start)
        if pts < .zero { pts = .zero }
        guard let sample = makeAudioSampleBuffer(buffer, pts: pts) else { return }
        input.append(sample)
    }

    /// Package an interleaved mono Int16 PCM buffer as a CMSampleBuffer at the given PTS.
    private func makeAudioSampleBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.int16ChannelData else { return nil }
        let byteCount = frames * MemoryLayout<Int16>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let block = blockBuffer else { return nil }

        let status = channel[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        let format = audioOutFormat.formatDescription
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [MemoryLayout<Int16>.size],
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: - Save

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                NSLog("[Recorder] Photos permission denied")
                self.finish(url: nil)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if success {
                    NSLog("[Recorder] Saved to Photos")
                    self.finish(url: url)
                } else {
                    NSLog("[Recorder] Save failed: %@", String(describing: error))
                    self.finish(url: nil)
                }
            }
        }
    }

    private func finish(url: URL?) {
        DispatchQueue.main.async { self.onFinished?(url) }
    }
}
