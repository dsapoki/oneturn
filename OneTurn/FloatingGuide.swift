import UIKit
import AVKit
import AVFoundation
import CoreLocation
import CoreMedia

/// The drive as the web page hands it over when you press Start (and again after every new route).
/// Kept here so the next turn can still be followed while the page is paused in the background.
struct GuideRoute {
    struct Step { let i: Int; let type: Int; let exit: Int; let text: String }
    let lat: [Double], lon: [Double], cum: [Double], t: [Double]
    let steps: [Step]
    let ci: Int                 // index of the charging stop on the route, -1 if none
    var extra: Double           // seconds of charging + stopping still to come (0 when no stop)
    var arr: Int                // charge on arrival, %, as the page last worked it out

    init?(_ body: [String: Any]) {
        guard let coords = body["coords"] as? [[Double]], let cum = body["cum"] as? [Double],
              let t = body["t"] as? [Double], coords.count >= 2, cum.count == coords.count, t.count == coords.count else { return nil }
        lon = coords.map { $0[0] }
        lat = coords.map { $0[1] }
        self.cum = cum
        self.t = t
        steps = (body["steps"] as? [[String: Any]] ?? []).compactMap { s in
            guard let i = s["i"] as? Int else { return nil }
            return Step(i: min(max(i, 0), coords.count - 1), type: s["type"] as? Int ?? 6, exit: s["exit"] as? Int ?? 0, text: s["text"] as? String ?? "")
        }
        ci = body["ci"] as? Int ?? -1
        extra = body["extra"] as? Double ?? 0
        arr = body["arr"] as? Int ?? -1
    }
}

/// What the floating window shows at a moment.
struct GuideState {
    var toTurn: Double = 0, type = 6, exit = 0, text = "", eta = Date(), arr = -1, off = false, arrived = false
}

/// Follows the car along the route (closest point on the line) and works out the next turn and the arrival time.
final class GuideTracker {
    private(set) var route: GuideRoute
    private var last = 0

    init(_ route: GuideRoute) { self.route = route }

    func update(extra: Double?, arr: Int?) {
        if let e = extra { route.extra = e }
        if let a = arr { route.arr = a }
    }

    func state(at loc: CLLocation) -> GuideState {
        let r = route, n = r.lat.count
        let la = loc.coordinate.latitude, lo = loc.coordinate.longitude
        let kx = cos(la * .pi / 180) * 111_320.0, ky = 110_540.0
        func nearest(_ from: Int, _ to: Int) -> (k: Int, f: Double, d: Double) {
            var best = (k: from, f: 0.0, d: Double.greatestFiniteMagnitude)
            guard from <= to else { return best }
            for k in from...to {
                let ax = (r.lon[k] - lo) * kx, ay = (r.lat[k] - la) * ky
                let bx = (r.lon[k + 1] - lo) * kx, by = (r.lat[k + 1] - la) * ky
                let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
                let f = len2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / len2)) : 0
                let px = ax + dx * f, py = ay + dy * f, d = (px * px + py * py).squareRoot()
                if d < best.d { best = (k, f, d) }
            }
            return best
        }
        // a charging stop not reached yet: only the way there counts (the way back is often the same road)
        let lastSeg = r.ci >= 1 ? min(n - 2, r.ci - 1) : n - 2
        var hit = nearest(max(0, min(lastSeg, last - 30)), min(lastSeg, last + 800))   // near where we were: fast, never jumps far along the line
        if hit.d > 150 { hit = nearest(0, lastSeg) }
        last = hit.k
        let along = r.cum[hit.k] + (r.cum[hit.k + 1] - r.cum[hit.k]) * hit.f
        let tNow = r.t[hit.k] + (r.t[hit.k + 1] - r.t[hit.k]) * hit.f
        var s = GuideState()
        s.off = hit.d > 80
        s.arr = r.arr
        let stopAhead = r.ci >= 0 && along < r.cum[r.ci]
        s.eta = Date().addingTimeInterval(max(0, r.t[n - 1] - tNow) + (stopAhead ? r.extra : 0))
        if let next = r.steps.first(where: { r.cum[$0.i] > along + 3 }) {
            s.toTurn = r.cum[next.i] - along; s.type = next.type; s.exit = next.exit; s.text = next.text
        } else {
            s.toTurn = max(0, r.cum[n - 1] - along); s.type = 10; s.text = "Arrive"
        }
        s.arrived = r.cum[n - 1] - along < 30
        return s
    }
}

/// Draws the guidance card that appears in the floating window.
enum GuideCard {
    static let size = CGSize(width: 320, height: 180)

