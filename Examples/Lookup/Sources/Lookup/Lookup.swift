// SPDX-License-Identifier: MIT
import Foundation
import DictionaryReaders

@main struct Lookup {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["apple", "babylon", "sdict", "dictd", "tei"].contains(args[1]) else {
            print("Usage: swift run Lookup <apple|babylon|sdict|dictd|tei> <dictionary-path> <word>")
            return
        }
        let url = URL(fileURLWithPath: args[2])
        let reader: any DictionarySource
        switch args[1] {
        case "apple": reader = try await AppleDictionary(bundleURL: url)
        case "babylon": reader = try await BabylonDictionary(url: url)
        case "sdict": reader = try await SdictDictionary(url: url)
        case "dictd": reader = try await DictdDictionary(indexURL: url)
        default: reader = try await TeiDictionary(url: url)
        }
        for entry in reader.lookup(exact: args[3]) {
            print(entry.headwords.joined(separator: ", "))
            print(entry.markup.html)
        }
    }
}
