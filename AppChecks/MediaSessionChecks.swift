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
func packet(_ seq: UInt32, idr: Bool, largeIDR: Bool = false) -> VideoPacket {
    var avcc=Data([0,0,0,4,idr ? 0x65 : 0x41,1,2,3])
    if idr && largeIDR {
        let nal=Data([0x65])+Data(repeating:0x7D,count:512*1024-1)
        avcc=Data();avcc.put(UInt32(nal.count));avcc.append(nal)
    }
    return VideoPacket(sequence:seq,sps:idr ? Data([0x67,0x42,0x00,0x1f]):Data(),pps:idr ? Data([0x68,0xce,0x06]):Data(),
        avcc:avcc)
}
enum PrepareHookCheck { case unchecked, boundStream, fallback }
func exercise(udp: Bool, auxiliary: Bool, rejectFirst: Bool, reconfigure: Bool,
              failRecoveryCandidate: Bool = false, pauseResume: Bool = false, stopCandidate: Bool = false, pathFailure: Bool = false, legacy: Bool = false, restoreUDP: Bool = false, inspectDiagnostics: Bool = false, largeIDR: Bool = false, overlapPrepare: Bool = false, prepareHook: PrepareHookCheck = .unchecked,
              delayedDecode: Bool = false, stalledDecode: Bool = false) throws {
    let key = try PairingKey.generate(), settings = StreamSettings(longestEdge:1920,framesPerSecond:60,megabits:12)
    let queue = DispatchQueue(label:"session.loopback-listener")
    let params = try MediaSecureTransport.tlsParameters(key:key,roles:MediaChannelRole.allCases)
    params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
    let listener = try NWListener(using:params)
    let listenReady = DispatchSemaphore(value:0), committed = DispatchSemaphore(value:0), dataDone = DispatchSemaphore(value:0), pathStable = DispatchSemaphore(value:0)
    let hostSession = Box<MediaSession?>(nil), viewerSession = Box<MediaSession?>(nil), peers = Box<[Peer]>([])
    let states=Box<[String]>([]), errors=Box<[String]>([]), decoded=Box<[UInt64]>([]), sequence=Box<UInt32>(0), prepared=Box(0), committedCount=Box(0)
    let rejectedCandidate = Box(false), candidateSeen = DispatchSemaphore(value:0)
    let lateDecode = Box<((Bool)->Void)?>(nil)
    let delayedFrameDone = DispatchSemaphore(value: 0), stalledFrameSeen = DispatchSemaphore(value: 0)
    let auxiliaryMeters = Box<[TrafficMeter]>([])
    let diagnostics = inspectDiagnostics ? PerformanceDiagnostics(enabled:true) : nil
    let sampledCompute = DispatchSemaphore(value:0)
    let reductions=Box<[MediaBottleneck]>([])
    let overlapSent=Box(false)
    let cursorID = UUID()
    let streamPreparations = Box<[MediaStreamID]>([]), streamBindings = Box<[MediaStreamID]>([])
    let streamVideos = Box<[MediaStreamID]>([]), streamCommits = Box<[MediaStreamID]>([])
    func nextPacket(_ idr: Bool) -> VideoPacket { sequence.update{$0 += 1}; return packet(sequence.get(),idr:idr,largeIDR:largeIDR) }
    listener.newConnectionHandler = { connection in
        let peer = Peer(connection:connection); peers.update{$0.append(peer)}
        peer.onClose={ reason in if !reason.contains("test") { errors.update{$0.append(reason)} } }
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            if let role=MediaSecureTransport.negotiatedRole(on:connection),role != .control {
                auxiliaryMeters.update { $0.append(peer.trafficMeter) }
                if auxiliary { hostSession.get()?.acceptAuxiliary(peer,role:role) } else { peer.close("test rejected auxiliary") }
                peers.update { $0.removeAll { $0 === peer } }
                return
            }
            do {
                let session = try MediaSession.host(control:peer,key:key,port:listener.port!.rawValue,settings:settings)
                hostSession.update{$0=session}
                session.diagnostics=diagnostics
                session.onPrepareRecovery={ complete in
                    prepared.update{$0 += 1}
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
                session.onResumeFrames={ [weak session] in session?.sendVideo(nextPacket(false)) }
                session.onState={ state in print("HOST",state) }
                session.onAcknowledged={ seq in print("ACK",seq) }
                session.onReliableData={ _ in dataDone.signal() }
                peer.onMessageHandled={ message,resume in _=session.receive(message);resume() }
                session.start()
                if legacy { session.sendVideo(nextPacket(true)) }
            } catch { errors.update{$0.append("host init \(error)")} }
        }
        peer.start()
    }
    listener.stateUpdateHandler={ if case .ready=$0 { listenReady.signal() } }
    listener.start(queue:queue)
    try wait(listenReady,"listener ready")
    let connection=NWConnection(host:"127.0.0.1",port:listener.port!,using:try MediaSecureTransport.tlsParameters(key:key,roles:[.control]))
    let client=Peer(connection:connection)
    client.onClose={ reason in errors.update{$0.append("control \(reason)")} }
    client.onReady={
        if legacy {
            client.onMessageHandled={ message,resume in
                if message.kind == .video {
                    do { let old=try VideoPacket.decode(message.payload);decoded.update{$0.append(UInt64(old.sequence))};committed.signal() }
                    catch { errors.update{$0.append("legacy frame invalid")} }
                }
                resume()
            }
            return
        }
        do {
            let session=try MediaSession.viewer(control:client,key:key,host:"127.0.0.1",port:listener.port!.rawValue,settings:settings,udpEnabled:udp)
            viewerSession.update{$0=session}
            session.diagnostics=diagnostics
            session.onReduceLoad={ cause in reductions.update{$0.append(cause)} }
            session.onSample={ sample in if (sample.encodeMilliseconds ?? 0)>=45 && (sample.decodeMilliseconds ?? 0)>=2 { sampledCompute.signal() } }
            session.onVideo={ frame,complete in
                decoded.update{$0.append(frame.header.frameID)}
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
                if largeIDR, frame.header.isIDR, frame.packet.avcc != packet(frame.packet.sequence,idr:true,largeIDR:true).avcc {
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
                if message.kind == .cursorControl, prepareHook != .unchecked {
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
    try require(!decoded.get().isEmpty,"No decoded media frame")
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
        if restoreUDP {
            let fallbackTime=SessionClock.now
            try wait(committed,"Healthy UDP did not recover after cooldown",seconds:37)
            try wait(pathStable,"Recovered UDP state was not published")
            try require(states.get().last=="UDP 视频","Recovered path was not UDP")
            try require(SessionClock.now-fallbackTime>=29,"UDP recovery ignored its cooldown")
        }
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
    try require(errors.get().isEmpty,"Session reported errors: \(errors.get())")
    if auxiliary, let meter=auxiliaryMeters.get().first, let parent=peers.get().first?.trafficMeter {
        let stopped=DispatchSemaphore(value:0)
        hostSession.get()?.stop()
        hostSession.get()?.suspendForConfiguration { stopped.signal() }
        try wait(stopped,"Stopped host media did not settle")
        let before=parent.snapshot().totals
        meter.record(sentBytes:7,receivedBytes:11)
        let after=parent.snapshot().totals
        try require(after.sentBytes-before.sentBytes==7 && after.receivedBytes-before.receivedBytes==11,"Late auxiliary completion was lost or double-counted in parent traffic")
    }
}
@main struct MediaSessionChecks {
 static func main() {
  var passed=0,failed=0
  func run(_ name: String, _ body: () throws -> Void) {
   if CommandLine.arguments.contains("--large-only") && !name.contains("512 KiB") { return }
   if CommandLine.arguments.contains("--prepare-only") && !name.contains("onPrepare") { return }
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
  if !CommandLine.arguments.contains("--skip-network") {
   run("Optional onPrepareStream binds each exact generation before candidate video and commit") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true,prepareHook:.boundStream) }
   run("Absent onPrepareStream preserves default onPrepareRecovery for candidates and configuration hold") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:true,prepareHook:.fallback) }
   run("Legacy peers keep configuration and pause recovery unchanged") { try exercise(udp:false,auxiliary:false,rejectFirst:false,reconfigure:false,legacy:true) }
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
   run("Stopped candidates reject late decode completion") { try exercise(udp:true,auxiliary:true,rejectFirst:false,reconfigure:false,stopCandidate:true) }
  }
  print("Media session checks: \(passed) passed, \(failed) failed")
  if failed>0 {exit(1)}
 }
}
