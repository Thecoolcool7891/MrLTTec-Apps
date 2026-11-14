import ReplayKit
import VideoToolbox
import CoreImage
import ImageIO
import Network

/// Screen broadcast extension. While broadcasting, the phone serves its screen on port 8799:
///   /screen.ts  live MPEG-TS (DLNA "Renderer" TVs like Hisense)
///   /live.m3u8  HLS live stream (Chromecast, AirPlay)
///   /mjpeg      motion JPEG (any web browser)
///   /           a web page that shows the screen
/// Video only. Work is only done for the kinds of viewers that are connected.
class SampleHandler: RPBroadcastSampleHandler {
    private let q = DispatchQueue(label: "mrl.mirror")
    private let jpegQ = DispatchQueue(label: "mrl.mirror.jpeg")
    private var encoder: VTCompressionSession?
    private var scaler: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var outW = 0, outH = 0
    private var firstPTS: CMTime?
    private var lastFrame = CMTime.zero
    private var lastJpeg = CMTime.zero
    private var jpegBusy = false
    private var muxer = TSMuxer()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let server = StreamServer()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) { server.start() }

    override func broadcastFinished() {
        server.stop()
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastFrame != .zero, CMTimeGetSeconds(CMTimeSubtract(pts, lastFrame)) < 1.0 / 31 { return }
        lastFrame = pts
        if firstPTS == nil { firstPTS = pts }
        let wants = server.wants
        guard wants.video || wants.jpeg else { return }
        if pool == nil { setup(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)) }
        guard let scaled = scale(pb) else { return }

        if wants.video, let encoder {
            let rel = CMTimeSubtract(pts, firstPTS ?? pts)
            let props: CFDictionary? = server.takeKeyframeRequest() ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(encoder, imageBuffer: scaled, presentationTimeStamp: rel, duration: .invalid,
                                            frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
                guard status == noErr, let sample, let self else { return }
                self.q.async { self.emit(sample) }
            }
        }

        // Browsers: about 12 JPEG frames a second, skipped while the last one is still being made.
        if wants.jpeg, !jpegBusy, lastJpeg == .zero || CMTimeGetSeconds(CMTimeSubtract(pts, lastJpeg)) >= 1.0 / 12 {
            lastJpeg = pts
            jpegBusy = true
            jpegQ.async { [weak self] in
                guard let self else { return }
                let img = CIImage(cvPixelBuffer: scaled)
                if let cs = CGColorSpace(name: CGColorSpace.sRGB),
                   let jpg = self.ci.jpegRepresentation(of: img, colorSpace: cs, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) {
                    self.server.sendJpeg(jpg)
                }
                self.jpegBusy = false
            }
        }
    }

    // MARK: Encoder

    private func setup(_ w: Int, _ h: Int) {
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
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
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
        var au: [UInt8] = start + [0x09, 0xF0]
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
        let seconds = max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        let pts = UInt64(seconds * 90000) + 90000
        var packet: [UInt8] = []
        if key { packet = muxer.tables() }
        packet += muxer.video(au, pts: pts, key: key)
        server.sendVideo(packet, keyframe: key, seconds: seconds)
    }
}

/// Serves the live streams. TS viewers start at a keyframe; HLS keeps the last few 1-second segments;
/// browser viewers get the newest JPEG. Slow viewers are dropped instead of using up memory.
final class StreamServer {
    static let port: UInt16 = 8799
    private let q = DispatchQueue(label: "mrl.mirror.server")
    private var listener: NWListener?

    private final class Viewer {
        let conn: NWConnection
        var started = false
        var inFlight = 0
        let jpeg: Bool
        init(_ c: NWConnection, jpeg: Bool) { conn = c; self.jpeg = jpeg }
    }
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var wantKey = false

    // HLS
    private struct Segment { let seq: Int; let data: Data; let duration: Double }
    private var segments: [Segment] = []
    private var current = Data()
    private var currentStart = -1.0
    private var nextSeq = 0
    private var lastHlsRequest = Date.distantPast

    var wants: (video: Bool, jpeg: Bool) {
        q.sync {
            let hls = Date().timeIntervalSince(lastHlsRequest) < 15
            return (viewers.values.contains { !$0.jpeg } || hls, viewers.values.contains { $0.jpeg })
        }
    }

