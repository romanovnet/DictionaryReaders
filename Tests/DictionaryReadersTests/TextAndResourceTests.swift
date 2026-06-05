// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import DictionaryReaders

@Suite("Text and resource support") struct TextAndResourceTests {
    @Test func keyMarkersAndEntities() {
        let cases = [("oak$17$", "oak"), ("wood$$$$", "wood"), ("a$tree$b", "a$tree$b"),
                     ("<b>caf&#233;</b>", "café"), ("x&amp;y", "x&y"), ("caf&eacute;", "caf&eacute;")]
        for (input, expected) in cases {
            #expect(BglText.processKey(Array(input.utf8), sourceEncoding: .utf8) == expected)
        }
        #expect(BglText.decodeCharsetTags(Array("<charset c=T>03A9;</charset>".utf8),
            defaultEncoding: .utf8, sourceEncoding: .utf8) == "Ω")
    }
    @Test func iconNamesAndMissingKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bytes = Data([8, 6, 4, 2])
        try bytes.write(to: resources.appendingPathComponent("Sample.png"))
        #expect(AppleDictionary.readBundleIcon(contents: root, plist: ["CFBundleIconFile":"Sample.png"]) == bytes)
        #expect(AppleDictionary.readBundleIcon(contents: root, plist: ["CFBundleIconName":"Sample"]) == bytes)
        #expect(AppleDictionary.readBundleIcon(contents: root, plist: [:]) == nil)
    }
    @Test func cacheEvictsLeastRecentlyRead() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache.insert("one", for: 1); cache.insert("two", for: 2)
        #expect(cache.value(for: 1) == "one")
        cache.insert("three", for: 3)
        #expect(cache.value(for: 2) == nil)
        #expect(cache.value(for: 1) == "one")
        #expect(cache.value(for: 3) == "three")
    }
}

@Suite("Optional installed Apple dictionary") struct ExternalAppleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_READERS_APPLE_BUNDLE"] != nil))
    func nativeIndexWithoutFallback() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DICTIONARY_READERS_APPLE_BUNDLE"])
        let bundle = URL(fileURLWithPath: path)
        let catalog = try #require(AppleKeyText.index(at: bundle.appendingPathComponent("Contents/Resources/KeyText.data"),
            props: AppleProps(keyTextCompressed: true, bodyHasSections: true, fixedFieldByteLen: 2)))
        #expect(Set(catalog.keywordsByAddress.flatMap { $0 }.map(LookupKey.fold)).count > 250_000)
    }
}
