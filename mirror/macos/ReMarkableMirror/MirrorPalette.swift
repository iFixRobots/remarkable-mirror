import SwiftUI

enum MirrorPalette {
    static let navy = Color(red: 0 / 255, green: 10 / 255, blue: 35 / 255)
    static let stage = Color(red: 237 / 255, green: 236 / 255, blue: 231 / 255)
    static let paper = Color(red: 250 / 255, green: 249 / 255, blue: 245 / 255)
    static let secondaryPaper = Color(red: 247 / 255, green: 246 / 255, blue: 241 / 255)
    static let ink = Color(red: 32 / 255, green: 33 / 255, blue: 36 / 255)
    static let muted = Color(red: 95 / 255, green: 96 / 255, blue: 102 / 255)
    static let accent = Color(red: 56 / 255, green: 88 / 255, blue: 233 / 255)
    static let bezel = Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)
    static let border = Color(red: 207 / 255, green: 207 / 255, blue: 201 / 255)

    static func status(_ tone: StatusTone) -> Color {
        switch tone {
        case .green: Color(red: 82 / 255, green: 210 / 255, blue: 139 / 255)
        case .gray: Color(red: 137 / 255, green: 145 / 255, blue: 158 / 255)
        case .amber: Color(red: 230 / 255, green: 166 / 255, blue: 46 / 255)
        case .red: Color(red: 225 / 255, green: 83 / 255, blue: 83 / 255)
        }
    }
}
