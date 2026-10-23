import SwiftUI
import AppKit

/// The FrogeeSoft "R" tile; its rounded corners are part of the artwork.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Renvert")
    }

    static func menuImage(side: CGFloat = 16) -> NSImage {
        if let named = NSImage(named: "MenuBarMark") {
            let image = named.copy() as? NSImage ?? named
            image.isTemplate = true
            image.size = NSSize(width: side, height: side)
            return image
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let font = NSFont.systemFont(ofSize: side * 0.86, weight: .semibold)
        let text = "R" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let textSize = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: (side - textSize.width) / 2,
            y: (side - textSize.height) / 2 - 0.6
        )
        text.draw(at: origin, withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
