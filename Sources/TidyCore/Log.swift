import Foundation
import os

/// What TidyMac writes to the system log, for `log show --predicate 'subsystem == "io.github.manuelebeh.TidyMac"'` or
/// Console. Names of files and apps are private, so a log shared in a bug report does not carry them.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.manuelebeh.TidyMac"
    static let executor = Logger(subsystem: subsystem, category: "executor")
    static let shell = Logger(subsystem: subsystem, category: "shell")
}
