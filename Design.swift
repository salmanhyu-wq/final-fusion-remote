import AppKit
import QuartzCore

enum Palette {
    /// Final Fusion violet, slightly brighter in dark mode.
    static let brand = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.42, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.40, green: 0.25, blue: 0.82, alpha: 1)
    }
    static let actionFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.38, green: 0.24, blue: 0.76, alpha: 1)
            : NSColor(srgbRed: 0.34, green: 0.22, blue: 0.73, alpha: 1)
    }
    // Colours taken from the round My Music Gacha patch.
    static let gachaDeep = NSColor(srgbRed: 0.09, green: 0.06, blue: 0.19, alpha: 1)
    static let gachaViolet = NSColor(srgbRed: 0.29, green: 0.18, blue: 0.56, alpha: 1)
    static let gachaLavender = NSColor(srgbRed: 0.80, green: 0.71, blue: 0.99, alpha: 1)
    static let gachaPink = NSColor(srgbRed: 0.94, green: 0.36, blue: 0.85, alpha: 1)
}

enum GachaArt {
    /// The round purple My Music Gacha logo patch (also the hangar floor patch in the space mission game).
    static let patch: NSImage? = Bundle.main.url(forResource: "MyMusicGacha", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))
}

/// A rounded, filled button with an optional SF Symbol.
final class ActionButton: NSButton {
    enum Style { case primary, secondary, quiet, danger }

    private var style: Style
    private var label = ""
    private var hovering = false
    private var pressing = false
    private var tracking: NSTrackingArea?

    init(_ style: Style = .secondary) {
        self.style = style
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        (cell as? NSButtonCell)?.highlightsBy = []
        wantsLayer = true
        layer?.cornerRadius = 8
        font = .systemFont(ofSize: 14, weight: .semibold)
        imagePosition = .imageLeading
        imageHugsTitle = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult
    func set(_ title: String, symbol: String? = nil, style: Style? = nil,
             target: AnyObject?, action: Selector) -> ActionButton {
        label = title
        if let style = style { self.style = style }
        if let symbol = symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
        refresh()
        return self
    }

    func setStyle(_ value: Style) {
        guard style != value else { return }
        style = value
        refresh()
    }

    override var isEnabled: Bool { didSet { if oldValue != isEnabled { refresh() } } }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: ceil(base.width) + (image == nil ? 30 : 34), height: 36)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        refresh()
        super.mouseDown(with: event)
        pressing = false
        refresh()
    }

    private func refresh() {
        let text: NSColor
        var fill: NSColor
        switch style {
        case .primary: text = .white; fill = Palette.actionFill
        case .secondary: text = .labelColor; fill = NSColor.labelColor.withAlphaComponent(0.08)
        case .quiet: text = .labelColor; fill = NSColor.labelColor.withAlphaComponent(0.025)
        case .danger: text = .systemRed; fill = NSColor.systemRed.withAlphaComponent(0.12)
        }
        var background: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if self.isEnabled && (self.pressing || self.hovering), let solid = fill.usingColorSpace(.sRGB) {
                let amount: CGFloat = self.pressing ? 0.22 : 0.10
                if self.style == .primary {
                    fill = solid.blended(withFraction: amount, of: self.pressing ? .black : .white) ?? solid
                } else {
                    fill = solid.withAlphaComponent(min(1, solid.alphaComponent * (self.pressing ? 2.4 : 1.6)))
                }
            }
            background = fill.cgColor
        }
        if isEnabled, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           hovering || pressing {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
            fade.duration = 0.14
            layer?.add(fade, forKey: "buttonTint")
        } else {
            layer?.removeAnimation(forKey: "buttonTint")
        }
        layer?.backgroundColor = background
        contentTintColor = text
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: label, attributes: [
            .foregroundColor: text, .font: font ?? .systemFont(ofSize: 14, weight: .semibold), .paragraphStyle: paragraph
        ])
        alphaValue = isEnabled ? 1 : 0.42
        invalidateIntrinsicContentSize()
    }
}

/// A visible activity cue, independent of the localized status message.
enum OperationActivity: Equatable {
    case idle, busy, progress(Double)
}

final class ActivityMark: NSStackView {
    private let spinner = NSProgressIndicator()
    private let still = NSImageView()
    private let bar = NSProgressIndicator()
    private var activity: OperationActivity = .idle
    private var motionObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
        still.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        still.contentTintColor = Palette.brand
        still.translatesAutoresizingMaskIntoConstraints = false
        still.widthAnchor.constraint(equalToConstant: 16).isActive = true
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 66).isActive = true
        [spinner, still, bar].forEach(addArrangedSubview)
        update()
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let observer = motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    func show(_ value: OperationActivity) {
        guard value != activity else { return }
        activity = value
        update()
    }

    private func update() {
        let animated = activity == .busy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let progress: Double?
        if case let .progress(value) = activity { progress = value } else { progress = nil }
        spinner.isHidden = !animated
        still.isHidden = activity != .busy || animated
        bar.isHidden = progress == nil
        if let progress = progress { bar.doubleValue = progress }
        isHidden = activity == .idle
        if animated, window != nil { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }
}

final class StatusLine: NSView {
    let label: NSTextField
    private let mark = ActivityMark()
    private var markWidth: NSLayoutConstraint!
    private var gap: NSLayoutConstraint!

