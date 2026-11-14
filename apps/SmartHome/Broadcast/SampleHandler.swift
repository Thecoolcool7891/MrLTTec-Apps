import ReplayKit
import VideoToolbox
import Network

/// Screen broadcast extension: turns the iPhone screen into a live H.264 MPEG-TS stream at
/// http://<iPhone IP>:8799/screen.ts, which DLNA "Renderer" TVs can play. Video only.
class SampleHandler: RPBroadcastSampleHandler {
    private let q = DispatchQueue(label: "mrl.mirror")
    private var encoder: VTCompressionSession?
    private var scaler: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var outW = 0, outH = 0
    private var firstPTS: CMTime?
    private var lastFrame = CMTime.zero
    private var muxer = TSMuxer()
    private let server = StreamServer()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        server.start()
    }

    override func broadcastFinished() {
        server.stop()
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // About 30 frames a second is plenty for a TV.
        if lastFrame != .zero, CMTimeGetSeconds(CMTimeSubtract(pts, lastFrame)) < 1.0 / 31 { return }
        lastFrame = pts
        if firstPTS == nil { firstPTS = pts }
        guard server.hasClients else { return }   // nothing to do until the TV connects
        if encoder == nil { setup(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)) }
        guard let encoder, let scaled = scale(pb) else { return }
        let rel = CMTimeSubtract(pts, firstPTS ?? pts)
        let force = server.needsKeyframe
        let props: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: scaled, presentationTimeStamp: rel, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.q.async { self.emit(sample) }
        }
    }

    // MARK: Encoder

    private func setup(_ w: Int, _ h: Int) {
        // Keep the long side at 1280 so phones and TVs keep up; sizes must be even.
        let f = min(1.0, 1280.0 / Double(max(w, h)))
        outW = Int(Double(w) * f) & ~1
        outH = Int(Double(h) * f) & ~1
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                    kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &scaler)

        var s: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(outW), height: Int32(outH), codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard let s else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 3_500_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        encoder = s
    }

    private func scale(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool, let scaler else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let dst else { return nil }
        return VTPixelTransferSessionTransferImage(scaler, from: src, to: dst) == noErr ? dst : nil
    }

    // MARK: H.264 -> Annex-B -> MPEG-TS

    private func emit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
        var key = true
        if let att = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
           let notSync = att.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool { key = !notSync }

        let start: [UInt8] = [0, 0, 0, 1]
        var au: [UInt8] = start + [0x09, 0xF0]   // access unit delimiter
        if key {
            for idx in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: idx, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    au += start + Array(UnsafeBufferPointer(start: ptr, count: size))
                }
            }
        }
        var total = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &dataPtr) == noErr,
              let dataPtr else { return }
        let bytes = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
        var off = 0
        while off + 4 <= total {
            let len = Int(bytes[off]) << 24 | Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
            off += 4
            guard len > 0, off + len <= total else { break }
            au += start + Array(UnsafeBufferPointer(start: bytes + off, count: len))
            off += len
        }
        let t = CMSampleBufferGetPresentationTimeStamp(sample)
        let pts = UInt64(max(0, CMTimeGetSeconds(t)) * 90000) + 90000
        var packet: [UInt8] = []
        if key { packet = muxer.tables() }
        packet += muxer.video(au, pts: pts, key: key)
        server.broadcast(packet, keyframe: key)
    }
}

/// Serves the live stream to TVs. Each TV starts at a keyframe; a TV that falls far behind is dropped.
final class StreamServer {
    private let q = DispatchQueue(label: "mrl.mirror.server")
    private var listener: NWListener?
    private final class Client {
        let conn: NWConnection
        var started = false
        var inFlight = 0
        init(_ c: NWConnection) { conn = c }
    }
    private var clients: [ObjectIdentifier: Client] = [:]
    private var wantKey = false
    static let port: UInt16 = 8799

    var hasClients: Bool { q.sync { !clients.isEmpty } }
    var needsKeyframe: Bool { q.sync { let w = wantKey; wantKey = false; return w } }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: StreamServer.port)!) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: q)
        listener = l
    }

    func stop() {
        q.sync {
            listener?.cancel(); listener = nil
            for c in clients.values { c.conn.cancel() }
            clients = [:]
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data else { c.cancel(); return }
            let head = String(decoding: data, as: UTF8.self)
            let line = head.components(separatedBy: "\r\n").first ?? ""
            if line.contains("/status") {
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8),
                       completion: .contentProcessed { _ in c.cancel() })
                return
            }
            let hdr = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\nCache-Control: no-cache\r\n" +
                "transferMode.dlna.org: Streaming\r\n" +
                "contentFeatures.dlna.org: DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n\r\n"
            if line.hasPrefix("HEAD") {
                c.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in c.cancel() })
                return
            }
            c.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in })
            let client = Client(c)
            let id = ObjectIdentifier(client)
            self.clients[id] = client
            self.wantKey = true
            c.stateUpdateHandler = { [weak self] s in
                switch s { case .failed, .cancelled: self?.clients.removeValue(forKey: id); default: break }
            }
        }
    }

    func broadcast(_ bytes: [UInt8], keyframe: Bool) {
        q.async {
            let d = Data(bytes)
            for (id, cl) in self.clients {
                if !cl.started { if keyframe { cl.started = true } else { continue } }
                if cl.inFlight > 4_000_000 { cl.conn.cancel(); self.clients.removeValue(forKey: id); continue }
                cl.inFlight += d.count
                cl.conn.send(content: d, completion: .contentProcessed { [weak cl] e in
                    cl?.inFlight -= d.count
                    if e != nil { cl?.conn.cancel() }
                })
            }
        }
    }
}
