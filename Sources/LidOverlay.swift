import AppKit
import ImageIO
import QuartzCore
import ScreenCaptureKit

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MetalHostView: NSView {
    init(metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

final class LidOverlay {
    private var window: OverlayWindow?
    private var fadingWindow: OverlayWindow?
    private var hud: LidHUD?
    private var renderer: DepthRenderer?
    private var triedRenderer = false
    private var generation = 0
    private var screenSize = CGSize.zero
    private var startAngle = 110.0
    private var commitAngle = 40.0
    private var currentAngle = 110.0
    private var revealed = false
    private let geometry = DepthGeometry()
    private let tuning = DepthTuning()
    private let buildQueue = DispatchQueue(label: "Stillwake.picture", qos: .userInteractive)

    var hostWindow: NSWindow? { window }

    func warmUp() {
        guard !triedRenderer else { return }
        triedRenderer = true
        renderer = DepthRenderer()
    }

    func show(startAngle: Double, commitAngle: Double) {
        dismiss(animated: false)
        warmUp()
        guard let renderer, let screen = NSScreen.builtIn else {
            log.error("overlay unavailable, renderer \(self.renderer != nil, privacy: .public)")
            return
        }
        self.startAngle = startAngle
        self.commitAngle = commitAngle
        currentAngle = startAngle
        screenSize = screen.frame.size
        generation += 1
        let token = generation

        let container = NSView(frame: CGRect(origin: .zero, size: screenSize))
        let host = MetalHostView(metalLayer: renderer.makeLayer(), scale: screen.backingScaleFactor)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let hud = LidHUD()
        hud.place(in: screenSize)
        container.addSubview(hud)

        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        self.window = window
        self.hud = hud
        revealed = false

        let size = screenSize
        ScreenSnapshot.capture(screen) { [weak self] image in
            guard let self, token == self.generation else { return }
            let image = image ?? ScreenSnapshot.placeholder(pixels: CGSize(width: size.width * screen.backingScaleFactor, height: size.height * screen.backingScaleFactor))
            log.debug("overlay picture \(image.width, privacy: .public)x\(image.height, privacy: .public)")
            let pixelScale = size.width > 0 ? CGFloat(image.width) / size.width : screen.backingScaleFactor
            self.buildQueue.async {
                let picture = renderer.makePicture(image: image, screenSize: size, pixelScale: pixelScale)
                DispatchQueue.main.async {
                    guard token == self.generation, let picture else { return }
                    renderer.adopt(picture)
                    self.draw()
                    self.reveal()
                }
            }
        }
    }

    func update(angle: Double) {
        currentAngle = angle
        let travel = max(startAngle - angle, 0)
        hud?.setProgress(min(1, travel / max(1, startAngle - commitAngle)))
        draw()
    }

    func setCommitted() {
        hud?.setCommitted()
    }

    func dismiss(animated: Bool) {
        closeFadingWindow()
        generation += 1
        guard let window else { return }
        self.window = nil
        hud = nil
        renderer?.release()
        guard animated, revealed else {
            window.orderOut(nil)
            window.close()
            return
        }
        fadingWindow = window
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.fadingWindow === window { self?.fadingWindow = nil }
            window.orderOut(nil)
            window.close()
        })
    }

    private func draw() {
        guard window != nil, let renderer, renderer.isReady else { return }
        let travel = max(startAngle - currentAngle, 0)
        renderer.render(
            corners: geometry.corners(startAngle: startAngle, currentAngle: currentAngle, tuning: tuning, screenSize: screenSize),
            progress: travel / max(tuning.blurSpan, 1),
            tuning: tuning
        )
    }

    private func reveal() {
        guard let window, !revealed else { return }
        revealed = true
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.07
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func closeFadingWindow() {
        guard let fadingWindow else { return }
        self.fadingWindow = nil
        fadingWindow.orderOut(nil)
        fadingWindow.close()
    }
}

final class LidHUD: NSVisualEffectView {
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var committed = false
    private var canvas = CGSize.zero

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: 32, y: 26), radius: 16, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, ring] {
            shape.path = circle
            shape.fillColor = nil
            shape.lineWidth = 3
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        ring.strokeColor = NSColor.white.cgColor
        ring.strokeEnd = 0

        icon.frame = CGRect(x: 22, y: 16, width: 20, height: 20)
        icon.contentTintColor = .white
        icon.image = Self.symbol("laptopcomputer")
        addSubview(icon)

        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        setText("Keep holding fn and close the lid")
    }

    required init?(coder: NSCoder) {
        nil
    }

    func place(in size: CGSize) {
        canvas = size
        layout(animated: false)
    }

    func setProgress(_ progress: Double) {
        guard !committed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = progress
        CATransaction.commit()
    }

    func setCommitted() {
        guard !committed else { return }
        committed = true
        ring.strokeEnd = 1
        ring.strokeColor = NSColor.systemGreen.cgColor
        icon.image = Self.symbol("checkmark")
        icon.contentTintColor = .systemGreen
        setText("Staying on · you can let go of fn")
        layout(animated: true)
    }

    private func setText(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
    }

    private func layout(animated: Bool) {
        let width = 62 + label.frame.width + 24
        let frame = CGRect(x: (canvas.width - width) / 2, y: 64, width: width, height: 52)
        label.setFrameOrigin(CGPoint(x: 62, y: (52 - label.frame.height) / 2))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().frame = frame
            }
        } else {
            self.frame = frame
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
    }
}

enum ScreenSnapshot {
    static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccess() {
        CGRequestScreenCaptureAccess()
    }

    static func capture(_ screen: NSScreen, completion: @escaping (CGImage?) -> Void) {
        let scale = screen.backingScaleFactor
        let pixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        let displayID = canCaptureScreen ? screen.displayID : nil
        let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        Task.detached(priority: .userInitiated) {
            var captured: CGImage?
            if let displayID {
                captured = await live(displayID: displayID, pixels: pixels)
            }
            if captured == nil, let wallpaperURL {
                captured = wallpaper(at: wallpaperURL, pixels: pixels)
            }
            let image = captured
            await MainActor.run {
                completion(image)
            }
        }
    }

    private static func live(displayID: CGDirectDisplayID, pixels: CGSize) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let own = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixels.width)
            configuration.height = Int(pixels.height)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    static func placeholder(pixels: CGSize) -> CGImage {
        let width = max(Int(pixels.width), 1)
        let height = max(Int(pixels.height), 1)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let colors = [CGColor(red: 0.2, green: 0.24, blue: 0.48, alpha: 1), CGColor(red: 0.05, green: 0.06, blue: 0.14, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        return context.makeImage()!
    }

    private static func wallpaper(at url: URL, pixels: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(pixels.width, pixels.height)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
