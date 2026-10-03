import AppKit
import SwiftUI

enum RotaryFaderMapping {
    static let angleRange = -135.0...135.0

    static func angle(for value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return angleRange.lowerBound }
        let progress = min(
            1,
            max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))
        )
        return angleRange.lowerBound
            + progress * (angleRange.upperBound - angleRange.lowerBound)
    }

    static func value(for angle: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = min(angleRange.upperBound, max(angleRange.lowerBound, angle))
        let progress =
            (clamped - angleRange.lowerBound)
            / (angleRange.upperBound - angleRange.lowerBound)
        return range.lowerBound + progress * (range.upperBound - range.lowerBound)
    }

    static func pointerAngle(at location: CGPoint, center: CGPoint) -> Double {
        let degrees = atan2(location.x - center.x, center.y - location.y) * 180 / .pi
        if degrees > angleRange.upperBound { return angleRange.upperBound }
        if degrees < angleRange.lowerBound { return angleRange.lowerBound }
        return degrees
    }
}

struct RotaryFader: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> RotaryFaderView {
        let view = RotaryFaderView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        view.onChange = { context.coordinator.value.wrappedValue = $0 }
        return view
    }

    func updateNSView(_ view: RotaryFaderView, context: Context) {
        context.coordinator.value = $value
        view.value = min(range.upperBound, max(range.lowerBound, value))
        view.valueRange = range
        view.defaultValue = defaultValue
        view.setAccessibilityLabel(accessibilityLabel)
        view.needsDisplay = true
    }

    final class Coordinator {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }
    }
}

final class RotaryFaderView: NSView {
    var value = 0.0
    var valueRange = 0.0...1.0
    var defaultValue = 0.0
    var onChange: ((Double) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityMinValue() -> Any? { valueRange.lowerBound }
    override func accessibilityMaxValue() -> Any? { valueRange.upperBound }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let insetBounds = bounds.insetBy(dx: 2, dy: 2)
        let face = NSBezierPath(ovalIn: insetBounds)
        NSGradient(
            starting: NSColor(calibratedWhite: 0.98, alpha: 1),
            ending: NSColor(calibratedWhite: 0.78, alpha: 1)
        )?.draw(in: face, angle: -90)
        NSColor(calibratedWhite: 0.52, alpha: 1).setStroke()
        face.lineWidth = 1
        face.stroke()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle = RotaryFaderMapping.angle(for: value, in: valueRange) * .pi / 180
        let radius = min(bounds.width, bounds.height) * 0.31
        let end = CGPoint(
            x: center.x + sin(angle) * radius,
            y: center.y + cos(angle) * radius
        )
        let pointer = NSBezierPath()
        pointer.move(to: center)
        pointer.line(to: end)
        NSColor(calibratedWhite: 0.22, alpha: 1).setStroke()
        pointer.lineWidth = 3
        pointer.lineCapStyle = .round
        pointer.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            setValue(defaultValue)
        } else {
            updateFromPointer(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateFromPointer(event)
    }

    override func scrollWheel(with event: NSEvent) {
        increment(by: -Double(event.scrollingDeltaY) * step / 4)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125:
            increment(by: -step)
        case 124, 126:
            increment(by: step)
        case 51:
            setValue(defaultValue)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        increment(by: step)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        increment(by: -step)
        return true
    }

    private var step: Double {
        max((valueRange.upperBound - valueRange.lowerBound) / 100, 0.001)
    }

    private func updateFromPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let angle = RotaryFaderMapping.pointerAngle(
            at: point,
            center: CGPoint(x: bounds.midX, y: bounds.midY)
        )
        setValue(RotaryFaderMapping.value(for: angle, in: valueRange))
    }

    private func increment(by amount: Double) {
        setValue(value + amount)
    }

    private func setValue(_ proposed: Double) {
        value = min(valueRange.upperBound, max(valueRange.lowerBound, proposed))
        onChange?(value)
        setAccessibilityValue(value)
        needsDisplay = true
    }
}
