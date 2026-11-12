#!/usr/bin/env swift
//
// Generates the service icons from Simple Icons (https://simpleicons.org), CC0:
//
//   npm pack simple-icons@16.36.0
//   swift tools/service-icons.swift simple-icons-16.36.0.tgz
//
// The tarball must match the npm registry's integrity hash recorded below, so a different or tampered download is
// refused. To update Simple Icons, change the version above and the hash to `npm view simple-icons@<version>
// dist.integrity`.
//
// It reads the slugs in tools/service-icons.txt, copies their SVGs into an image set each in
// Authenticator/Assets.xcassets/ServiceIcons, and writes their names and colors to
// Authenticator/Accounts/ServiceIconCatalog.swift. Icons whose license isn't CC0 are refused, as attribution or
// copyleft would apply to them. Run it from the root of the repository.

import CryptoKit
import Foundation

let expectedIntegrity = "sha512-+VNPPkqSOLidFeSgBKUWX4n50WPpDC09hav+BgS26anIF1oQOlGBb8LvwGR+6fYRjo+B6CiKzNBceMPkSVXANQ=="

struct Entry: Decodable {
    struct Aliases: Decodable {
        let aka: [String]?
        let loc: [String: String]?
    }
    struct License: Decodable {
        let type: String
    }
    let title: String
    let slug: String
    let hex: String
    let aliases: Aliases?
    let license: License?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("Usage: swift tools/service-icons.swift <simple-icons tarball>") }
let tarball = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default

let integrity = "sha512-" + Data(SHA512.hash(data: try Data(contentsOf: tarball))).base64EncodedString()
guard integrity == expectedIntegrity else {
    fail("\(tarball.path) is \(integrity), not the expected \(expectedIntegrity)")
}
let unpacked = fileManager.temporaryDirectory.appending(component: "service-icons-\(UUID().uuidString)")
try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: unpacked) }
let tar = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", tarball.path, "-C", unpacked.path])
tar.waitUntilExit()
guard tar.terminationStatus == 0 else { fail("Couldn't unpack \(tarball.path)") }
// npm tarballs keep their files in a folder named "package".
let package = unpacked.appending(component: "package")

let data = try Data(contentsOf: package.appending(components: "data", "simple-icons.json"))
let entries = Dictionary(try JSONDecoder().decode([Entry].self, from: data).map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
let version =
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: package.appending(component: "package.json"))) as? [String: Any])?["version"]
    as? String ?? "?"

let slugs = try String(contentsOfFile: "tools/service-icons.txt", encoding: .utf8)
    .split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

let catalog = URL(fileURLWithPath: "Authenticator/Assets.xcassets/ServiceIcons")
try? fileManager.removeItem(at: catalog)
try fileManager.createDirectory(at: catalog, withIntermediateDirectories: true)
// A folder of its own, so the images are named "ServiceIcons/<slug>" and can't clash with the app's.
try Data(
    """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "provides-namespace" : true
      }
    }

    """.utf8
).write(to: catalog.appending(component: "Contents.json"))

func swiftString(_ string: String) -> String {
    "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

var lines = [String]()
// The slug names files and the color is written into Swift source, so both must be exactly what they should be.
let slugPattern = #/[a-z0-9]+/#
let hexPattern = #/[0-9A-Fa-f]{6}/#

for slug in slugs {
    guard slug.wholeMatch(of: slugPattern) != nil else { fail("\(slug) in tools/service-icons.txt isn't a slug") }
    guard let entry = entries[slug] else { fail("No icon \(slug) in Simple Icons \(version)") }
    guard entry.hex.wholeMatch(of: hexPattern) != nil else { fail("\(slug)'s color \(entry.hex) isn't six hex digits") }
    if let license = entry.license?.type, license != "CC0-1.0" { fail("\(slug) is licensed under \(license), not CC0") }
    let imageSet = catalog.appending(component: "\(slug).imageset")
    try fileManager.createDirectory(at: imageSet, withIntermediateDirectories: true)
    try fileManager.copyItem(at: package.appending(components: "icons", "\(slug).svg"), to: imageSet.appending(component: "\(slug).svg"))
    // A template, drawn in the color that contrasts with the brand's.
    try Data(
        """
        {
          "images" : [
            {
              "filename" : "\(slug).svg",
              "idiom" : "universal"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          },
          "properties" : {
            "preserves-vector-representation" : true,
            "template-rendering-intent" : "template"
          }
        }

        """.utf8
    ).write(to: imageSet.appending(component: "Contents.json"))

    let names = ([entry.title] + (entry.aliases?.aka ?? []) + (entry.aliases?.loc?.values.sorted() ?? []))
    lines.append(
        "        ServiceIcon(slug: \(swiftString(slug)), color: 0x\(entry.hex.uppercased()), names: [\(names.map(swiftString).joined(separator: ", "))]),"
    )
}

let source = """
    // Generated by tools/service-icons.swift from Simple Icons \(version) (https://simpleicons.org), CC0. Don't edit.

    extension ServiceIcon {
        /// The bundled icons, with the names of the brand each one is found by.
        nonisolated static let catalog: [ServiceIcon] = [
    \(lines.joined(separator: "\n"))
        ]
    }

    """
try Data(source.utf8).write(to: URL(fileURLWithPath: "Authenticator/Accounts/ServiceIconCatalog.swift"))
print("\(slugs.count) icons from Simple Icons \(version)")
