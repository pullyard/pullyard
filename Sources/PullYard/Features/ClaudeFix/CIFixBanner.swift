import SwiftUI

struct CIFixRequest: Identifiable {
    let id = UUID()
    var focus: String?
    var log: String?
}

struct CIFixLaunch {
    let tabID: UUID?
    let target: ClaudeTarget
    let headOid: String
    let at: Date
}
