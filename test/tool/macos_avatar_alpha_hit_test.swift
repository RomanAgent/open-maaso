import CoreGraphics
import CoreImage
import Foundation
import QuartzCore

@main
enum AlphaHitTestBoundaryTests {
  static func main() {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bgra = CGBitmapInfo.byteOrder32Little.rawValue
      | CGImageAlphaInfo.premultipliedFirst.rawValue
    var assertions = 0
    func check(_ result: Bool, _ label: String) {
      assertions += 1
      guard result else {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
      }
    }
    func makeImage(
      _ alpha: [UInt8], width: Int = 2, height: Int = 2,
      stride: Int = 12, bitmapInfo: UInt32? = nil
    ) -> CGImage {
      // Nonzero row padding catches width*4 addressing instead of bytesPerRow.
      var pixels = [UInt8](repeating: 255, count: stride * height)
      for row in 0..<height {
        for column in 0..<width {
          let offset = row * stride + column * 4
          pixels[offset] = 0
          pixels[offset + 1] = 0
          pixels[offset + 2] = 0
          pixels[offset + 3] = alpha[row * width + column]
        }
      }
      return CGImage(
        width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: stride, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo ?? bgra),
        provider: CGDataProvider(data: Data(pixels) as CFData)!,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    let hit = MacOSAvatarAlphaHitTest()
    let square = CGRect(x: 0, y: 0, width: 2, height: 2)
    let bottomLeft = CGPoint(x: 0.5, y: 0.5)
    let bottomRight = CGPoint(x: 1.5, y: 0.5)
    let topLeft = CGPoint(x: 0.5, y: 1.5)
    let topRight = CGPoint(x: 1.5, y: 1.5)
    check(!hit.contains(bottomLeft, in: square), "no frame passes through")

    let asymmetric = makeImage([16, 0, 15, 255])
    hit.replaceImage(asymmetric)
    check(hit.contains(bottomLeft, in: square), "alpha 16 is interactive at lower left")
    check(!hit.contains(bottomRight, in: square), "alpha 0 passes at lower right")
    check(!hit.contains(topLeft, in: square), "alpha 15 passes at upper left")
    check(hit.contains(topRight, in: square), "opaque upper right uses padded second row")
    check(hit.contains(.zero, in: square), "minimum edge is included")
    check(!hit.contains(CGPoint(x: 2, y: 1.5), in: square), "maximum X edge is excluded")
    check(!hit.contains(CGPoint(x: 1.5, y: 2), in: square), "maximum Y edge is excluded")
    check(!hit.contains(CGPoint(x: -0.01, y: 0.5), in: square), "outside negative X passes")
    check(!hit.contains(bottomLeft, in: .zero), "empty bounds pass")
    check(!hit.contains(CGPoint(x: CGFloat.nan, y: 0), in: square), "NaN point passes")
    check(!hit.contains(bottomLeft, in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 2)),
          "invalid bounds pass")

    for scale: CGFloat in [1.2, 1.8, 2.4, 3.0] {
      let bounds = CGRect(x: 37, y: 19, width: 2 * scale, height: 2 * scale)
      check(hit.contains(CGPoint(x: 37 + 0.5 * scale, y: 19 + 0.5 * scale), in: bounds),
            "translated scaled opaque point \(scale)")
      check(!hit.contains(CGPoint(x: 37 + 1.5 * scale, y: 19 + 0.5 * scale), in: bounds),
            "translated scaled transparent point \(scale)")
    }
    let tallBounds = CGRect(x: 0, y: 0, width: 4, height: 8)
    check(!hit.contains(CGPoint(x: 1, y: 1), in: tallBounds), "bottom letterbox passes")
    check(!hit.contains(CGPoint(x: 3, y: 7), in: tallBounds), "top letterbox passes")
    check(hit.contains(CGPoint(x: 1, y: 3), in: tallBounds), "resizeAspect fits centered square")
    hit.replaceImage(makeImage([255, 255], width: 1, height: 2, stride: 8))
    let wideBounds = CGRect(x: 10, y: 20, width: 4, height: 4)
    check(!hit.contains(CGPoint(x: 10.5, y: 21), in: wideBounds), "left letterbox passes")
    check(!hit.contains(CGPoint(x: 13.5, y: 21), in: wideBounds), "right letterbox passes")
    check(hit.contains(CGPoint(x: 12, y: 21), in: wideBounds), "portrait center hits")

    hit.replaceImage(makeImage([255, 255, 255, 255]))
    check(hit.contains(bottomLeft, in: square), "replacement opaque frame hits")
    hit.replaceImage(makeImage([0, 0, 0, 0]))
    check(!hit.contains(bottomLeft, in: square), "replacement clears previous cached alpha")
    hit.replaceImage(asymmetric)
    hit.replaceImage(nil)
    check(!hit.contains(bottomLeft, in: square), "clearing frame releases prior mask")
    hit.replaceImage(makeImage([255, 255, 255, 255], bitmapInfo:
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue))
    check(!hit.contains(bottomLeft, in: square), "missing alpha layout fails open")
    hit.replaceImage(makeImage([255, 255, 255, 255], bitmapInfo:
      CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
    check(!hit.contains(bottomLeft, in: square), "unexpected byte order fails open")
    hit.replaceImage(makeImage([16, 0, 0, 0], bitmapInfo:
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue))
    check(hit.contains(bottomLeft, in: square), "explicit unpremultiplied BGRA alpha is supported")
    let shortImage = CGImage(
      width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
      space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bgra),
      provider: CGDataProvider(data: Data([UInt8](repeating: 255, count: 12)) as CFData)!,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    hit.replaceImage(shortImage)
    check(!hit.contains(topRight, in: square), "truncated provider data fails open")

    // Production CIContext .BGRA8 output must be accepted, not just synthetic images.
    let ciContext = CIContext(options: [.cacheIntermediates: false])
    let image = ciContext.createCGImage(
      CIImage(cgImage: asymmetric), from: square,
      format: .BGRA8, colorSpace: colorSpace)!
    hit.replaceImage(image)
    check(hit.contains(bottomLeft, in: square), "real CoreImage BGRA8 threshold accepted")
    check(!hit.contains(bottomRight, in: square), "real CoreImage transparent pixel passes")

    // Calibrate bitmap row direction using a graphics operation independent of the hit math.
    var calibration = [UInt8](repeating: 0, count: 16)
    calibration.withUnsafeMutableBytes { bytes in
      let context = CGContext(
        data: bytes.baseAddress, width: 2, height: 2, bitsPerComponent: 8,
        bytesPerRow: 8, space: colorSpace, bitmapInfo: bgra)!
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    check(calibration[11] == 255 && calibration[3] == 0,
          "CoreGraphics y=0 fills final raw bitmap row")

    let root = CALayer()
    root.bounds = square
    let avatar = CALayer()
    avatar.bounds = square
    avatar.position = CGPoint(x: 1, y: 1)
    avatar.contents = image
    avatar.contentsGravity = .resizeAspect
    avatar.magnificationFilter = .nearest
    avatar.minificationFilter = .nearest
    avatar.transform = CATransform3DMakeScale(1, -1, 1)
    root.addSublayer(avatar)
    var rendered = [UInt8](repeating: 0, count: 16)
    rendered.withUnsafeMutableBytes { bytes in
      let context = CGContext(
        data: bytes.baseAddress, width: 2, height: 2, bitsPerComponent: 8,
        bytesPerRow: 8, space: colorSpace, bitmapInfo: bgra)!
      root.render(in: context)
    }
    let points = [bottomLeft, bottomRight, topLeft, topRight]
    // Offsets established by fill calibration, not by the helper's image-row formula.
    for (point, alphaOffset) in zip(points, [11, 15, 3, 7]) {
      check(hit.contains(point, in: square) == (rendered[alphaOffset] >= 16),
            "hit matches actual flipped CALayer rendering at \(point)")
    }

    let retina = makeImage([
      16, 16, 0, 0, 16, 16, 0, 0,
      15, 15, 255, 255, 15, 15, 255, 255,
    ], width: 4, height: 4, stride: 20)
    let retinaHit = MacOSAvatarAlphaHitTest()
    retinaHit.replaceImage(retina)
    for point in points {
      check(retinaHit.contains(point, in: square) == hit.contains(point, in: square),
            "Retina pixel density preserves logical-point hit at \(point)")
    }
    print("PASS: \(assertions) macOS alpha hit-test assertions")
  }
}
