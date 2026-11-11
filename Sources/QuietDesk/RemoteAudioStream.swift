import AVFAudio
import CoreMedia
import Foundation
import QuietDeskCore

final class HostAudioSender: @unchecked Sendable {
    let epoch: UInt32
    let magicCookie: Data?

    private let encodeQueue = DispatchQueue(label: "quietdesk.audio-encode", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private var paused = false
    private var queuedSampleChunks = 0
    private var encoder: OpusAudioEncoder?
    private var sequence: UInt64 = 0
    private let sendPacket: (RemoteAudioPacket) -> Void

    init(epoch: UInt32, sendPacket: @escaping (RemoteAudioPacket) -> Void) throws {
        guard epoch > 0 else {
            throw DeskError.invalid("远端音频发送代次无效")
        }
        let opusEncoder = try OpusAudioEncoder()
        self.epoch = epoch
        self.magicCookie = opusEncoder.magicCookie
        self.encoder = opusEncoder
        self.sendPacket = sendPacket
    }

    func setPaused(_ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard !stopped, paused != value else { return false }
            paused = value
            return true
        }
        guard changed else { return }
        encodeQueue.async { [weak self] in
            self?.encoder?.reset()
        }
    }

    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard wasRunning else { return }
        encodeQueue.async { [weak self] in
            self?.encoder = nil
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let shouldExtract = lock.withLock { () -> Bool in
            guard !stopped, !paused, queuedSampleChunks < 6 else { return false }
            queuedSampleChunks += 1
            return true
        }
        guard shouldExtract else { return }

        // Extract PCM immediately on the audio capture queue so CMSampleBuffer retention never spans async hops.
        let extracted: [Float]
        do {
            extracted = try RemoteAudioSampleExtractor.extractInterleavedStereo48k(sampleBuffer)
        } catch {
            lock.withLock { queuedSampleChunks = max(0, queuedSampleChunks - 1) }
            return
        }
        guard !extracted.isEmpty else {
            lock.withLock { queuedSampleChunks = max(0, queuedSampleChunks - 1) }
            return
        }

        encodeQueue.async { [weak self] in
            guard let self else { return }
            let active = self.lock.withLock { () -> Bool in
                self.queuedSampleChunks = max(0, self.queuedSampleChunks - 1)
                return !self.stopped && !self.paused
            }
            guard active, let encoder = self.encoder else { return }
            guard let packets = try? encoder.encode(interleavedStereoSamples: extracted), !packets.isEmpty else {
                return
            }
            for opusPayload in packets {
                guard self.sequence < UInt64.max else {
                    self.stop()
                    return
                }
                self.sequence &+= 1
                if let packet = try? RemoteAudioPacket(
                    epoch: self.epoch,
                    sequence: self.sequence,
                    opusPayload: opusPayload
                ) {
                    self.sendPacket(packet)
                }
            }
        }
    }
}

protocol AudioPlayoutBackend: AnyObject {
    func scheduleInterleavedStereo48k(_ samples: [Float], onConsumed: @escaping @Sendable () -> Void) throws
    func resetPlayout()
    func stop()
}

final class AVAudioEnginePlayoutBackend: AudioPlayoutBackend {
    private let format: AVAudioFormat
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var configObserver: NSObjectProtocol?
    private let queue: DispatchQueue

    init(queue: DispatchQueue) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(RemoteAudioControl.sampleRate),
            channels: AVAudioChannelCount(RemoteAudioControl.channels)
        ) else {
            throw DeskError.invalid("无法初始化 48 kHz 立体声音频格式")
        }
        self.format = format
        self.queue = queue
    }

    deinit {
        stop()
    }

    private func ensureStarted() throws -> AVAudioPlayerNode {
        if let engine, let playerNode, engine.isRunning {
            if !playerNode.isPlaying {
                playerNode.play()
            }
            return playerNode
        }
        teardownEngine()

        let newEngine = AVAudioEngine()
        let outputChannels = newEngine.outputNode.outputFormat(forBus: 0).channelCount
        guard outputChannels > 0 else {
            throw DeskError.invalid("本机当前没有可用的音频输出设备")
        }
        let node = AVAudioPlayerNode()
        newEngine.attach(node)
        newEngine.connect(node, to: newEngine.mainMixerNode, format: format)
        newEngine.prepare()
        try newEngine.start()
        node.play()

        self.engine = newEngine
        self.playerNode = node
        let targetQueue = self.queue
        self.configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: nil
        ) { [weak self] _ in
            targetQueue.async {
                self?.teardownEngine()
            }
        }
        return node
    }

    func scheduleInterleavedStereo48k(_ samples: [Float], onConsumed: @escaping @Sendable () -> Void) throws {
        let frameCount = samples.count / RemoteAudioControl.channels
        guard frameCount > 0 else {
            onConsumed()
            return
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = pcmBuffer.floatChannelData else {
            onConsumed()
            throw DeskError.invalid("无法分配音频播放缓冲区")
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let left = channelData[0]
        let right = channelData[1]
        for frame in 0..<frameCount {
            left[frame] = samples[frame * 2]
            right[frame] = samples[frame * 2 + 1]
        }
        let node = try ensureStarted()
        node.scheduleBuffer(pcmBuffer, completionCallbackType: .dataConsumed) { _ in
            onConsumed()
        }
    }

    func resetPlayout() {
        playerNode?.stop()
    }

    func stop() {
        teardownEngine()
    }

    private func teardownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        playerNode?.stop()
        engine?.stop()
        if let engine, let playerNode {
            engine.detach(playerNode)
        }
        playerNode = nil
        engine = nil
    }
}

