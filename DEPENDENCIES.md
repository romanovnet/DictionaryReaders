# Dependencies

The package has no external SwiftPM dependencies, vendored decoder libraries or
prebuilt binaries. Runtime code uses Swift, Foundation/CoreFoundation and Apple's
Compression framework. Tests use Swift Testing. The export script uses
Python 3's standard library.

| Sources under `Sources/DictionaryReaders` | Purpose |
|---|---|
| `Apple/` | Bundle metadata, keyword index, article loading and resources |
| `Babylon/` | BGL framing, encodings, entries and metadata |
| `Sdict/` | SDictionary headers, index, article loading and markup |
| `DictD/` | Text index and article markup |
| `Tei/` | Entry extraction and TEI-to-HTML rendering |
| `Support/DictDataStore.swift`, `Support/DictZip.swift` | Plain/gzip/dictzip article access |
| `Support/Gzip.swift` | Gzip/zlib framing and system DEFLATE calls |
| `Support/ReaderBytes.swift`, `Support/LRUCache.swift` | Checked byte reads and lock-protected caching |
| `Support/XmlText.swift`, `Support/ResourceMIME.swift` | XML text helpers and resource media types |
| `DictionarySource.swift` | Public protocols, value types and lookup folding |

The supplied implementation and generated fixtures are offered under MIT on the
review basis in [ORIGIN.md](ORIGIN.md). No upstream GPL source is bundled or linked.
Apple frameworks and dictionary content retain their own terms.