    static func image(_ s: GuideState) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let green = UIColor(red: 11 / 255, green: 128 / 255, blue: 67 / 255, alpha: 1)
            let grey = UIColor(red: 68 / 255, green: 68 / 255, blue: 65 / 255, alpha: 1)
            (s.off ? grey : green).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // turn arrow (or roundabout with its exit number)
            let iconBox = CGRect(x: 14, y: 18, width: 76, height: 76)
            if s.type == 7 || s.type == 8 {
                let ring = UIBezierPath(ovalIn: iconBox.insetBy(dx: 10, dy: 10))
                ring.lineWidth = 7
                UIColor.white.setStroke()
                ring.stroke()
                if s.exit > 0 { draw("\(s.exit)", in: iconBox.insetBy(dx: 0, dy: 20), size: 28, weight: .bold, align: .center) }
            } else if let icon = symbol(for: s.type) {
                let k = min(iconBox.width / icon.size.width, iconBox.height / icon.size.height)
                let w = icon.size.width * k, h = icon.size.height * k
                icon.draw(in: CGRect(x: iconBox.midX - w / 2, y: iconBox.midY - h / 2, width: w, height: h))
            }

            if s.off {
                draw("Off route", in: CGRect(x: 102, y: 22, width: 206, height: 44), size: 34, weight: .bold)
                draw("Open OneTurn for a new route", in: CGRect(x: 102, y: 68, width: 206, height: 48), size: 17, weight: .regular, lines: 2)
            } else {
                draw(s.arrived ? "Arrived" : distance(s.toTurn), in: CGRect(x: 102, y: 18, width: 206, height: 50), size: 40, weight: .bold)
                draw(s.text, in: CGRect(x: 102, y: 68, width: 206, height: 50), size: 17, weight: .regular, lines: 2)
            }

            // bottom line: arrival time and charge on arrival
            UIColor(white: 0, alpha: 0.18).setFill()
            ctx.fill(CGRect(x: 0, y: 130, width: size.width, height: 50))
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            draw("Arrive " + clock.string(from: s.eta), in: CGRect(x: 16, y: 140, width: 190, height: 30), size: 22, weight: .semibold)
            if s.arr >= 0 {
                let c: UIColor = s.arr > 20 ? UIColor(red: 0.75, green: 0.95, blue: 0.6, alpha: 1)
                    : s.arr > 0 ? UIColor(red: 1, green: 0.8, blue: 0.35, alpha: 1) : UIColor(red: 1, green: 0.6, blue: 0.6, alpha: 1)
                draw("\(s.arr) %", in: CGRect(x: 200, y: 140, width: 104, height: 30), size: 22, weight: .bold, align: .right, color: c)
            }
        }
    }

    private static func symbol(for type: Int) -> UIImage? {
        let name: String
        switch type {
        case 0, 2: name = "arrow.turn.up.left"
        case 1, 3: name = "arrow.turn.up.right"
        case 4, 12: name = "arrow.up.left"
        case 5, 13: name = "arrow.up.right"
        case 9: name = "arrow.uturn.left"
        case 10: name = "flag.checkered"
        default: name = "arrow.up"
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: 64, weight: .bold)
        let img = UIImage(systemName: name, withConfiguration: cfg) ?? UIImage(systemName: "arrow.up", withConfiguration: cfg)
        return img?.withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    private static func distance(_ m: Double) -> String {
        if m < 950 { return "\(Int((m / 10).rounded()) * 10) m" }
        if m < 9950 { return String(format: "%.1f km", m / 1000) }
        return "\(Int((m / 1000).rounded())) km"
    }

    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, weight: UIFont.Weight,
                             align: NSTextAlignment = .left, lines: Int = 1, color: UIColor = .white) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs, context: nil)
    }
}

/// Shows the guidance card in iOS's floating window (picture in picture) when you leave the app during a drive.
/// The card is sent as video frames to a tiny layer in the app, which iOS lifts into the floating window.
final class FloatingGuide: NSObject {
    private final class SampleView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    private let sampleView = SampleView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    private var pip: AVPictureInPictureController?
    private(set) var active = false

    func attach(to parent: UIView) {
        sampleView.isUserInteractionEnabled = false
        sampleView.displayLayer.videoGravity = .resizeAspect
        parent.addSubview(sampleView)
    }

    /// Driving: let the card float when you leave the app.
    func start(_ first: GuideState) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if pip == nil {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: sampleView.displayLayer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.requiresLinearPlayback = true
            pip = controller
        }
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        active = true
        show(first)
    }

    /// Drive ended: no more floating window.
    func stop() {
        active = false
        pip?.canStartPictureInPictureAutomaticallyFromInline = false
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        sampleView.displayLayer.flushAndRemoveImage()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Back in the app: the floating window closes (the full map is on screen again).
    func appBecameActive() {
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
    }

    func show(_ state: GuideState) {
        guard active, let cg = GuideCard.image(state).cgImage, let buffer = Self.sampleBuffer(cg) else { return }
        let layer = sampleView.displayLayer
        if layer.status == .failed { layer.flush() }
        layer.enqueue(buffer)
    }

    private static func sampleBuffer(_ image: CGImage) -> CMSampleBuffer? {
        let w = image.width, h = image.height
        var pixel: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pixel) == kCVReturnSuccess,
              let pb = pixel else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pb, [])

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
              let fmt = format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sb = sample else { return nil }
        if let list = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(list) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

extension FloatingGuide: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)   // "full screen" in the floating window: iOS opens OneTurn again
    }
}

extension FloatingGuide: AVPictureInPictureSampleBufferPlaybackDelegate {
    // A live picture, not a video: always "playing", no time line, no skipping.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) { completionHandler() }
}
