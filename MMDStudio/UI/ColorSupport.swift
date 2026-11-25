import SwiftUI
import UIKit
import simd

extension Color {
    init(simd4 value: SIMD4<Float>) {
        self.init(.sRGB,
                  red: Double(max(0, min(1, value.x))),
                  green: Double(max(0, min(1, value.y))),
                  blue: Double(max(0, min(1, value.z))),
                  opacity: Double(max(0, min(1, value.w))))
    }

    var simd4: SIMD4<Float> {
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
    }
}

extension PMXMorph {
    var panelName: String {
        switch panel {
        case 1: return "眉"
        case 2: return "眼"
        case 3: return "口"
        case 4: return "其他"
        default: return "系统"
        }
    }
}
