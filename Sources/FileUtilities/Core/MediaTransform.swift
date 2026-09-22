import CoreImage
import CoreImage.CIFilterBuiltins

/// Crop → flip → rotate → resize, shared by photos and videos.
struct MediaTransform: Equatable {
    enum Resize: Equatable {
        case none
        case percent(Double)
        case fit(width: Int, height: Int)
        case width(Int)
        case height(Int)
    }

    enum Crop: Equatable {
        case none
        case aspect(Double)
        /// Fractions (0..<0.5) removed from each edge.
        case insets(top: Double, left: Double, bottom: Double, right: Double)
    }

    var resize: Resize = .none
    var crop: Crop = .none
    var rotation = 0
    var flipHorizontal = false
    var flipVertical = false

    var isIdentity: Bool {
        resize == .none && crop == .none && rotation % 360 == 0 && !flipHorizontal && !flipVertical
    }

    func cropRect(for size: CGSize) -> CGRect? {
        switch crop {
        case .none:
            return nil
        case .aspect(let ratio):
            guard ratio > 0 else { return nil }
            if size.width / size.height > ratio {
                let w = (size.height * ratio).rounded()
                return CGRect(x: ((size.width - w) / 2).rounded(), y: 0, width: w, height: size.height)
            } else {
                let h = (size.width / ratio).rounded()
                return CGRect(x: 0, y: ((size.height - h) / 2).rounded(), width: size.width, height: h)
            }
        case let .insets(top, left, bottom, right):
            let w = size.width * max(0.02, 1 - left - right), h = size.height * max(0.02, 1 - top - bottom)
            // Core Image's origin is bottom-left.
            return CGRect(x: size.width * left, y: size.height * bottom, width: w, height: h).integral
        }
    }

    func resizedSize(for size: CGSize) -> CGSize {
        var scaleX = 1.0, scaleY = 1.0
        switch resize {
        case .none: break
        case .percent(let p): scaleX = p / 100; scaleY = p / 100
        case let .fit(w, h):
            let s = min(Double(w) / size.width, Double(h) / size.height, 1)
            scaleX = s; scaleY = s
        case .width(let w): scaleX = Double(w) / size.width; scaleY = scaleX
        case .height(let h): scaleY = Double(h) / size.height; scaleX = scaleY
        }
        return CGSize(width: max(1, (size.width * scaleX).rounded()), height: max(1, (size.height * scaleY).rounded()))
    }

    /// Final pixel size for an input of `size` (already upright).
    func outputSize(for size: CGSize, even: Bool) -> CGSize {
        var s = cropRect(for: size)?.size ?? size
        if rotation % 180 != 0 { s = CGSize(width: s.height, height: s.width) }
        s = resizedSize(for: s)
        if even {
            s = CGSize(width: max(2, floor(s.width / 2) * 2), height: max(2, floor(s.height / 2) * 2))
        }
        return s
    }

    func apply(_ input: CIImage, even: Bool) -> CIImage {
        var image = input.atOrigin
        let target = outputSize(for: image.extent.size, even: even)
        if let rect = cropRect(for: image.extent.size) {
            image = image.cropped(to: rect).atOrigin
        }
        if flipHorizontal { image = image.oriented(.upMirrored).atOrigin }
        if flipVertical { image = image.oriented(.downMirrored).atOrigin }
        switch ((rotation % 360) + 360) % 360 {
        case 90: image = image.oriented(.right).atOrigin
        case 180: image = image.oriented(.down).atOrigin
        case 270: image = image.oriented(.left).atOrigin
        default: break
        }
        if target != image.extent.size {
            let sx = target.width / image.extent.width, sy = target.height / image.extent.height
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image.clampedToExtent().cropped(to: image.extent.insetBy(dx: -4, dy: -4))
            filter.scale = Float(sy)
            filter.aspectRatio = Float(sx / sy)
            image = (filter.outputImage ?? image).cropped(to: CGRect(origin: .zero, size: target))
        }
        return image.cropped(to: CGRect(origin: .zero, size: target))
    }
}

extension CIImage {
    var atOrigin: CIImage {
        let o = extent.origin
        return o == .zero ? self : transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y))
    }

    /// Applies an AVFoundation (top-left origin) preferred transform to a Core Image frame.
    func applyingVideoTransform(_ t: CGAffineTransform) -> CIImage {
        let linear = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0)
        guard !linear.isIdentity else { return self }
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        return transformed(by: flip.concatenating(linear).concatenating(flip)).atOrigin
    }
}
