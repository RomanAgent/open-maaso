import CoreGraphics
import Foundation

/// Hit tests the immutable BGRA8 image also assigned to the pet's CALayer.
/// Main-thread owned; provider bytes are retained lazily, at most once per frame.
final class MacOSAvatarAlphaHitTest {
  private static let minimumAlpha: UInt8 = 16
  private var image: CGImage?
  private var pixelData: CFData?
  private var didReadPixelData = false

  func replaceImage(_ nextImage: CGImage?) {
    image = nil
    pixelData = nil
    didReadPixelData = false
    guard let nextImage,
          nextImage.width > 0, nextImage.height > 0,
          nextImage.bitsPerComponent == 8, nextImage.bitsPerPixel == 32,
          nextImage.colorSpace?.model == .rgb,
          nextImage.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little,
          !nextImage.bitmapInfo.contains(.floatComponents),
          nextImage.alphaInfo == .premultipliedFirst
            || nextImage.alphaInfo == .first
    else { return }
    let (minimumStride, strideOverflow) = nextImage.width.multipliedReportingOverflow(by: 4)
    let (_, sizeOverflow) = nextImage.bytesPerRow.multipliedReportingOverflow(by: nextImage.height)
    guard !strideOverflow, !sizeOverflow,
          nextImage.bytesPerRow >= minimumStride
    else { return }
    image = nextImage
  }

  func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
    guard let image,
          point.x.isFinite, point.y.isFinite,
          bounds.origin.x.isFinite, bounds.origin.y.isFinite,
          bounds.width.isFinite, bounds.height.isFinite,
          bounds.width > 0, bounds.height > 0
    else { return false }
    // Match contentsGravity = .resizeAspect, including transparent letterboxing.
    let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    let content = CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
    guard scale.isFinite, scale > 0,
          content.minX.isFinite, content.minY.isFinite,
          point.x >= content.minX, point.x < content.maxX,
          point.y >= content.minY, point.y < content.maxY,
          let data = loadDataIfNeeded(for: image),
          let pixels = CFDataGetBytePtr(data)
    else { return false }

    let column = min(image.width - 1, Int((point.x - content.minX) / scale))
    // The avatar layer's Y = -1 transform places source row 0 at AppKit minY.
    let row = min(image.height - 1, Int((point.y - content.minY) / scale))
    return pixels[row * image.bytesPerRow + column * 4 + 3] >= Self.minimumAlpha
  }

  private func loadDataIfNeeded(for image: CGImage) -> CFData? {
    if !didReadPixelData {
      didReadPixelData = true
      if let data = image.dataProvider?.data,
         CFDataGetLength(data) >= image.bytesPerRow * image.height
      {
        pixelData = data
      }
    }
    return pixelData
  }
}
