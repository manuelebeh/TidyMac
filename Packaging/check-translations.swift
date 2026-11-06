// Checks each translation against the texts in the source code. Run it from the repository root, with the folder of
// .stringsdata files that the compiler's -emit-localized-strings writes (Packaging/check-translations.sh does both).
//
// Fails when a text has no translation, when a translation has no text any more, or when a translation's format
// specifiers differ from its text's, which would show the wrong value or crash.
import Foundation

struct Data_: Decodable {
    struct Entry: Decodable { let key: String }
    let tables: [String: [Entry]]
}

let specifier = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?(#@[A-Za-z0-9_]+@|@|lld|llu|ld|lu|d|u|lf|f|%)"#)

/// The kinds of value a text takes, in argument order. `%1$@` and `%@` count the same, so a translation can reorder.
func specifiers(_ text: String) -> [String] {
    let range = NSRange(text.startIndex..., in: text)
    var next = 1
    var found: [(Int, String)] = []
    for m in specifier.matches(in: text, range: range) {
        let kind = String(text[Range(m.range(at: 2), in: text)!])
        if kind == "%" { continue }
        let position = Range(m.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? next
        if m.range(at: 1).location == NSNotFound { next += 1 }
        found.append((position, kind.hasPrefix("#@") ? "lld" : kind))
    }
    return found.sorted { $0.0 < $1.0 }.map(\.1)
}

/// A text with nothing to translate, such as "%@ — %@", needs no entry.
func hasWords(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return specifier.stringByReplacingMatches(in: text, range: range, withTemplate: "").unicodeScalars.contains(where: CharacterSet.letters.contains)
}

let extracted = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
var keys = Set<String>()
for case let url as URL in fm.enumerator(at: extracted, includingPropertiesForKeys: nil)! where url.pathExtension == "stringsdata" {
    let parsed = try JSONDecoder().decode(Data_.self, from: Data(contentsOf: url))
    for entry in parsed.tables.values.joined() where hasWords(entry.key) { keys.insert(entry.key) }
}
guard !keys.isEmpty else { print("No extracted texts in \(extracted.path)"); exit(1) }

var problems: [String] = []

/// The value of each variant of a counted text, with its variable filled in, so they can be checked like plain ones.
func pluralValues(_ entry: [String: Any]) -> [String] {
    guard let format = entry["NSStringLocalizedFormatKey"] as? String else { return [] }
    var values: [String] = []
    for (name, variable) in entry where name != "NSStringLocalizedFormatKey" {
        guard let variable = variable as? [String: Any] else { continue }
        for (rule, text) in variable where !rule.hasPrefix("NSString") {
            guard let text = text as? String else { continue }
            values.append(format.replacingOccurrences(of: "%#@\(name)@", with: text)
                .replacingOccurrences(of: "%2$#@\(name)@", with: text).replacingOccurrences(of: "%1$#@\(name)@", with: text))
        }
    }
    return values
}

let root = URL(fileURLWithPath: "Localization")
let languages = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".lproj") }.sorted()
for language in languages {
    let dir = root.appendingPathComponent(language)
    let strings = (NSDictionary(contentsOf: dir.appendingPathComponent("Localizable.strings")) as? [String: String]) ?? [:]
    let plurals = (NSDictionary(contentsOf: dir.appendingPathComponent("Localizable.stringsdict")) as? [String: [String: Any]]) ?? [:]

    // English is the source language: only its counted texts need an entry.
    if language != "en.lproj" {
        for key in keys.sorted() where strings[key] == nil && plurals[key] == nil { problems.append("\(language): no translation for \"\(key)\"") }
        for key in strings.keys.sorted() where !keys.contains(key) && hasWords(key) { problems.append("\(language): \"\(key)\" is not in the code") }
    }
    for key in plurals.keys.sorted() where !keys.contains(key) { problems.append("\(language): counted text \"\(key)\" is not in the code") }

    for (key, value) in strings where specifiers(key) != specifiers(value) {
        problems.append("\(language): format of \"\(value)\" does not match \"\(key)\"")
    }
    for (key, entry) in plurals {
        for value in pluralValues(entry) where specifiers(key) != specifiers(value) {
            problems.append("\(language): format of \"\(value)\" does not match \"\(key)\"")
        }
    }
}

if problems.isEmpty {
    print("\(keys.count) texts checked against \(languages.joined(separator: ", ")).")
} else {
    print(problems.sorted().joined(separator: "\n"))
    print("\(problems.count) problems.")
    exit(1)
}