    init(_ label: NSTextField) {
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .left
        addSubview(mark)
        addSubview(label)
        markWidth = mark.widthAnchor.constraint(equalToConstant: 0)
        gap = label.leadingAnchor.constraint(equalTo: mark.trailingAnchor)
        NSLayoutConstraint.activate([
            markWidth, gap,
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            mark.heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ value: OperationActivity) {
        switch value {
        case .idle: markWidth.constant = 0
        case .busy: markWidth.constant = 16
        case .progress: markWidth.constant = 66
        }
        gap.constant = value == .idle ? 0 : 9
        mark.show(value)
    }
}

/// A softly filled rounded group with an optional heading.
final class CardView: NSView {
    enum Tone { case section, panel, featured }
    let stack: NSStackView
    var tone: Tone { didSet { if tone != oldValue { needsDisplay = true } } }

    init(title: String? = nil, symbol: String? = nil, tone: Tone = .panel, _ views: [NSView]) {
        self.tone = tone
        var all: [NSView] = []
        if let title = title {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            heading.textColor = .labelColor
            if let symbol = symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let icon = NSImageView(image: image)
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                icon.contentTintColor = Palette.brand
                let row = NSStackView(views: [icon, heading])
                row.spacing = 6
                all.append(row)
            } else {
                all.append(heading)
            }
        }
        all += views
        stack = NSStackView(views: all)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
        for view in views where view is NSTextField || view is StatusLine {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill: NSColor
        let edge: NSColor
        switch tone {
        case .section: fill = .clear; edge = NSColor.labelColor.withAlphaComponent(0.095)
        case .panel: fill = NSColor.labelColor.withAlphaComponent(0.035); edge = NSColor.labelColor.withAlphaComponent(0.105)
        case .featured: fill = Palette.brand.withAlphaComponent(0.08); edge = Palette.brand.withAlphaComponent(0.37)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = edge.cgColor
    }
}

/// The clickable My Music Gacha promotion shown at the bottom of the settings window.
final class PromoBanner: NSView {
    static let address = URL(string: "https://mymusicgacha.com")!

    private let gradient = CAGradientLayer()
    private let shine = CALayer()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        gradient.colors = [Palette.gachaDeep.cgColor, Palette.gachaViolet.cgColor,
                           (Palette.gachaViolet.blended(withFraction: 0.35, of: Palette.gachaPink) ?? Palette.gachaViolet).cgColor]
        gradient.locations = [0.1, 0.62, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(gradient)
        shine.backgroundColor = NSColor.white.cgColor
        shine.opacity = 0
        layer?.addSublayer(shine)

        let title = NSTextField(labelWithAttributedString: {
            let text = NSMutableAttributedString(string: "MY MUSIC ", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 16, weight: .heavy), .kern: 0.8
            ])
            text.append(NSAttributedString(string: "GACHA", attributes: [
                .foregroundColor: Palette.gachaLavender, .font: NSFont.systemFont(ofSize: 16, weight: .heavy), .kern: 0.8
            ]))
            return text
        }())
        let tagline = NSTextField(wrappingLabelWithString: L("내 이야기를 노래로 · 두 가지 버전으로 받아 보세요",
                                                     "Turn your story into a song · get two versions"))
        tagline.font = .systemFont(ofSize: 13, weight: .medium)
        tagline.textColor = NSColor.white.withAlphaComponent(0.88)
        tagline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSStackView(views: [title, tagline])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 3

        let pill = NSTextField(labelWithString: L("노래 만들기  →", "Make a song  →"))
        pill.font = .systemFont(ofSize: 13, weight: .bold)
        pill.textColor = Palette.gachaDeep
        pill.alignment = .center
        let pillBox = NSView()
        pillBox.wantsLayer = true
        pillBox.layer?.backgroundColor = NSColor.white.cgColor
        pillBox.layer?.cornerRadius = 15
        pillBox.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pillBox.addSubview(pill)
        NSLayoutConstraint.activate([
            pillBox.heightAnchor.constraint(equalToConstant: 30),
            pill.centerYAnchor.constraint(equalTo: pillBox.centerYAnchor),
            pill.leadingAnchor.constraint(equalTo: pillBox.leadingAnchor, constant: 14),
            pill.trailingAnchor.constraint(equalTo: pillBox.trailingAnchor, constant: -14)
        ])
        pillBox.setContentCompressionResistancePriority(.required, for: .horizontal)

        var views: [NSView] = []
        if let patch = GachaArt.patch {
            let icon = NSImageView(image: patch)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
            views.append(icon)
        }
        views += [words, pillBox]
        let row = NSStackView(views: views)
        row.spacing = 12
        row.alignment = .centerY
        row.setCustomSpacing(16, after: words)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
        toolTip = "mymusicgacha.com"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("마이 뮤직 가챠 웹사이트 열기", "Open the My Music Gacha website"))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        shine.frame = bounds
        CATransaction.commit()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { shine.opacity = 0.08 }
    override func mouseExited(with event: NSEvent) { shine.opacity = 0 }
    override func mouseDown(with event: NSEvent) { shine.opacity = 0.16 }

    override func mouseUp(with event: NSEvent) {
        shine.opacity = 0.08
        if bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
    }

    override func accessibilityPerformPress() -> Bool { open(); return true }

    private func open() { NSWorkspace.shared.open(Self.address) }
}