final class ViewerAudioPlayer: @unchecked Sendable {
    private static let maxInFlightBuffers = 3
    private let playoutQueue = DispatchQueue(label: "quietdesk.audio-playout", qos: .userInteractive)
    private let stateLock = NSLock()
    private var configuredActive = false
    private var configuredPaused = false
    private var acceptingPackets: Bool { configuredActive && !configuredPaused }

    private var activeEpoch: UInt32 = 0
    private var paused = false
    private var decoder: OpusAudioDecoder?
    private var jitterBuffer = RemoteAudioJitterBuffer(prebufferPackets: 2, maxTotalBufferedPackets: 5)
    private var backend: AudioPlayoutBackend?
    private let makeBackend: (DispatchQueue) throws -> AudioPlayoutBackend
    private var inFlightBuffers = 0
    private var playoutGeneration: UInt64 = 0
    private var reportedOutputError = false
    private let onError: ((String) -> Void)?

    init(
        makeBackend: ((DispatchQueue) throws -> AudioPlayoutBackend)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        self.makeBackend = makeBackend ?? { queue in try AVAudioEnginePlayoutBackend(queue: queue) }
        self.onError = onError
    }

    func start(epoch: UInt32, magicCookie: Data?, paused: Bool) {
        stateLock.withLock {
            configuredActive = epoch > 0
            configuredPaused = paused
        }
        playoutQueue.async { [weak self] in
            guard let self else { return }
            self.playoutGeneration &+= 1
            self.inFlightBuffers = 0
            self.reportedOutputError = false
            self.activeEpoch = epoch
            self.paused = paused
            self.jitterBuffer.reset(epoch: epoch)
            self.backend?.resetPlayout()
            self.decoder = try? OpusAudioDecoder(magicCookie: magicCookie)
        }
    }

    func setPaused(_ value: Bool) {
        stateLock.withLock { configuredPaused = value }
        playoutQueue.async { [weak self] in
            guard let self, self.paused != value else { return }
            self.paused = value
            if value {
                self.playoutGeneration &+= 1
                self.inFlightBuffers = 0
                self.jitterBuffer.reset(epoch: self.activeEpoch)
                self.decoder?.reset()
                self.backend?.resetPlayout()
            }
        }
    }

    func stop() {
        stateLock.withLock {
            configuredActive = false
            configuredPaused = false
        }
        playoutQueue.async { [weak self] in
            guard let self else { return }
            self.playoutGeneration &+= 1
            self.inFlightBuffers = 0
            self.activeEpoch = 0
            self.paused = false
            self.reportedOutputError = false
            self.jitterBuffer.reset(epoch: 0)
            self.decoder = nil
            self.backend?.stop()
            self.backend = nil
        }
    }

    func receive(_ packet: RemoteAudioPacket) {
        guard stateLock.withLock({ acceptingPackets }) else { return }
        playoutQueue.async { [weak self] in
            guard let self, self.activeEpoch > 0, !self.paused else { return }
            guard packet.epoch == self.activeEpoch else { return }
            guard self.jitterBuffer.push(packet, inFlightPlayoutBuffers: self.inFlightBuffers) else { return }
            self.drainPlayoutQueue()
        }
    }

    private func drainPlayoutQueue() {
        guard activeEpoch > 0, !paused else { return }
        if decoder == nil {
            decoder = try? OpusAudioDecoder()
        }
        guard let decoder else { return }

        let readyPackets = jitterBuffer.popReadyPackets(
            inFlightPlayoutBuffers: inFlightBuffers,
            maxInFlightBuffers: Self.maxInFlightBuffers
        )
        guard !readyPackets.isEmpty else { return }

        if backend == nil {
            do {
                backend = try makeBackend(playoutQueue)
            } catch {
                reportOutputFailureOnce(error.localizedDescription)
                return
            }
        }
        guard let backend else { return }

        let generation = playoutGeneration
        for packet in readyPackets {
            guard let decoded = try? decoder.decode(packet.opusPayload), !decoded.isEmpty else {
                continue
            }
            inFlightBuffers += 1
            do {
                try backend.scheduleInterleavedStereo48k(decoded) { [weak self] in
                    self?.playoutQueue.async {
                        guard let self, self.playoutGeneration == generation else { return }
                        self.inFlightBuffers = max(0, self.inFlightBuffers - 1)
                        self.drainPlayoutQueue()
                    }
                }
            } catch {
                inFlightBuffers = max(0, inFlightBuffers - 1)
                reportOutputFailureOnce(error.localizedDescription)
                break
            }
        }
    }

    private func reportOutputFailureOnce(_ message: String) {
        guard !reportedOutputError else { return }
        reportedOutputError = true
        onError?(message)
    }
}
