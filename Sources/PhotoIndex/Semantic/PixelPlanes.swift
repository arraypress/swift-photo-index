//
//  PixelPlanes.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  A picture as SigLIP 2's image encoder wants it: squeezed (not cropped) to
//  224×224 RGB, scaled to 0…1, then (x − 0.5) / 0.5, planar channel-first.
//  Squeezing matches the reference processor, which resizes to the exact size
//  without keeping the aspect ratio.
//

import CoreGraphics
import Foundation

enum PixelPlanes {

    /// Planar float RGB, `size`×`size`, normalised as SigLIP expects; nil if
    /// the picture cannot be drawn.
    static func normalised(_ image: CGImage, size: Int, mean: Float = 0.5, std: Float = 0.5) -> [Float]? {
        let bytesPerRow = size * 4
        var rgba = [UInt8](repeating: 0, count: size * bytesPerRow)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        let plane = size * size
        var out = [Float](repeating: 0, count: 3 * plane)
        let scale = 1 / (255 * std)
        let offset = mean / std
        for pixel in 0..<plane {
            let base = pixel * 4
            out[pixel] = Float(rgba[base]) * scale - offset
            out[plane + pixel] = Float(rgba[base + 1]) * scale - offset
            out[2 * plane + pixel] = Float(rgba[base + 2]) * scale - offset
        }
        return out
    }
}
