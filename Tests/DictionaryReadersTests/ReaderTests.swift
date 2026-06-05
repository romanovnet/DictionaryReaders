// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import DictionaryReaders

/// Original, generated wire fixtures: no dictionary content or upstream parser
/// implementation is included. See ORIGIN.md.
private enum WireFixture {
    static func integer(_ value: Int, _ width: Int, little: Bool = false) -> Data {
        let shifts = little ? Array(0..<width) : Array((0..<width).reversed())
        return Data(shifts.map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func field(_ bytes: Data, _ width: Int, little: Bool = false) -> Data {
        integer(bytes.count, width, little: little) + bytes
    }
    // One RFC 1951 uncompressed block; fixture payloads are below 65536 bytes.
    static func deflate(_ bytes: Data) -> Data {
        precondition(bytes.count < 65536)
        return Data([1]) + integer(bytes.count, 2, little: true)
            + integer(65535 - bytes.count, 2, little: true) + bytes
    }
    static func zlib(_ bytes: Data) -> Data {
        var a = 1, b = 0
        for byte in bytes { a = (a + Int(byte)) % 65521; b = (b + a) % 65521 }
        return Data([0x78, 0x01]) + deflate(bytes) + integer((b << 16) | a, 4)
    }
    static func bgl(_ stream: Data) -> Data {
        var crc: UInt32 = .max
        for byte in stream {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        let gzip = Data([31,139,8,0,0,0,0,0,0,255]) + deflate(stream)
            + integer(Int(~crc), 4, little: true) + integer(stream.count, 4, little: true)
        return Data([0x12,0x34,0,2,0,6]) + gzip
    }
    static func block(_ type: UInt8, _ bytes: Data, width: Int = 2) -> Data {
        Data([UInt8(width - 1) << 4 | type]) + field(bytes, width)
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func apple(_ root: URL, compressed: Bool, indexed: Bool = true, flat: Bool = false,
                      corruptFirstSection: Bool = false, emptyFirstKeyword: Bool = false, extraFlags: Int = 0) throws -> URL {
        let bundle = root.appendingPathComponent("Example.dictionary")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let xml = Data("<d:entry d:title=\"example\" xmlns:d=\"urn:dictionary\"><span class=\"df\">Original test article</span></d:entry>".utf8)
        let article = integer(xml.count, 4, little: true) + xml
        func section(_ bytes: Data) -> Data {
            let payload = compressed ? zlib(bytes) : bytes
            let content = compressed ? integer(bytes.count, 4, little: true) + payload : payload
            return integer(content.count + 4, 4, little: true) + field(content, 4, little: true)
        }
        var body = Data(repeating: 0, count: 96)
        body.replaceSubrange(72..<76, with: integer(0xffffffff, 4, little: true))
        if flat { body.append(article) }
        else {
            if corruptFirstSection {
                // Valid next-jump, impossible data length; reader must continue.
                body.append(integer(8, 4, little: true) + integer(0xffffffff, 4, little: true) + Data(repeating: 0, count: 4))
            }
            body.append(section(article))
        }
        body.replaceSubrange(64..<68, with: integer(body.count - 64, 4, little: true))
        try body.write(to: resources.appendingPathComponent("Body.data"))
        if indexed {
            var records = Data([0,0])
            for (word, flag) in [("examples", 0), ("example", 18), ("examples", 0)] {
                var record = integer(flat ? 32 : 0, 4, little: true)
                if !flat { record.append(integer(corruptFirstSection ? 44 : 32, 4, little: true)) }
                record.append(integer(flag | extraFlags, 2, little: true))
                if emptyFirstKeyword { record.append(Data([0,0])) }
                record.append(field(word.data(using: .utf16LittleEndian)!, 2, little: true))
                records.append(field(record, 2, little: true))
            }
            let group = (compressed ? Data() : Data(repeating: 0, count: 4)) + integer(3, 2, little: true) + records
            let keywords = field(group, 4, little: true)
            var keyFile = Data(repeating: 0, count: 64)
            if compressed {
                let zipped = zlib(keywords)
                let chunk = integer(zipped.count + 4, 4, little: true) + integer(keywords.count, 4, little: true) + zipped
                keyFile.append(integer(chunk.count + 8, 4, little: true))
                keyFile.append(integer(chunk.count, 4, little: true)); keyFile.append(chunk)
            } else {
                keyFile.append(integer(keywords.count + 4, 4, little: true)); keyFile.append(keywords)
            }
            try keyFile.write(to: resources.appendingPathComponent("KeyText.data"))
        }
        let plist: [String: Any] = [
            "CFBundleDisplayName": "Fixture Dictionary", "DCSDictionaryCSS": "style.css",
            "CFBundleIconFile": "icon.png", "DCSDictionaryLanguages": [["DCSDictionaryIndexLanguage": "en"]],
            // Deliberately reordered: matching by name must not depend on position.
            "IDXDictionaryIndexes": [
                ["IDXIndexName": "DCSBodyDataIndex", "HeapDataCompressionType": compressed ? 2 : 0],
                ["IDXIndexName": "DCSKeywordIndex", "TrieAuxiliaryDataOptions": ["HeapDataCompressionType": compressed ? 3 : 0],
                 "IDXIndexDataFields": ["IDXFixedDataFields": [["IDXDataSize": 2]], "IDXExternalDataFields": [["IDXDataSize": flat ? 4 : 8]]]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data(".df { color: green }".utf8).write(to: resources.appendingPathComponent("style.css"))
        try Data([1,2,3]).write(to: resources.appendingPathComponent("icon.png"))
        return bundle
    }
}

@Suite("Babylon reader") struct BabylonReplacementTests {
    @Test(arguments: [1,7,10,11,13]) func entryForms(_ type: Int) async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let word = Data("Café$2$".utf8), alias = Data("coffee".utf8), body = Data("Original article".utf8)
        var record: Data
        if type == 11 {
            record = WireFixture.field(word, 5) + WireFixture.integer(1, 4)
                + WireFixture.field(alias, 4) + WireFixture.field(body, 4)
        } else { record = WireFixture.field(word, 1) + WireFixture.field(body, 2) + WireFixture.field(alias, 1) }
        // Metadata follows entries; all block length widths and inline blocks occur.
        let stream = WireFixture.block(UInt8(type), record, width: type == 11 ? 4 : 2)
            + WireFixture.block(3, Data([0,17,0,0,128,0]), width: 3)
            + WireFixture.block(3, Data([0,1]) + Data("Original fixture".utf8), width: 1) + Data([0x40])
        let url = root.appendingPathComponent("test.bgl"); try WireFixture.bgl(stream).write(to: url)
        let dictionary = try await BabylonDictionary(url: url)
        #expect(dictionary.title == "Original fixture")
        #expect(dictionary.lookup(exact: "CAFE").count == 1)
        #expect(dictionary.lookup(exact: "coffee").first?.headwords == ["Café", "coffee"])
        #expect(dictionary.indexEntries.first?.body == "Original article")
        #expect(dictionary.prefix(matching: "CO", limit: 1) == ["coffee"])
    }
    @Test func wideEntryAlternateSentinel() async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at:root) }
        // The zero length terminates alternates before the declared count.
        let record = WireFixture.field(Data("example".utf8), 5) + WireFixture.integer(100, 4)
            + WireFixture.integer(0, 4) + WireFixture.field(Data("article".utf8), 4)
        let url = root.appendingPathComponent("sentinel.bgl")
        try WireFixture.bgl(WireFixture.block(11,record)).write(to:url)
        let dictionary = try await BabylonDictionary(url:url)
        #expect(dictionary.indexEntries.first?.body == "article")
    }
    @Test func sourceAndTargetEncodings() async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let record = WireFixture.field(Data([0xe9]), 1) + WireFixture.field(Data([0xe1,20,24,1,0xe9]), 2)
        let stream = WireFixture.block(1, record) + WireFixture.block(3, Data([0,0x1a,0x42]))
            + WireFixture.block(3, Data([0,0x1b,0x49])) + WireFixture.block(3, Data([0,1,0xe1]))
        let url = root.appendingPathComponent("legacy.bgl"); try WireFixture.bgl(stream).write(to: url)
        let dictionary = try await BabylonDictionary(url: url)
        #expect(dictionary.lookup(exact: "é").count == 1)
        #expect(dictionary.title == "α")
        #expect(dictionary.indexEntries.first?.body == "é<br>\nα")
    }
    @Test func trailingMetadata() {
        let ignored: [[UInt8]] = [[6,0],[7,0,0],[0x13,2,65,66],[0x1a,1,65],[0x28,0,1,65],
                                  [0x40,0,0],[0x4f] + Array(repeating:0,count:17),[0x50,9,1,65],[0x60,9,0,1,65]]
        for field in ignored {
            let bytes: [UInt8] = [65,20] + field + [24,3,66,38,67,2,48]
            #expect(BglText.processDefi(bytes, sourceEncoding:.utf8, targetEncoding:.utf8) == "<em class=\"bgl-pos\">noun</em> B&C<br>\nA")
        }
        #expect(BglCharset.partOfSpeech(68) == "participle")
        #expect(BglCharset.partOfSpeech(0) == nil)
    }
    @Test func nestedEncodingAndMalformedInput() {
        let bytes = Array("a<charset c=U>é<charset c=T>D83D;DE00;</charset>z</charset>b".utf8)
        #expect(BglText.decodeCharsetTags(bytes, defaultEncoding:.windowsCP1252, sourceEncoding:.utf8) == "aé😀zb")
        #expect(BglText.decodeCharsetTags(Array("<charset c=T>0041;bad;0042;</charset>".utf8), defaultEncoding:.utf8, sourceEncoding:.utf8) == "AB")
        let hostile = Array((String(repeating:"<charset c=U>",count:1000) + "x").utf8)
        #expect(BglText.decodeCharsetTags(hostile, defaultEncoding:.utf8, sourceEncoding:.utf8).contains("x"))
        // An incomplete metadata candidate is retained as text, not used to cut
        // off the article. Control characters still pass through normal cleanup.
        #expect(BglText.processDefi([65,20,0x28,255], sourceEncoding:.utf8, targetEncoding:.utf8).hasPrefix("A("))
    }
    @Test func trailerRequiresCompleteFieldChain() {
        func render(_ value: [UInt8]) -> String {
            BglText.processDefi(value, sourceEncoding: .utf8, targetEncoding: .utf8)
        }
        // Control characters in ordinary text must not truncate that text.
        #expect(render(Array("A\u{14} next".utf8)) == "A next")
        #expect(render(Array("A\u{14}!next".utf8)) == "A!next")
        // A complete trailer after an earlier false marker is still recognized.
        #expect(render([65,20,33,66,20,2,48]) == "<em class=\"bgl-pos\">noun</em><br>\nA!B")
        // Valid first field followed by unknown/truncated data is not a trailer.
        #expect(render([65,20,2,48,255]).hasPrefix("A0"))
        #expect(render([65,20,0x18,4,66]).hasPrefix("AB"))
        // Empty length-prefixed fields and marker bytes inside a field are valid.
        #expect(render([65,20,0x18,0,2,48]) == "<em class=\"bgl-pos\">noun</em><br>\nA")
        #expect(render([65,20,0x13,2,20,32,2,48]) == "<em class=\"bgl-pos\">noun</em><br>\nA")
    }
    @Test func truncatedFramingIsRejected() throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for bytes in [Data([0x12,0x34]), WireFixture.bgl(Data([0x31,0,0,0,255,65]))] {
            let url = root.appendingPathComponent("bad.bgl"); try bytes.write(to:url)
            #expect(throws: BabylonError.badHeader) { try BglFile(url:url) }
        }
    }
}

@Suite("Apple reader") struct AppleReplacementTests {
    @Test(arguments: [false,true]) func nativeIndexAndResources(_ compressed: Bool) async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try WireFixture.apple(root, compressed: compressed)
        let dictionary = try await AppleDictionary(bundleURL: bundle)
        #expect(dictionary.title == "Fixture Dictionary")
        #expect(dictionary.lookup(exact:"examples").first?.headwords == ["example","examples"])
        #expect(dictionary.indexEntries.first?.body == "<div class=\"apple_entry\"><span class=\"df\">Original test article</span></div>")
        #expect(dictionary.css == ".df { color: green }")
        #expect(dictionary.embeddedIconData == Data([1,2,3]))
        #expect(dictionary.languagePair?.source == "en")
        #expect(dictionary.resource(forPath:"icon.png")?.data == Data([1,2,3]))
        let outside = root.appendingPathComponent("private.txt"); try Data("secret".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:dictionary.resourcesDirectory.appendingPathComponent("escape"), withDestinationURL:outside)
        #expect(dictionary.resource(forPath:"escape") == nil)
        #expect(dictionary.resource(forPath:"%2e%2e/Info.plist") == nil)
    }
    @Test(arguments: [false,true]) func fallbackSkipsDamagedSection(_ compressed: Bool) async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try WireFixture.apple(root, compressed:compressed, indexed:false, corruptFirstSection:true)
        // A corrupt index must behave like a missing index, preserving title lookup.
        try Data([1,2,3]).write(to:bundle.appendingPathComponent("Contents/Resources/KeyText.data"))
        let dictionary = try await AppleDictionary(bundleURL:bundle.appendingPathComponent("Contents/Resources/Body.data"))
        #expect(dictionary.allHeadwords() == ["example"])
        #expect(dictionary.indexEntries.first?.body.contains("Original test article") == true)
    }
    @Test func flatAddressAndLegacyLayout() async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try WireFixture.apple(root, compressed:false, flat:true)
        let contents = bundle.appendingPathComponent("Contents"), resources = contents.appendingPathComponent("Resources")
        for file in try FileManager.default.contentsOfDirectory(at:resources, includingPropertiesForKeys:nil) {
            try FileManager.default.moveItem(at:file, to:contents.appendingPathComponent(file.lastPathComponent))
        }
        try FileManager.default.removeItem(at:resources)
        let dictionary = try await AppleDictionary(bundleURL:contents)
        #expect(dictionary.lookup(exact:"examples").count == 1)
        #expect(dictionary.indexEntries.first?.body.contains("Original test article") == true)
    }
    @Test(arguments: [1, 32, 64, 128, 256]) func priorityIgnoresOtherFlagBits(_ extra: Int) async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try WireFixture.apple(root, compressed: true, extraFlags: extra)
        let catalog = try #require(AppleKeyText.index(at: bundle.appendingPathComponent("Contents/Resources/KeyText.data"),
            props: AppleProps(keyTextCompressed: true, bodyHasSections: true, fixedFieldByteLen: 2)))
        #expect(catalog.keywordsByAddress == [["example", "examples"]])
    }
    @Test func oversizedHeapBlockKeepsFollowingBlock() throws {
        let allocation = 32
        let payloads = [Data(repeating: 65, count: 70), Data("tail".utf8)]
        var file = Data(repeating: 0, count: 68)
        file.append(WireFixture.integer(allocation, 4, little: true))
        for payload in payloads {
            let compressed = WireFixture.zlib(payload)
            var block = WireFixture.integer(compressed.count + 4, 4, little: true)
                + WireFixture.integer(payload.count, 4, little: true) + compressed
            let padding = (allocation - block.count % allocation) % allocation
            block.append(Data(repeating: 0, count: padding)); file.append(block)
        }
        file.replaceSubrange(64..<68, with: WireFixture.integer(file.count - 64, 4, little: true))
        #expect(AppleHeap.keywords(file, compressed: true) == payloads[0] + payloads[1])
        var wrongLength = file
        wrongLength.replaceSubrange(76..<80, with: WireFixture.integer(1, 4, little: true))
        #expect(AppleHeap.keywords(wrongLength, compressed: true) == nil)
        var truncated = file
        truncated.removeLast()
        truncated.replaceSubrange(64..<68, with: WireFixture.integer(truncated.count - 64, 4, little: true))
        #expect(AppleHeap.keywords(truncated, compressed: true) == nil)
    }
    @Test func emptyFirstKeywordKeepsAlternate() async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at:root) }
        let bundle = try WireFixture.apple(root, compressed:true, emptyFirstKeyword:true)
        let catalog = try #require(AppleKeyText.index(at:bundle.appendingPathComponent("Contents/Resources/KeyText.data"),
            props:AppleProps(keyTextCompressed:true, bodyHasSections:true, fixedFieldByteLen:2)))
        #expect(catalog.keywordsByAddress == [["example", "examples"]])
    }
    @Test func iconNameFallbackSurvivesMissingIconFile() async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at:root) }
        let bundle = try WireFixture.apple(root, compressed:false)
        let icon = AppleDictionary.readBundleIcon(contents:bundle.appendingPathComponent("Contents"),
            plist:["CFBundleIconFile":"missing", "CFBundleIconName":"icon"])
        #expect(icon == Data([1,2,3]))
    }
    @Test func rejectsOverflowingPlistSizes() async throws {
        let root = try WireFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try WireFixture.apple(root, compressed: false)
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf:url), format:nil) as! [String:Any]
        plist["IDXDictionaryIndexes"] = [["IDXIndexName":"DCSKeywordIndex", "IDXIndexDataFields":
            ["IDXFixedDataFields":[["IDXDataSize":Int.max],["IDXDataSize":1]]]]]
        try PropertyListSerialization.data(fromPropertyList:plist, format:.xml, options:0).write(to:url)
        await #expect(throws: AppleDictionaryError.notAppleDictionary(bundle)) { try await AppleDictionary(bundleURL:bundle) }
    }
    @Test func cursorRejectsInvalidLengths() {
        var cursor = ReaderBytes(Data([255,255,255,255,255]))
        #expect(cursor.field(5) == nil)
        #expect(cursor.take(-1) == nil)
        #expect(AppleHeap.range(Data(repeating:255,count:80)) == nil)
        #expect(AppleHeap.bodySection(Data(repeating:0,count:80), address:400, compressed:true) == nil)
    }
}
