# Verification

For maintainers reproducing reader checks without a dictionary collection.

## Default tests

```sh
swift test --jobs 2
swift build -c release --jobs 2
swift build --package-path Examples/Lookup --jobs 2
```

The tests generate tiny original files in temporary directories and remove them
afterward. They cover BGL entry types and length widths, legacy/UTF-8 decoding,
alternate keys, supported metadata, malformed framing/charset spans and complete
trailer validation. Apple tests cover native indexes, fallback, layouts, flat and
section addresses, priority masking, oversized blocks, icons and confined resources.
Additional tests cover plain/zlib SDictionary, plain/gzip/dictzip DictD,
cross-chunk reads, metadata exclusion, offsets that would overflow an integer,
UTF-8/UTF-16 and compressed TEI, nested entries, alternate headwords, links and
stored-entry rendering. They are regression tests, not an exhaustive fuzzer or
hostile-input audit.

The test builders use stored DEFLATE blocks and compute their checksums; the
readers do not validate checksums.

## Optional installed native-index check

Set `DICTIONARY_READERS_APPLE_BUNDLE` to a locally installed **New Oxford American
Dictionary v3-style bundle with more than 250,000 folded keywords**, using compressed
KeyText, sectioned bodies and a two-byte fixed field. This test directly checks
native-index decoding, bypassing body fallback. It is deliberately specific to
that fixture layout; do not point it at an arbitrary small dictionary.

```sh
DICTIONARY_READERS_APPLE_BUNDLE=/path/to/New\ Oxford\ American\ Dictionary.dictionary \
  swift test --jobs 2
```

The package contains neither that dictionary nor its article text. The normal
test run skips this optional check if its environment variable is absent.

## Public API consumer

`Examples/Lookup` is a separate package importing the public module, without
`@testable`. Supply a local dictionary file, for example:

```sh
swift run --package-path Examples/Lookup --jobs 2 Lookup tei /path/eng-fra.tei tree
```

It prints matching headwords and article HTML. A release
candidate should also be exported, unpacked into a separate directory, have its
SHA256SUMS checked, and pass the default tests and example build from that copy.
Record actual commands/results in the originating project's release records;
do not equate the declared iOS/visionOS platforms with verified builds.