    func takeKeyframeRequest() -> Bool { q.sync { let w = wantKey; wantKey = false; return w } }

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
            for v in viewers.values { v.conn.cancel() }
            viewers = [:]; segments = []; current = Data()
        }
    }

    private func reply(_ c: NWConnection, _ status: String, _ type: String, _ body: Data) {
        let h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data else { c.cancel(); return }
            let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let head = line.hasPrefix("HEAD")

            if path.hasPrefix("/status") { self.reply(c, "200 OK", "text/plain", Data("ok".utf8)); return }
            if path == "/" || path.hasPrefix("/index") { self.reply(c, "200 OK", "text/html; charset=utf-8", Data(StreamServer.page.utf8)); return }
            if path.hasPrefix("/live.m3u8") {
                self.lastHlsRequest = Date()
                if self.segments.isEmpty { self.wantKey = true }
                self.reply(c, "200 OK", "application/vnd.apple.mpegurl", Data(self.playlist().utf8)); return
            }
            if path.hasPrefix("/seg/"), let n = Int(path.dropFirst(5).split(separator: ".").first ?? "") {
                self.lastHlsRequest = Date()
                if let s = self.segments.first(where: { $0.seq == n }) { self.reply(c, "200 OK", "video/mp2t", s.data) }
                else { self.reply(c, "404 Not Found", "text/plain", Data()) }
                return
            }
            let jpeg = path.hasPrefix("/mjpeg")
            let hdr: String
            if jpeg {
                hdr = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            } else {
                hdr = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\nCache-Control: no-cache\r\n" +
                    "transferMode.dlna.org: Streaming\r\n" +
                    "contentFeatures.dlna.org: DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n\r\n"
            }
            if head { c.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in c.cancel() }); return }
            c.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in })
            let v = Viewer(c, jpeg: jpeg)
            let id = ObjectIdentifier(v)
            self.viewers[id] = v
            if !jpeg { self.wantKey = true }
            c.stateUpdateHandler = { [weak self] s in
                switch s { case .failed, .cancelled: self?.viewers.removeValue(forKey: id); default: break }
            }
        }
    }

    private func push(_ v: Viewer, _ id: ObjectIdentifier, _ d: Data) {
        if v.inFlight > 4_000_000 { v.conn.cancel(); viewers.removeValue(forKey: id); return }
        v.inFlight += d.count
        v.conn.send(content: d, completion: .contentProcessed { [weak v] e in
            v?.inFlight -= d.count
            if e != nil { v?.conn.cancel() }
        })
    }

    func sendVideo(_ bytes: [UInt8], keyframe: Bool, seconds: Double) {
        q.async {
            let d = Data(bytes)
            for (id, v) in self.viewers where !v.jpeg {
                if !v.started { if keyframe { v.started = true } else { continue } }
                self.push(v, id, d)
            }
            // HLS: cut a new segment at a keyframe once the current one is a second long.
            if Date().timeIntervalSince(self.lastHlsRequest) < 15 {
                if keyframe && self.currentStart >= 0 && seconds - self.currentStart >= 0.9 {
                    self.segments.append(Segment(seq: self.nextSeq, data: self.current, duration: seconds - self.currentStart))
                    self.nextSeq += 1
                    if self.segments.count > 6 { self.segments.removeFirst(self.segments.count - 6) }
                    self.current = Data(); self.currentStart = -1
                }
                if self.currentStart < 0 { if keyframe { self.currentStart = seconds } else { return } }
                self.current += d
            }
        }
    }

    func sendJpeg(_ jpg: Data) {
        q.async {
            let part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpg.count)\r\n\r\n".utf8) + jpg + Data("\r\n".utf8)
            for (id, v) in self.viewers where v.jpeg {
                if v.inFlight > 1_500_000 { continue }   // skip a frame for slow browsers
                self.push(v, id, part)
            }
        }
    }

    private func playlist() -> String {
        let segs = segments.suffix(4)
        let target = Int((segs.map { $0.duration }.max() ?? 1).rounded(.up))
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(max(1, target))\n#EXT-X-MEDIA-SEQUENCE:\(segs.first?.seq ?? 0)\n"
        for g in segs { s += String(format: "#EXTINF:%.3f,\n", g.duration) + "seg/\(g.seq).ts\n" }
        return s
    }

    static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>iPhone screen</title>
    <style>html,body{margin:0;height:100%;background:#000;color:#bbb;font-family:-apple-system,system-ui,sans-serif}
    #wrap{display:flex;align-items:center;justify-content:center;height:100%}img{max-width:100%;max-height:100%;object-fit:contain}
    #msg{position:fixed;bottom:12px;width:100%;text-align:center;font-size:13px;opacity:.7}</style></head>
    <body><div id="wrap"><img id="s" src="/mjpeg" alt="iPhone screen"></div><div id="msg">MrLTTec Home · live iPhone screen</div>
    <script>
    const s=document.getElementById('s');
    s.onerror=()=>{document.getElementById('msg').textContent='Waiting for the iPhone… (is the broadcast still on?)';setTimeout(()=>{s.src='/mjpeg?'+Date.now()},2000)};
    document.body.ondblclick=()=>{document.documentElement.requestFullscreen&&document.documentElement.requestFullscreen()};
    </script></body></html>
    """
}
