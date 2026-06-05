// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import DictionaryReaders

/// Original content and wire encoders; no external dictionary is redistributed.
private enum AdditionalFixture {
    static func number(_ value: Int, width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
    static func storedBlock(_ data: Data, final: Bool = true) -> Data {
        precondition(data.count < 65536)
        return Data([final ? 1 : 0]) + number(data.count, width: 2)
            + number(65535 - data.count, width: 2) + data
    }
    static func zlib(_ data: Data) -> Data {
        var a = 1, b = 0
        for byte in data { a = (a + Int(byte)) % 65521; b = (b + a) % 65521 }
        return Data([0x78, 0x01]) + storedBlock(data)
            + Data(number((b << 16) | a, width: 4).reversed())
    }
    static func gzip(_ data: Data, chunkLength: Int? = nil) -> Data {
        var header = Data([31,139,8,chunkLength == nil ? 0 : 4,0,0,0,0,0,255])
        var payload = Data()
        if let length = chunkLength {
            let chunks = stride(from: 0, to: data.count, by: length).map { start in
                storedBlock(data.subdata(in: start..<min(start + length, data.count)),
                            final: start + length >= data.count)
            }
            var ra = number(1, width: 2) + number(length, width: 2) + number(chunks.count, width: 2)
            for chunk in chunks { ra.append(number(chunk.count, width: 2)); payload.append(chunk) }
            let extra = Data([82,65]) + number(ra.count, width: 2) + ra
            header.append(number(extra.count, width: 2)); header.append(extra)
        } else { payload = storedBlock(data) }
        var crc: UInt32 = .max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        return header + payload + number(Int(~crc), width: 4) + number(data.count, width: 4)
    }
    static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("additional-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func base64(_ value: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var result = "", remaining = value
        repeat { result.insert(alphabet[remaining % 64], at: result.startIndex); remaining /= 64 } while remaining > 0
        return result
    }
    static func sdict(compressed: Bool) -> Data {
        func record(_ text: String) -> Data {
            let bytes = compressed ? zlib(Data(text.utf8)) : Data(text.utf8)
            return number(bytes.count, width: 4) + bytes
        }
        let title = record("Garden fixture")
        let entries = [("Café", "A quiet garden. See <r>oak</r>\nEnd."), ("oak", "Original <b>tree</b> article.")]
        var index = Data(), articles = Data()
        for (word, body) in entries {
            let key = Data(word.utf8)
            index.append(number(key.count + 8, width: 2) + number(0, width: 2)
                         + number(articles.count, width: 4) + key)
            articles.append(record(body))
        }
        var header = Data("sdctengfra".utf8) + Data([compressed ? 1 : 0])
        for value in [entries.count, 0, 43, 0, 0, 0, 43 + title.count, 43 + title.count + index.count] {
            header.append(number(value, width: 4))
        }
        return header + title + index + articles
    }
    static let tei = """
    <?xml version="1.0" encoding="UTF-8"?>
    <TEI><teiHeader><fileDesc><titleStmt><title>Garden &amp; sky</title></titleStmt></fileDesc></teiHeader>
    <text><body><entryFree><orth>ignored</orth></entryFree>
    <entry><form><orth>Caf&#233;</orth><orth>coffee</orth></form>
    <gramGrp><pos>noun</pos></gramGrp><sense n="2"><def>Original garden text.</def>
    <cit><quote>Quiet shade.</quote></cit><ref>oak</ref></sense>
    <re><entry><form><orth>sapling</orth></form><sense><def>Original nested text.</def></sense></entry></re></entry>
    <entry><form><orth>oak</orth></form><sense><def>Original tree text.</def></sense></entry>
    </body></text></TEI>
    """
}

@Suite("SDictionary") struct AdditionalSdictTests {
    @Test(arguments: [false, true]) func lookup(_ compressed: Bool) async throws {
        let root = try AdditionalFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("garden.dct")
        try AdditionalFixture.sdict(compressed: compressed).write(to: url)
        let reader = try await SdictDictionary(url: url)
        #expect(reader.title == "Garden fixture")
        #expect(reader.languagePair == LanguagePair(source: "eng", target: "fra"))
        #expect(reader.headwordCount == 2)
        let html = try #require(reader.lookup(exact: "CAFE").first?.markup.html)
        #expect(html.contains("href=\"bword:oak\""))
        #expect(html.contains("<br/>End."))
        #expect(reader.prefix(matching: "ca", limit: 1) == ["Café"])
        #expect(reader.allHeadwords() == ["Café", "oak"])
        #expect(reader.lookup(exact: "absent").isEmpty)
        #expect(SdictDictionary.convert("<BR>x<br>y") == "<br/>x<br/>y")
    }
    @Test func invalidHeaderAndCompression() async throws {
        let root = try AdditionalFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invalid.dct")
        var data = AdditionalFixture.sdict(compressed: false)
        data[10] = 2; try data.write(to: url)
        await #expect(throws: SdictError.unsupportedCompression("bzip2")) { try await SdictDictionary(url: url) }
        data[10] = 0; data.replaceSubrange(11..<15, with: Data(repeating: 255, count: 4)); try data.write(to: url)
        await #expect(throws: SdictError.noEntries(url)) { try await SdictDictionary(url: url) }
        try Data([1,2,3]).write(to: url)
        await #expect(throws: SdictError.fileNotReadable(url)) { try await SdictDictionary(url: url) }
    }
}

@Suite("DictD") struct AdditionalDictdTests {
    @Test(arguments: ["plain", "gzip", "dictzip"]) func lookup(_ mode: String) async throws {
        let root = try AdditionalFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("garden")
        var bodies = Data(), index = ""
        for (word, body) in [("00-database-short", "00-database-short\nGarden fixture\n"),
                             ("Café", "Café\nOriginal text. See {oak}. < &\n"),
                             ("oak", "oak \\sound\\\nOriginal tree text.\n")] {
            let bytes = Data(body.utf8)
            index += "\(word)\t\(AdditionalFixture.base64(bodies.count))\t\(AdditionalFixture.base64(bytes.count))\n"
            bodies.append(bytes)
        }
        // An overflowing integer must be rejected without trapping or hiding valid entries.
        index += "bad\t/////////////////////////\tB\n"
        let indexURL = base.appendingPathExtension("index")
        if mode == "plain" {
            try Data(index.utf8).write(to: indexURL)
            try bodies.write(to: base.appendingPathExtension("dict"))
        } else {
            try AdditionalFixture.gzip(Data(index.utf8)).write(to: base.appendingPathExtension("index.gz"))
            try AdditionalFixture.gzip(bodies, chunkLength: mode == "dictzip" ? 17 : nil)
                .write(to: base.appendingPathExtension("dict.dz"))
        }
        let reader = try await DictdDictionary(indexURL: indexURL)
        #expect(reader.title == "Garden fixture")
        #expect(reader.headwordCount == 2)
        #expect(DictdDictionary.headwordCount(indexURL: indexURL) == 4)
        #expect(reader.lookup(exact: "00-database-short").isEmpty)
        let html = try #require(reader.lookup(exact: "CAFE").first?.markup.html)
        #expect(html.contains("<a href=\"bword:oak\">oak</a>"))
        #expect(html.contains("&lt; &amp;"))
        #expect(reader.lookup(exact: "oak").first?.markup.html.contains("dictd_phonetic") == true)
        #expect(reader.prefix(matching: "ca", limit: 1) == ["cafe"])
    }
    @Test func missingAndOutOfRangeArticles() async throws {
        let root = try AdditionalFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("invalid"), index = base.appendingPathExtension("index")
        try Data("oak\tB\t\(AdditionalFixture.base64(Int.max))\n".utf8).write(to: index)
        await #expect(throws: DictdError.missingDataFile(base: base)) { try await DictdDictionary(indexURL: index) }
        try Data([65]).write(to: base.appendingPathExtension("dict"))
        let reader = try await DictdDictionary(indexURL: index)
        #expect(reader.lookup(exact: "oak").first?.markup.body == .unavailable(reason: "out-of-range article"))
    }
    @Test func chunkRangesAndBounds() throws {
        let bytes = Data((0..<130).map { UInt8($0) })
        let zip = try #require(DictZip(AdditionalFixture.gzip(bytes, chunkLength: 17)))
        for (offset, size) in [(0,1), (16,3), (0,130), (119,11), (130,0)] {
            #expect(try zip.read(offset: offset, size: size) == bytes.subdata(in: offset..<offset + size))
        }
        #expect(throws: DictZipError.outOfRange) { try zip.read(offset: Int.max, size: 2) }
        #expect(throws: DictZipError.outOfRange) { try zip.read(offset: 129, size: 2) }
        #expect(throws: DictZipError.outOfRange) { try zip.read(offset: 0, size: -1) }
        #expect(DictZip(Data([31,139,8,4])) == nil)
    }
}

@Suite("TEI") struct AdditionalTeiTests {
    @Test(arguments: [false, true]) func lookup(_ compressed: Bool) async throws {
        let root = try AdditionalFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(compressed ? "eng-fra.tei.gz" : "eng-fra.tei")
        let bytes = Data(AdditionalFixture.tei.utf8)
        try (compressed ? AdditionalFixture.gzip(bytes) : bytes).write(to: url)
        let reader = try await TeiDictionary(url: url)
        #expect(reader.title == "Garden & sky")
        #expect(reader.languagePair == LanguagePair(source: "eng", target: "fra"))
        #expect(reader.lookup(exact: "ignored").isEmpty)
        #expect(reader.lookup(exact: "CAFE").first?.headwords == ["Café", "coffee", "sapling"])
        let html = try #require(reader.lookup(exact: "coffee").first?.markup.html)
        #expect(html.contains("tei_sensenum\">2.</span>"))
        #expect(html.contains("href=\"bword:oak\""))
        #expect(html.contains("Original nested text."))
        #expect(reader.prefix(matching: "ca", limit: 1) == ["cafe"])
        #expect(reader.indexEntries.count == 2)
        #expect(Tei2Html.convert(reader.indexEntries[0].body) == html)
    }
    @Test func utf16AndEmpty() async throws {
        let root = try AdditionalFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("eng-fra.tei")
        try (Data([255,254]) + AdditionalFixture.tei.data(using: .utf16LittleEndian)!).write(to: url)
        #expect(try await TeiDictionary(url: url).lookup(exact: "oak").count == 1)
        try Data("<TEI/>".utf8).write(to: url)
        await #expect(throws: TeiError.notTei(url)) { try await TeiDictionary(url: url) }
    }
}
