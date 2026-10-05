import Foundation
import CoreGraphics

/// Only arms a native drop receiver. File validation belongs to the native drag callback.
public struct PointerIntent {
    private var origin: CGPoint?
    private var dragged = false
    private var suppressed = false
    private var hoverStart: TimeInterval?

    public init() {}

    /// CGRect.contains excludes the upper edge, where a mouse pushed to the top can sit.
    public static func containsTopEdge(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    public mutating func drag(buttonDown: Bool, point: CGPoint) -> Bool {
        guard buttonDown else {
            origin = nil
            dragged = false
            suppressed = false
            return false
        }
        guard !suppressed else { return false }
        guard let origin else { self.origin = point; return false }
        if hypot(point.x - origin.x, point.y - origin.y) >= 6 { dragged = true }
        return dragged
    }

    public mutating func consume() {
        suppressed = true
        dragged = false
        hoverStart = nil
    }

    public mutating func hover(inside: Bool, buttonsDown: Bool, now: TimeInterval) -> Bool {
        guard inside && !buttonsDown else { hoverStart = nil; return false }
        guard let hoverStart else { self.hoverStart = now; return false }
        return now - hoverStart >= 0.35
    }
}
