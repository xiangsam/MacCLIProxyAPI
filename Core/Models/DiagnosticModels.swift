import Foundation

enum DiagnosticLevel: String, Equatable, Sendable {
    case pass
    case warning
    case fail
}

struct DiagnosticCheck: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var level: DiagnosticLevel
}
