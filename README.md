# DictionaryReaders

Swift readers for Apple Dictionary, Babylon, SDictionary, DictD and FreeDict TEI.
Loads local files, looks up headwords and returns article HTML. No UI, database,
networking or external package dependencies. Dictionary files are not included.

## Requirements

Swift 6 tools and an Apple SDK. Deployment targets: macOS 15, iOS 18 and visionOS 2.
Builds and tests are verified on Apple Silicon macOS; iOS and visionOS are unverified.
Decompression uses Apple's Compression framework, so Linux and Windows are unsupported.

```sh
swift test --jobs 2
swift build -c release --jobs 2
```

## Usage

```swift
// Package.swift
.package(url: "https://github.com/romanovnet/DictionaryReaders.git", from: "0.1.0")

// Target dependencies
.product(name: "DictionaryReaders", package: "DictionaryReaders")
```

```swift
import Foundation
import DictionaryReaders

let reader = try await TeiDictionary(url: URL(fileURLWithPath: "/path/eng-fra.tei"))
for entry in reader.lookup(exact: "tree") {
    print(entry.headwords)
    print(entry.markup.html)
}
let suggestions = reader.prefix(matching: "tr", limit: 10)
```

| Reader | Input | Supported scope |
|---|---|---|
| `AppleDictionary(bundleURL:)` | `.dictionary` bundle | Native keyword index, article sections, CSS and embedded resources |
| `BabylonDictionary(url:)` | `.bgl` | Ordinary/wide entries, alternate headwords, legacy/UTF-8 encodings and supported metadata |
| `SdictDictionary(url:)` | `.dct` | Plain or zlib articles; bzip2 is rejected |
| `DictdDictionary(indexURL:)` | `.index` with `.dict` or `.dict.dz` | Plain/gzip index, dictzip random access and gzip fallback; pass the logical `.index` path even when only `.index.gz` or `.index.dz` exists |
| `TeiDictionary(url:)` | `.tei` or `.tei.gz` | Entry/headword extraction and a subset of TEI P5 markup |

Every reader implements `DictionarySource`: title, language pair when available,
headword count, exact lookup, prefix lookup and headword enumeration. Lookup folds
case and diacritics. Prefix/enumeration spelling and duplicate handling vary by format.
DictD's enumeration includes metadata keys; exact lookup excludes them.

`EntryMarkup.body` is either `.html(String)` or `.unavailable(reason:)`.
The `html` convenience property supplies escaped diagnostic HTML for an unavailable
article. HTML from dictionary content is **not sanitized**; callers control rendering.

Apple and Babylon implement `BodyIndexable` with HTML bodies. TEI's `indexEntries`
contain raw entry XML; render those through `Tei2Html.convert`. Enumeration may read
and decompress an entire dictionary. Apple also implements `DictionaryResourceProvider`.

The separate example uses only the public API:

```sh
swift run --package-path Examples/Lookup --jobs 2 Lookup tei /path/eng-fra.tei tree
# Other selectors: apple, babylon, sdict, dictd
```

## Limits and license

TEI uses a lightweight scanner, not a complete validating XML processor. Babylon
embedded resources and some metadata/rare variants are unsupported. Gzip/zlib
checksums and decompression budgets are not enforced. Selected malformed-input
cases are tested; this is not a complete hostile-input audit.

[MIT-licensed](LICENSE). No GPL-licensed code is bundled or linked, and there are
no external package dependencies. See the [source review and its scope](ORIGIN.md),
[dependencies](DEPENDENCIES.md) and [test instructions](TESTING.md). Dictionary
content has its own licensing terms.
