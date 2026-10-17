import MediaPlayer
import UIKit

/// Lock-screen artwork: a soft clay circle on warm linen.
/// Built outside the main actor because MediaPlayer may request it on any thread.
enum NowPlayingArtwork {
    static let shared: MPMediaItemArtwork = {
        let image = render(size: CGSize(width: 600, height: 600))
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    static func render(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            // Background: vertical linen gradient.
            let top = UIColor(hex: 0xF5EFE6).cgColor
            let bottom = UIColor(hex: 0xE9DCCB).cgColor
            if let bg = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }

            // Soft halo and core.
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let halo = [UIColor(hex: 0xE9D5C3).cgColor, UIColor(hex: 0xE9D5C3, alpha: 0).cgColor]
            if let haloGradient = CGGradient(colorsSpace: colorSpace, colors: halo as CFArray, locations: [0, 1]) {
                cg.drawRadialGradient(haloGradient, startCenter: center, startRadius: size.width * 0.18,
                                      endCenter: center, endRadius: size.width * 0.46, options: [])
            }
            let core = [UIColor(hex: 0xC98E6D).cgColor, UIColor(hex: 0xB5795A).cgColor]
            if let coreGradient = CGGradient(colorsSpace: colorSpace, colors: core as CFArray, locations: [0, 1]) {
                cg.saveGState()
                let radius = size.width * 0.2
                cg.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                cg.clip()
                cg.drawLinearGradient(coreGradient, start: CGPoint(x: center.x, y: center.y - radius),
                                      end: CGPoint(x: center.x, y: center.y + radius), options: [])
                cg.restoreGState()
            }
        }
    }
}
