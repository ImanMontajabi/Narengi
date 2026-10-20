import SwiftUI
import os

enum Theme {
    /// Narengi orange (#F26522).
    static let accent = Color(red: 0.949, green: 0.396, blue: 0.133)
}

enum Log {
    static let subsystem = "app.narengi.Narengi"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let drag = Logger(subsystem: subsystem, category: "drag")
    static let job = Logger(subsystem: subsystem, category: "job")
    static let wheel = Logger(subsystem: subsystem, category: "wheel")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
