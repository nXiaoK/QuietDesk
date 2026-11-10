import Darwin
import Foundation
import Network
import QuietDeskCore

final class Box<T>: @unchecked Sendable {
    let lock = NSLock(); var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func update(_ body: (inout T)->Void) { lock.withLock { body(&value) } }
}
struct Failure: Error { let message: String }
func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
func wait(_ value: DispatchSemaphore, _ message: String, seconds: Double = 8) throws {
    try require(value.wait(timeout:.now()+seconds) == .success,message)
}
func packet(_ seq: UInt32, idr: Bool, largeIDR: Bool = false, hevc: Bool = false, largePredicted: Bool = false) -> VideoPacket {
    // HEVC NAL headers are two bytes: IDR_N_LP is type 20, TRAIL_R type 1, VPS/SPS/PPS types 32/33/34.
    let header: [UInt8] = hevc ? (idr ? [0x28,0x01] : [0x02,0x01]) : [idr ? 0x65 : 0x41]
    var avcc=Data();avcc.put(UInt32(header.count+3));avcc.append(contentsOf:header);avcc.append(contentsOf:[1,2,3])
    if idr && largeIDR || !idr && largePredicted {
        let bytes = idr ? 512*1024 : 64*1024
        let nal=Data(header)+Data(repeating:0x7D,count:bytes-header.count)
        avcc=Data();avcc.put(UInt32(nal.count));avcc.append(nal)
    }
    if hevc {
        return VideoPacket(sequence:seq,codec:.hevc,vps:idr ? Data([0x40,0x01,0x0c]):Data(),sps:idr ? Data([0x42,0x01,0x01]):Data(),
            pps:idr ? Data([0x44,0x01,0xc1]):Data(),avcc:avcc)
    }
    return VideoPacket(sequence:seq,sps:idr ? Data([0x67,0x42,0x00,0x1f]):Data(),pps:idr ? Data([0x68,0xce,0x06]):Data(),
        avcc:avcc)
}
func reserveMediaPort() throws -> (socket: Int32, port: UInt16) {
    for _ in 0..<20 {
        let udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP), tcp = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard udp >= 0, tcp >= 0 else {
            if udp >= 0 { close(udp) };if tcp >= 0 { close(tcp) }
            throw Failure(message:"Could not create fixture port reservations")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let reserved = withUnsafeMutablePointer(to:&address) { pointer in
            pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { raw in
                bind(udp,raw,length) == 0 && getsockname(udp,raw,&length) == 0 && bind(tcp,raw,length) == 0
            }
        }
        close(tcp)
        if reserved { return (udp,UInt16(bigEndian:address.sin_port)) }
        close(udp)
    }
    throw Failure(message:"No paired TCP/UDP fixture port was available")
}
enum PrepareHookCheck { case unchecked, boundStream, fallback }
enum RecoveryConfigurationCheck { case none, restart, unchanged, bitrate }
func exercise(udp: Bool, auxiliary: Bool, rejectFirst: Bool, reconfigure: Bool,
              failRecoveryCandidate: Bool = false, pauseResume: Bool = false, stopCandidate: Bool = false, pathFailure: Bool = false, legacy: Bool = false, restoreUDP: Bool = false, inspectDiagnostics: Bool = false, largeIDR: Bool = false, overlapPrepare: Bool = false, prepareHook: PrepareHookCheck = .unchecked,
              delayedDecode: Bool = false, stalledDecode: Bool = false, liveBitrate: Bool = false,
              inspectRoundTrip: Bool = false, hevc: Bool = false, recoveries: Bool = false,
              deliveryHints: Bool = false, duplicateHints: Bool = false,
              recoveryConfiguration: RecoveryConfigurationCheck = .none, retryHints: Bool = false,
              schedulingStall: Bool = false) throws {
    let key = try PairingKey.generate(), settings = StreamSettings(longestEdge:1920,framesPerSecond:60,megabits:12)
    let queue = DispatchQueue(label:"session.loopback-listener")
    // A random TCP port can already belong to UDP. Reserve both protocols before choosing it.
    let reservation = try reserveMediaPort()
    var udpReservation = reservation.socket
    defer { if udpReservation >= 0 { close(udpReservation) } }
    let params = try MediaSecureTransport.tlsParameters(key:key,roles:MediaChannelRole.allCases)
    params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:reservation.port)!)
    let listener = try NWListener(using:params)
    let listenReady = DispatchSemaphore(value:0), committed = DispatchSemaphore(value:0), dataDone = DispatchSemaphore(value:0), pathStable = DispatchSemaphore(value:0)
    let deliverySampled = DispatchSemaphore(value:0)
    let hostSession = Box<MediaSession?>(nil), viewerSession = Box<MediaSession?>(nil), peers = Box<[Peer]>([])
    let states=Box<[String]>([]), errors=Box<[String]>([]), decoded=Box<[UInt64]>([]), sequence=Box<UInt32>(0), prepared=Box(0), committedCount=Box(0)
    let rejectedCandidate = Box(false), candidateSeen = DispatchSemaphore(value:0)
    let lateDecode = Box<((Bool)->Void)?>(nil)
    let delayedFrameDone = DispatchSemaphore(value: 0), stalledFrameSeen = DispatchSemaphore(value: 0)
    let diagnostics = inspectDiagnostics ? PerformanceDiagnostics(enabled:true) : nil
    let sampledCompute = DispatchSemaphore(value:0)
    let reductions=Box<[MediaBottleneck]>([])
    let localRoutes=Box<[Bool]>([]), roundTripSamples=Box<[MediaPathSample]>([])
    let roundTripSampled=DispatchSemaphore(value:0)
    let reportPaths = Box<[MediaSession.DiagnosticVideoPath]>([])
    let reportRoundTrips = Box<[Double]>([]), reportFragments = Box((trial: 0, committed: 0, lost: 0))
    let reportTailFrame = DispatchSemaphore(value: 0)
    let pathSwitches=Box<[(String,MediaSwitchCause)]>([])
    let overlapSent=Box(false)
    let cursorID = UUID()
    let streamPreparations = Box<[MediaStreamID]>([]), streamBindings = Box<[MediaStreamID]>([])
    let streamVideos = Box<[MediaStreamID]>([]), streamCommits = Box<[MediaStreamID]>([])
    let currentStream = Box<MediaStreamID?>(nil), hostControl = Box<Peer?>(nil)
    let rejectedHintAttempts = Box(0), hintRetryRejected = DispatchSemaphore(value:0), hostResumed = DispatchSemaphore(value:0)
    let stallNextFrame = Box(false), stallDatagrams = Box(0)
    let localStallFinished = DispatchSemaphore(value:0)
    func nextPacket(_ idr: Bool) -> VideoPacket { sequence.update{$0 += 1}; return packet(sequence.get(),idr:idr,largeIDR:largeIDR,hevc:hevc,largePredicted:schedulingStall) }
    listener.newConnectionHandler = { connection in
        let peer = Peer(connection:connection); peers.update{$0.append(peer)}
        peer.onClose={ reason in if !reason.contains("test") { errors.update{$0.append(reason)} } }
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            if let role=MediaSecureTransport.negotiatedRole(on:connection),role != .control {
                if auxiliary { hostSession.get()?.acceptAuxiliary(peer,role:role) } else { peer.close("test rejected auxiliary") }
                peers.update { $0.removeAll { $0 === peer } }
                return
            }
            do {
                let session = try MediaSession.host(control:peer,key:key,port:listener.port!.rawValue,settings:settings,relayRouting:deliveryHints)
                hostControl.update{$0=peer}
                hostSession.update{$0=session}
                session.diagnostics=diagnostics
                session.onPrepareRecovery={ complete in
                    prepared.update{$0 += 1}
                    if retryHints, committedCount.get() == 1, rejectedHintAttempts.get() < 3 {
                        rejectedHintAttempts.update{$0 += 1}
                        complete(false)
                        return
                    }
                    complete(!rejectFirst || prepared.get()>1)
                }
                try require(session.onPrepareStream == nil, "Optional stream preparation was enabled by default")
                if prepareHook == .boundStream {
                    session.onPrepareStream = { stream, complete in
                        streamPreparations.update { $0.append(stream) }
                        do {
                            peer.send(try CursorControl(.binding, cursorID: cursorID, epoch: 1,
                                                        enabled: true, stream: stream).message())
                            complete(true)
                        } catch { errors.update { $0.append("Prepare-stream binding failed: \(error)") }; complete(false) }
                    }
                }
                session.onProduceRecoveryFrame={ [weak session] in session?.sendVideo(nextPacket(true)) }
                session.onResumeFrames={ [weak session] in
                    if !schedulingStall { session?.sendVideo(nextPacket(false)) }
                    hostResumed.signal()
                }
                session.onState={ state in print("HOST",state) }
                session.onAcknowledged={ seq in print("ACK",seq) }
                let receivedData: (Message) -> Void = { message in
                    if message.kind != .clipboardCancel || message.payload != Data([1,2,3]) {
                        errors.update{$0.append("Reliable fixture data changed bytes")}
                    }
                    dataDone.signal()
                }
                session.onReliableData=receivedData
                peer.onMessageHandled={ message,resume in
                    // Before auxiliary binding finishes, reliable data legitimately uses control TCP.
                    if !session.receive(message) { receivedData(message) }
                    resume()
                }
                session.start()
                if legacy { session.sendVideo(nextPacket(true)) }
            } catch { errors.update{$0.append("host init \(error)")} }
        }
        peer.start()
    }
    listener.stateUpdateHandler={ if case .ready=$0 { listenReady.signal() } }
    listener.start(queue:queue)
    try wait(listenReady,"listener ready")
    close(udpReservation);udpReservation = -1
    let connection=NWConnection(host:"127.0.0.1",port:listener.port!,using:try MediaSecureTransport.tlsParameters(key:key,roles:[.control]))
    let client=Peer(connection:connection)
    client.onClose={ reason in errors.update{$0.append("control \(reason)")} }
    client.onReady={
        if legacy {
            client.onMessageHandled={ message,resume in
                if message.kind == .video {
                    do {
                        let old=try VideoPacket.decode(message.payload)
                        if old.codec != (hevc ? .hevc : .h264) { errors.update{$0.append("legacy frame changed codec")} }
                        decoded.update{$0.append(UInt64(old.sequence))};committed.signal()
                    }
                    catch { errors.update{$0.append("legacy frame invalid")} }
                }
                resume()
            }
            return
        }
        do {
            let session=try MediaSession.viewer(control:client,key:key,host:"127.0.0.1",port:listener.port!.rawValue,settings:settings,udpEnabled:udp,relayRouting:deliveryHints)
            viewerSession.update{$0=session}
            session.diagnostics=diagnostics
            if inspectRoundTrip {
                session.onDiagnosticVideoPath = { path in reportPaths.update { $0.append(path) } }
                session.onDiagnosticUDPRoundTrip = { milliseconds in
                    if committedCount.get() == 0 { errors.update { $0.append("A candidate UDP probe reached the report") } }
                    reportRoundTrips.update { $0.append(milliseconds) }
                }
                session.onDiagnosticUDPLoss = { settled, lost in
                    let path = reportPaths.get().last
                    reportFragments.update { counts in
                        switch path {
                        case .trialUDP(relayed: false): counts.trial += settled
                        case .committed(.udp, relayedUDP: false): counts.committed += settled
                        default: errors.update { $0.append("UDP fragments arrived outside their receiver's path") }
                        }
                        counts.lost += lost
                    }
                }
            }
            if schedulingStall {
                session.onBytes = { _ in
                    guard stallNextFrame.get() else { return }
                    stallDatagrams.update{$0 += 1}
                    if stallDatagrams.get() == 3 {
                        stallNextFrame.update{$0=false}
                        Thread.sleep(forTimeInterval:0.35)
                        localStallFinished.signal()
                    }
                }
            }
            session.onLocalNetwork={ local in localRoutes.update{$0.append(local)} }
            session.onReduceLoad={ cause in
                if localRoutes.get().last != false { errors.update{$0.append("Loopback reduction preceded its non-LAN classification")} }
                reductions.update{$0.append(cause)}
            }
            session.onPathSwitch={ label,cause in pathSwitches.update{$0.append((label,cause))} }
            session.onSample={ sample in
                if localRoutes.get().last != false || sample.isLocalNetwork {
                    errors.update{$0.append("Loopback sample used LAN policy or preceded its route classification")}
                }
                if inspectRoundTrip { roundTripSamples.update{$0.append(sample)};roundTripSampled.signal() }
                if (sample.encodeMilliseconds ?? 0)>=45 && (sample.decodeMilliseconds ?? 0)>=2 { sampledCompute.signal() }
                if sample.deliveryMilliseconds != nil, (sample.receivedMegabits ?? 0) > 0 { deliverySampled.signal() }
            }
            session.onVideo={ frame,complete in
                decoded.update{$0.append(frame.header.frameID)}
                if inspectRoundTrip, frame.header.frameID == 3 { reportTailFrame.signal() }
                let expected = packet(frame.packet.sequence,idr:frame.header.isIDR,largeIDR:largeIDR,hevc:hevc,largePredicted:schedulingStall)
                if frame.packet.codec != expected.codec || frame.packet.vps != expected.vps || frame.packet.sps != expected.sps {
                    errors.update{$0.append("Media frame changed its codec or parameter sets in transit")}
                }
                if prepareHook != .unchecked, frame.header.isIDR {
                    if prepareHook == .boundStream, !streamBindings.get().contains(frame.header.stream) {
                        errors.update { $0.append("Candidate video arrived before its exact stream binding") }
                    }
                    streamVideos.update { $0.append(frame.header.stream) }
                }
                if overlapPrepare, frame.header.isIDR, !overlapSent.get() {
                    overlapSent.update{$0=true}
                    do {
                        client.send(try MediaControl(.prepare,sessionID:frame.header.stream.sessionID,transactionID:UUID(),
                            transportEpoch:frame.header.stream.transportEpoch+1,codecEpoch:frame.header.stream.codecEpoch+1,path:"udp").message())
                    } catch { errors.update{$0.append("Overlapping test prepare could not be encoded")} }
                }
                if largeIDR, frame.header.isIDR, frame.packet.avcc != packet(frame.packet.sequence,idr:true,largeIDR:true,hevc:hevc).avcc {
                    errors.update{$0.append("Large IDR payload changed across fragments")};complete(false);return
                }
                if stopCandidate { lateDecode.update{$0=complete};candidateSeen.signal();return }
                if !frame.header.isIDR, stalledDecode, lateDecode.get() == nil {
                    lateDecode.update { $0 = complete }; stalledFrameSeen.signal(); return
                }
                if !frame.header.isIDR, delayedDecode {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                        complete(true); delayedFrameDone.signal()
                    }
                    return
                }
                if failRecoveryCandidate, frame.header.frameID == 1, committedCount.get() > 0, !rejectedCandidate.get() {
                    rejectedCandidate.update{$0=true};complete(false);return
                }
                complete(true)
                complete(true) // A duplicate decoder completion must not duplicate a commit or credit.
            }
            session.onCommitStream={ stream,_ in
                currentStream.update{$0=stream}
                if prepareHook != .unchecked {
                    if prepareHook == .boundStream, !streamBindings.get().contains(stream) {
                        errors.update { $0.append("Media commit preceded its exact stream binding") }
                    }
                    streamCommits.update { $0.append(stream) }
                }
                committedCount.update{$0 += 1};committed.signal()
            }
            session.onState={ state in states.update{$0.append(state)};if ["UDP 视频","TCP 视频","TCP 兼容模式"].contains(state) { pathStable.signal() };print("VIEWER",state) }
            client.onMessageHandled={ message,resume in
                if retryHints, message.kind == .mediaControl, let value = try? MediaControl.read(message.payload), value.operation == .abort {
                    _=session.receive(message)
                    hintRetryRejected.signal()
                } else if message.kind == .cursorControl, prepareHook != .unchecked {
                    do {
                        let binding = try CursorControl.read(message.payload)
                        guard binding.operation == .binding, binding.cursorID == cursorID, binding.epoch == 1,
                              binding.enabled, let stream = binding.stream?.stream else {
                            throw Failure(message: "Prepare-stream binding identity changed")
                        }
                        streamBindings.update { $0.append(stream) }
                    } catch { errors.update { $0.append("Invalid prepare-stream binding: \(error)") } }
                } else { _=session.receive(message) }
                resume()
            }
            session.start()
        } catch { errors.update{$0.append("viewer init \(error)")} }
    }
    defer { viewerSession.get()?.stop();hostSession.get()?.stop();client.close("test done");peers.get().forEach{$0.close("test done")};listener.cancel() }
    client.start()
    if legacy {
        try wait(committed,"Legacy first frame was not delivered")
        let suspended=DispatchSemaphore(value:0)
        hostSession.get()?.suspendForConfiguration { suspended.signal() }
        try wait(suspended,"Legacy configuration suspend did not complete")
        try require(prepared.get()==0,"Legacy configuration entered the new media hold")
        hostSession.get()?.updateSettings(StreamSettings(longestEdge:1920,framesPerSecond:30,megabits:8))
        hostSession.get()?.resumeAfterConfiguration()
        hostSession.get()?.sendVideo(nextPacket(true))
        try wait(committed,"Legacy video froze after configuration")
        hostSession.get()?.setPaused(true)
        hostSession.get()?.setPaused(false)
        hostSession.get()?.resumeAfterConfiguration()
        hostSession.get()?.sendVideo(nextPacket(true))
        try wait(committed,"Legacy video froze after pause and resume")
        try require(prepared.get()==0 && decoded.get().count==3,"Legacy path invoked media recovery or lost frames")
        return
    }
    if stopCandidate {
        try wait(candidateSeen,"Candidate IDR never reached decoder")
        viewerSession.get()?.stop();hostSession.get()?.stop()
        lateDecode.get()?(true)
        let checked=DispatchSemaphore(value:0)
        DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { checked.signal() }
        try wait(checked,"Cancellation fence did not settle")
        try require(committedCount.get()==0,"A late decoder callback committed after stop")
        return
    }
    try wait(committed,"No committed media stream; states \(states.get()), errors \(errors.get())",seconds:10)
    try wait(pathStable,"Committed path state was not published")
    Thread.sleep(forTimeInterval:0.1)
    let expected = udp ? "UDP 视频" : auxiliary ? "TCP 视频" : "TCP 兼容模式"
    try require(states.get().contains(expected),"wrong selected path \(states.get())")
    let firstCause: MediaSwitchCause = udp ? .policy(.initialProbe) : .initial
    try require(pathSwitches.get().contains{ $0.0 == expected && $0.1 == firstCause },"Initial path switch did not report its cause \(pathSwitches.get())")
    try require(!decoded.get().isEmpty,"No decoded media frame")
    try require(localRoutes.get() == [false] && !client.isLocalNetwork,
                "A connected loopback route was not explicitly classified as non-LAN: \(localRoutes.get())")
    if inspectRoundTrip {
        try wait(roundTripSampled,"Media route did not publish its first RTT sample",seconds:3)
        if udp {
            try require(roundTripSamples.get().contains { $0.roundTripMilliseconds.map { $0.isFinite && $0 > 0 && $0 < 1_000 } == true },
                        "Authenticated UDP pongs did not provide measured RTT")
        } else {
            try require(roundTripSamples.get().allSatisfy { $0.roundTripMilliseconds == nil },
                        "Initial TCP RTT used an unmeasured default estimate")
            let before=roundTripSamples.get().count
            viewerSession.get()?.recordControlRoundTrip(milliseconds:200)
            for invalid in [-1.0, .nan, .infinity, 60_001] { viewerSession.get()?.recordControlRoundTrip(milliseconds:invalid) }
            func counted() -> Int? { roundTripSamples.get().indices.first { $0 >= before && roundTripSamples.get()[$0].roundTripMilliseconds == 200 } }
            let deadline=SessionClock.now+5
            while counted().map({ roundTripSamples.get().count <= $0+1 }) ?? true, SessionClock.now<deadline {
                try wait(roundTripSampled,"RTT observation stopped before the window after the control RTT",seconds:2)
            }
            let samples=roundTripSamples.get()
            guard let index=counted() else { throw Failure(message:"Valid control RTT was lost or overwritten by an invalid observation") }
            try require(samples[before..<index].allSatisfy { $0.roundTripMilliseconds == nil },
                        "An invalid control RTT reached the media sample")
            try require(samples.count>index+1 && samples[index+1].roundTripMilliseconds == nil,
                        "One control RTT counted in more than the sample window it arrived in")
        }
    }
    if delayedDecode {
        try wait(delayedFrameDone, "A delayed complete frame did not finish decoding")
        Thread.sleep(forTimeInterval: 0.3)
        try require(committedCount.get() == 1 && !states.get().contains("正在恢复画面"),
                    "A 350 ms complete-frame decode restarted the media stream: \(states.get())")
    }
    if stalledDecode {
        try wait(stalledFrameSeen, "The stalled P-frame never reached the decoder")
        try require(committed.wait(timeout: .now() + 0.5) == .timedOut,
                    "A stalled complete frame still used the short delivery deadline")
        try wait(committed, "A stalled decoder disabled finite recovery", seconds: 7)
        try wait(pathStable, "Recovered TCP state was not published")
        lateDecode.get()?(true)
        Thread.sleep(forTimeInterval: 0.2)
        try require(committedCount.get() == 2 && states.get().last == expected,
                    "Stall recovery or a late decode caused repeated stream commits")
        try require(pathSwitches.get().count == 1, "A same-path recovery was reported as a route change \(pathSwitches.get())")
    }
    if prepareHook == .boundStream {
        try require(prepared.get() == 0 && streamPreparations.get().count == 1,
                    "The optional stream hook did not replace default candidate preparation")
    }
    if overlapPrepare { try require(overlapSent.get() && prepared.get()==1 && committedCount.get()==1,"Overlapping prepare replaced the current transaction") }
    if rejectFirst { try require(prepared.get()>=2,"transient capture readiness did not retry") }
    if auxiliary {
        viewerSession.get()?.sendReliableData(Message(.clipboardCancel,Data([1,2,3])))
        try wait(dataDone,"Bound bulk data was not delivered")
    }
    if pauseResume {
        viewerSession.get()?.setPaused(true)
        let suspended=DispatchSemaphore(value:0)
        hostSession.get()?.suspendForConfiguration { suspended.signal() }
        try wait(suspended,"Pause did not suspend")
        hostSession.get()?.setPaused(true)
        let checked=DispatchSemaphore(value:0)
        DispatchQueue.global().asyncAfter(deadline:.now()+1.2) { checked.signal() }
        try wait(checked,"Pause observation did not settle")
        try require(committedCount.get()==1,"Paused media switched paths or committed a candidate")
        hostSession.get()?.setPaused(false)
        hostSession.get()?.resumeAfterConfiguration()
        viewerSession.get()?.setPaused(false)
        try wait(committed,"Resume did not recover with a fresh IDR")
        try wait(pathStable,"Resumed path state was not published")
        try require(states.get().last=="UDP 视频","Pause caused a false TCP fallback")
    }
    if pathFailure {
        viewerSession.get()?.networkPathChanged()
        try wait(committed,"UDP path failure did not commit TCP",seconds:4)
        try wait(pathStable,"Fallback path state was not published")
        try require(states.get().last=="TCP 视频","UDP path failure selected the wrong fallback")
        try require(pathSwitches.get().last?.0=="TCP 视频","UDP fallback did not report its route change \(pathSwitches.get())")
        if restoreUDP {
            let fallbackTime=SessionClock.now
            try wait(committed,"Healthy UDP did not recover after cooldown",seconds:37)
            try wait(pathStable,"Recovered UDP state was not published")
            try require(states.get().last=="UDP 视频","Recovered path was not UDP")
            try require(pathSwitches.get().last.map{ $0.0=="UDP 视频" && $0.1 == .policy(.recoveryProbe) } == true,"UDP recovery did not report its probe cause \(pathSwitches.get())")
            try require(SessionClock.now-fallbackTime>=29,"UDP recovery ignored its cooldown")
        }
    }
    if liveBitrate {
        let commitsBefore=committedCount.get(), preparedBefore=prepared.get(), decodedBefore=decoded.get().count
        let lower=StreamSettings(longestEdge:1920,framesPerSecond:60,megabits:6)
        hostSession.get()?.updateSettings(lower,restartsStream:false)
        viewerSession.get()?.updateSettings(lower,restartsStream:false)
        for _ in 0..<40 {
            hostSession.get()?.recordComputeTiming(encodeMilliseconds:3)
            hostSession.get()?.sendVideo(nextPacket(false))
            Thread.sleep(forTimeInterval:0.05)
        }
        try wait(deliverySampled,"Host frame delivery timing did not reach a viewer sample",seconds:3)
        try require(committedCount.get()==commitsBefore && prepared.get()==preparedBefore,"A bitrate-only change restarted the stream")
        try require(decoded.get().count>=decodedBefore+30,"Predicted frames stopped after a live bitrate change")
        try require(errors.get().isEmpty,"Live bitrate change failed: \(errors.get())")
    }
    if reconfigure {
        let suspended=DispatchSemaphore(value:0)
        hostSession.get()?.suspendForConfiguration { suspended.signal() }
        try wait(suspended,"Configuration did not suspend")
        hostSession.get()?.sendVideo(nextPacket(false))
        hostSession.get()?.updateSettings(StreamSettings(longestEdge:1920,framesPerSecond:30,megabits:8))
        hostSession.get()?.resumeAfterConfiguration()
        try wait(committed,"Configuration did not commit a fresh epoch")
        try wait(pathStable,"Reconfigured path state was not published")
        try require(committedCount.get()>=2,"Configuration reused the old epoch")
        if failRecoveryCandidate {
            try require(rejectedCandidate.get() && prepared.get()>=4,"A failed post-IDR candidate did not recover through a fresh preparation")
            try require(reductions.get().filter{$0 == .decoder}.count==1 && !reductions.get().contains(.network),"Decoder rejection was misclassified as network failure or counted twice")
            try require(states.get().last=="UDP 视频","Decoder rejection incorrectly forced TCP")
        }
    }
    if schedulingStall {
        guard let host = hostSession.get(), let control = hostControl.get() else { throw Failure(message:"Missing scheduling fixture host") }
        try wait(hostResumed,"Initial host commit did not resume")
        Thread.sleep(forTimeInterval:0.3)
        stallDatagrams.update{$0=0};stallNextFrame.update{$0=true}
        host.sendVideo(nextPacket(false))
        try wait(localStallFinished,"No queued fragment exercised the local scheduling stall")
        try wait(committed,"Local stall did not establish a fresh reference chain")
        try wait(pathStable,"Local-stall recovery did not publish its path")
        try wait(hostResumed,"Local-stall recovery did not resume the host")
        Thread.sleep(forTimeInterval:1.1)
        for _ in 0..<2 {
            guard let stream = currentStream.get() else { throw Failure(message:"Missing post-stall stream") }
            control.send(try MediaControl(.recover,sessionID:stream.sessionID,transportEpoch:stream.transportEpoch,
                                         codecEpoch:stream.codecEpoch,mediaFailure:true).message())
            try wait(committed,"Post-stall delivery recovery did not commit")
            try wait(pathStable,"Post-stall path did not settle")
            try wait(hostResumed,"Post-stall host did not resume")
            Thread.sleep(forTimeInterval:0.3)
        }
        try require(states.get().last == "UDP 视频" && pathSwitches.get().count == 1 && committedCount.get() == 4,
                    "Local scheduling stall was counted as a network interruption: \(states.get())")
    }
    if retryHints {
        guard let control = hostControl.get(), let original = currentStream.get() else { throw Failure(message:"Missing interrupted stream") }
        for copy in 0..<3 {
            Thread.sleep(forTimeInterval:0.3)
            control.send(try MediaControl(.recover,sessionID:original.sessionID,transportEpoch:original.transportEpoch,
                                         codecEpoch:original.codecEpoch,mediaFailure:true).message())
            try wait(hintRetryRejected,"Duplicate hint did not reach a rejected recovery prepare")
            if copy > 0 { try require(currentStream.get() == original,"Rejected prepare changed the active stream") }
        }
        try wait(committed,"Recovery did not resume after rejected prepares")
        try wait(pathStable,"Recovered path was not published")
        try require(states.get().last == "UDP 视频" && pathSwitches.get().count == 1 && committedCount.get() == 2,
                    "Hints for one active stream exhausted the playback failure budget: \(states.get())")
    }
    if recoveries {
        guard let control = hostControl.get() else { throw Failure(message:"Missing fixture host control") }
        try wait(hostResumed,"Initial host commit did not resume")
        for round in 1...4 {
            guard let stream = currentStream.get() else { throw Failure(message:"Missing committed stream") }
            Thread.sleep(forTimeInterval:0.3)
            for copy in 0..<(duplicateHints && round == 1 ? 3 : 1) {
                if copy > 0 { Thread.sleep(forTimeInterval:0.3) }
                control.send(try MediaControl(.recover,sessionID:stream.sessionID,transportEpoch:stream.transportEpoch,
                                             codecEpoch:stream.codecEpoch,mediaFailure:deliveryHints && (!duplicateHints || round <= 2) ? true : nil).message())
            }
            try wait(committed,"Repeated recovery did not commit round \(round)")
            try wait(pathStable,"Repeated recovery did not publish its path")
            try wait(hostResumed,"Repeated recovery did not resume the host")
            let expectedPath = deliveryHints && !duplicateHints && recoveryConfiguration != .restart && round >= 3 ? "TCP 视频" : "UDP 视频"
            try require(states.get().last == expectedPath,"Recovery misclassified normal reconfiguration, duplicate hints or failed playback: \(states.get())")
            if round == 2, recoveryConfiguration != .none {
                guard let host = hostSession.get(), let viewer = viewerSession.get() else { throw Failure(message:"Missing configuration sessions") }
                let updated = StreamSettings(longestEdge:1920,framesPerSecond:recoveryConfiguration == .restart ? 30 : 60,
                                             megabits:recoveryConfiguration == .unchanged ? 12 : 8)
                if recoveryConfiguration == .restart {
                    Thread.sleep(forTimeInterval:0.3)
                    let suspended = DispatchSemaphore(value:0)
                    host.suspendForConfiguration { suspended.signal() }
                    try wait(suspended,"Host configuration did not suspend")
                    host.updateSettings(updated)
                    viewer.updateSettings(updated)
                    host.resumeAfterConfiguration()
                    try wait(committed,"Configuration after interrupted playback did not commit")
                    try wait(pathStable,"Configuration path was not published")
                    try wait(hostResumed,"Configuration did not resume the host")
                } else {
                    host.updateSettings(updated,restartsStream:false)
                    viewer.updateSettings(updated,restartsStream:false)
                }
            }
        }
        try require(committedCount.get() == (recoveryConfiguration == .restart ? 6 : 5),"Repeated or stale delivery hints created extra stream commits")
        let switches = pathSwitches.get()
        let fallsBack = deliveryHints && !duplicateHints && recoveryConfiguration != .restart
        try require(switches.count == (fallsBack ? 2 : 1),"Normal or duplicated recovery hints exhausted the UDP interruption budget")
        if fallsBack {
            try require(switches.last?.1 == .policy(.networkDegraded),"Repeated delivery failures omitted their fallback reason")
        }
    }
    if inspectDiagnostics {
        hostSession.get()?.recordComputeTiming(encodeMilliseconds:45)
        viewerSession.get()?.recordComputeTiming(decodeMilliseconds:2)
        // Keep the local decode observation in the same receive window as the remote host statistic.
        DispatchQueue.global().asyncAfter(deadline:.now()+0.9) { viewerSession.get()?.recordComputeTiming(decodeMilliseconds:2) }
        try wait(sampledCompute,"Authenticated host encode timing did not reach the viewer sample",seconds:3)
        let summaries=diagnostics!.drain()
        let metrics=Set(summaries.map{$0.metric})
        if largeIDR {
            for summary in summaries where [.mediaExpired,.mediaRecovery,.mediaReassembly,.mediaSwitch].contains(summary.metric) {
                print("LARGE",summary.metric.rawValue,"count",summary.count,"max",summary.maximum,"frame",summary.worstIdentifier ?? 0)
            }
        }
        for expected: PerformanceMetric in [.mediaRoundTrip,.mediaSwitch,.mediaTransport,.mediaDatagramSentBytes,.mediaDatagramReceivedBytes,.mediaReassembly] {
            try require(metrics.contains(expected),"Missing observable media diagnostic \(expected)")
        }
    }
    if largeIDR { try require(committedCount.get()==1 && prepared.get()==1,"A decoded large IDR unnecessarily restarted its reference chain") }
    if prepareHook != .unchecked {
        let committedStreams = streamCommits.get()
        try require(committedStreams.count == 2 && streamVideos.get() == committedStreams,
                    "Configuration did not decode and commit one IDR for each media generation")
        try require(committedStreams[0].sessionID == committedStreams[1].sessionID
                    && committedStreams[1].transportEpoch > committedStreams[0].transportEpoch
                    && committedStreams[1].codecEpoch > committedStreams[0].codecEpoch,
                    "Configuration reused the first prepared stream identity")
        if prepareHook == .boundStream {
            try require(streamPreparations.get() == committedStreams && streamBindings.get() == committedStreams,
                        "Prepared, bound, decoded and committed stream identities diverged")
            try require(prepared.get() == 1, "Configuration hold bypassed default recovery or stream preparation ran twice")
        } else {
            try require(prepared.get() == 3 && streamPreparations.get().isEmpty && streamBindings.get().isEmpty,
                        "Absent optional stream hook changed default candidate/configuration recovery behavior")
        }
    }
    if inspectRoundTrip {
        let paths = reportPaths.get()
        let expected: MediaSession.Path = udp ? .udp : auxiliary ? .tcp : .shared
        try require(paths.first == .preparing && paths.last == .committed(expected, relayedUDP: false),
                    "Report did not distinguish preparation and the committed media path: \(paths)")
        if udp {
            try require(reportFragments.get().trial == 1 && reportFragments.get().committed == 1,
                        "Initial IDR and P-frame were not attributed to the trial and committed paths")
            hostSession.get()?.sendVideo(nextPacket(false))
            try wait(reportTailFrame, "Final UDP frame did not reach the viewer")
            let final = reportFragments.get()
            try require(final.trial == 1 && final.committed == 2 && final.lost == 0,
                        "Final UDP fragment was missing from the report at frame delivery")
            let measured = reportRoundTrips.get()
            try require(!measured.isEmpty && measured.allSatisfy { (0..<1_000).contains($0) },
                        "Report missed authenticated post-commit UDP pongs")
        } else {
            try require(reportRoundTrips.get().isEmpty && reportFragments.get().trial + reportFragments.get().committed == 0,
                        "TCP exposed UDP RTT or fragment counts")
        }
    }
    try require(errors.get().isEmpty,"Session reported errors: \(errors.get())")
}
@main struct MediaSessionChecks {
 static func main() {
  var passed=0,failed=0
  func run(_ name: String, _ body: () throws -> Void) {
   if let index = CommandLine.arguments.firstIndex(of:"--match"), index+1 < CommandLine.arguments.count,
      !name.contains(CommandLine.arguments[index+1]) { return }
   if CommandLine.arguments.contains("--recovery-only") && !name.contains("Recovery accounting") { return }
   if CommandLine.arguments.contains("--large-only") && !name.contains("512 KiB") { return }
   if CommandLine.arguments.contains("--prepare-only") && !name.contains("onPrepare") { return }
   if CommandLine.arguments.contains("--local-network-only") && !name.contains("Local-network") { return }
   do { try body();passed += 1;print("PASS",name) }
   catch { failed += 1;print("FAIL",name,error) }
  }
  run("Malformed media session factories reject before networking") {
    let key=try PairingKey.generate()
    let peer=Peer(connection:NWConnection(host:"127.0.0.1",port:1,using:SecureTransport.parameters(key:key)))
    defer { peer.close("test unused") }
    do { _=try MediaSession.host(control:peer,key:key,port:0,settings:StreamSettings()) }
    catch {
      do { _=try MediaSession.viewer(control:peer,key:key,host:"",port:1,settings:StreamSettings()) }
      catch { return }
      throw Failure(message:"Empty media destination was accepted")
    }
    throw Failure(message:"Zero media port was accepted")
  }
  run("Stopped media forwards late auxiliary traffic exactly once") {
    let key=try PairingKey.generate()
    for role in [MediaChannelRole.video, .bulk] {
        let parent: TrafficMeter, meter: TrafficMeter, initial: TrafficSnapshot
        do {
            // Never start these connections: live control/UDP completions would also change the parent
            // between snapshots, even after the media queue has stopped. Install the real relay instead.
            let control=Peer(connection:NWConnection(host:"127.0.0.1",port:1,using:SecureTransport.parameters(key:key)))
            let auxiliary=Peer(connection:NWConnection(host:"127.0.0.1",port:1,using:SecureTransport.parameters(key:key)))
            let session=try MediaSession.host(control:control,key:key,port:1,settings:StreamSettings())
            defer { session.stop();auxiliary.close("test done");control.close("test done") }
            parent=control.trafficMeter;meter=auxiliary.trafficMeter
            parent.record(sentBytes:100,receivedBytes:200)
            meter.record(sentBytes:5,receivedBytes:9)
            initial=meter.snapshot()
            session.acceptAuxiliary(auxiliary,role:role)
            try require(parent.snapshot().totals == TrafficTotals(sentBytes:105,receivedBytes:209),
                        "Existing auxiliary traffic was not relayed exactly once")
            let stopped=DispatchSemaphore(value:0)
            session.stop()
            session.suspendForConfiguration { stopped.signal() }
            try wait(stopped,"Stopped host media did not settle")
            auxiliary.queue.sync {}
        }
        meter.record(sentBytes:7,receivedBytes:11)
        let after=parent.snapshot().totals
        try require(after == TrafficTotals(sentBytes:112,receivedBytes:220),
                    "Late auxiliary completion was lost or double-counted in parent traffic: \(after)")
        guard let replay=meter.onUpdate else { throw Failure(message:"Stopped auxiliary meter lost its traffic relay") }
        replay(meter.snapshot())
        replay(initial)
        try require(parent.snapshot().totals == after,"Repeated or older auxiliary snapshots changed parent traffic")
        meter.record(sentBytes:13,receivedBytes:17)
        try require(parent.snapshot().totals == TrafficTotals(sentBytes:125,receivedBytes:237),
                    "Replaying an old snapshot changed the next late auxiliary delta")
    }
  }
  if !CommandLine.arguments.contains("--skip-network") {
   run("Local-network classification excludes loopback UDP and reports authenticated RTT") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,inspectRoundTrip:true) }
   run("Local-network classification excludes loopback TCP and counts a control RTT only in its own window") { try exercise(udp:false,auxiliary:true,rejectFirst:false,reconfigure:false,inspectRoundTrip:true) }
   run("Local-network classification excludes framed shared loopback TCP and samples fresh control RTT") { try exercise(udp:false,auxiliary:false,rejectFirst:false,reconfigure:false,inspectRoundTrip:true) }
   run("Optional onPrepareStream binds each exact generation before candidate video and commit") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true,prepareHook:.boundStream) }
   run("Absent onPrepareStream preserves default onPrepareRecovery for candidates and configuration hold") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true,prepareHook:.fallback) }
   run("Legacy peers keep configuration and pause recovery unchanged") { try exercise(udp:false,auxiliary:false,rejectFirst:false,reconfigure:false,legacy:true) }
   run("Recovery accounting keeps repeated legacy reconfiguration on UDP") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,recoveries:true) }
   run("Recovery accounting falls back after three negotiated playback delivery failures") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,recoveries:true,deliveryHints:true) }
   run("Recovery accounting counts repeated and stale hints only once per committed stream") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,recoveries:true,deliveryHints:true,duplicateHints:true) }
   run("Recovery accounting clears pre-configuration interruptions at the viewer's applied restart") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,recoveries:true,deliveryHints:true,recoveryConfiguration:.restart) }
   run("Recovery accounting preserves delivery failures across unchanged settings") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,recoveries:true,deliveryHints:true,recoveryConfiguration:.unchanged) }
   run("Recovery accounting preserves delivery failures across a live bitrate change") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,recoveries:true,deliveryHints:true,recoveryConfiguration:.bitrate) }
   run("Recovery accounting deduplicates an active stream while rejected candidates wait to retry") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,deliveryHints:true,retryHints:true) }
   run("Recovery accounting excludes old deadlines after a local scheduling stall") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,deliveryHints:true,schedulingStall:true) }
   run("UDP first choice, bulk binding and configuration cutover") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true) }
   run("TCP-only choice uses its independent media connection") { try exercise(udp:false,auxiliary:true,rejectFirst:false,reconfigure:false) }
   run("Independent TCP tolerates a 350 ms complete-frame decode without recovery") { try exercise(udp:false,auxiliary:true,rejectFirst:false,reconfigure:false,delayedDecode:true) }
   run("Shared TCP tolerates a 350 ms complete-frame decode without recovery") { try exercise(udp:false,auxiliary:false,rejectFirst:false,reconfigure:false,delayedDecode:true) }
   run("Reassembled UDP tolerates a 350 ms complete-frame decode without recovery") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,delayedDecode:true) }
   run("Stalled TCP decode still recovers once and fences its late callback") { try exercise(udp:false,auxiliary:true,rejectFirst:false,reconfigure:false,stalledDecode:true) }
   run("Auxiliary refusal falls back to framed shared TCP") { try exercise(udp:false,auxiliary:false,rejectFirst:false,reconfigure:false) }
   run("Transient capture readiness retries UDP") { try exercise(udp:true,auxiliary:true,rejectFirst:true,reconfigure:false) }
   run("Aborting after candidate IDR requires a fresh epoch and IDR") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true,failRecoveryCandidate:true) }
   run("Pause and resume preserve UDP and establish a fresh epoch") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,pauseResume:true) }
   run("Running UDP path failure commits TCP and returns after cooldown") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,pathFailure:true,restoreUDP:true) }
   run("Overlapping prepare preserves current transaction and future epochs") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true,overlapPrepare:true) }
   run("512 KiB IDR is paced, reassembled and committed byte-for-byte") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,inspectDiagnostics:true,largeIDR:true) }
   run("Observable diagnostics and authenticated compute samples") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,inspectDiagnostics:true) }
   run("A bitrate-only change keeps the UDP stream and reports host frame delivery") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,liveBitrate:true) }
   run("A bitrate-only change keeps the TCP stream and reports host frame delivery") { try exercise(udp:false,auxiliary:true,rejectFirst:false,reconfigure:false,liveBitrate:true) }
   run("Stopped candidates reject late decode completion") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,stopCandidate:true) }
   run("HEVC frames cross UDP fragments, a configuration cutover and the decode window") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true,hevc:true) }
   run("A 512 KiB HEVC IDR is paced, reassembled and committed byte-for-byte") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,largeIDR:true,hevc:true) }
   run("HEVC frames cross the independent TCP media connection") { try exercise(udp:false,auxiliary:true,rejectFirst:false,reconfigure:false,hevc:true) }
   run("HEVC frames cross framed shared TCP") { try exercise(udp:false,auxiliary:false,rejectFirst:false,reconfigure:false,hevc:true) }
   run("HEVC packets keep their codec on the legacy video message") { try exercise(udp:false,auxiliary:false,rejectFirst:false,reconfigure:false,legacy:true,hevc:true) }
  }
  print("Media session checks: \(passed) passed, \(failed) failed")
  if failed>0 {exit(1)}
 }
}
