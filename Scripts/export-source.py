#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Export the reviewed source allowlist without Git/build/private metadata."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
FILES = """
.gitignore
Package.swift
LICENSE
README.md
ORIGIN.md
DEPENDENCIES.md
TESTING.md
Sources/DictionaryReaders/DictionarySource.swift
Sources/DictionaryReaders/Apple/AppleDictionary.swift
Sources/DictionaryReaders/Apple/AppleKeyText.swift
Sources/DictionaryReaders/Babylon/BabylonDictionary.swift
Sources/DictionaryReaders/Babylon/BglFile.swift
Sources/DictionaryReaders/Babylon/BglCharset.swift
Sources/DictionaryReaders/Babylon/BglText.swift
Sources/DictionaryReaders/Support/Gzip.swift
Sources/DictionaryReaders/Support/LRUCache.swift
Sources/DictionaryReaders/Support/ReaderBytes.swift
Sources/DictionaryReaders/Support/ResourceMIME.swift
Sources/DictionaryReaders/Support/XmlText.swift
Sources/DictionaryReaders/Sdict/SdictDictionary.swift
Sources/DictionaryReaders/DictD/DictdDictionary.swift
Sources/DictionaryReaders/DictD/DictdArticle.swift
Sources/DictionaryReaders/Tei/TeiDictionary.swift
Sources/DictionaryReaders/Tei/Tei2Html.swift
Sources/DictionaryReaders/Support/DictDataStore.swift
Sources/DictionaryReaders/Support/DictZip.swift
Tests/DictionaryReadersTests/AdditionalReaderTests.swift
Tests/DictionaryReadersTests/ReaderTests.swift
Tests/DictionaryReadersTests/TextAndResourceTests.swift
Examples/Lookup/Package.swift
Examples/Lookup/Sources/Lookup/Lookup.swift
Scripts/export-source.py
""".split()


def export(output):
    payload = {}
    for name in sorted(FILES):
        source = ROOT / name
        if any(path.is_symlink() for path in [source, *source.parents] if path != ROOT.parent):
            raise ValueError(f'Symlink in export path: {name}')
        if not source.is_file():
            raise ValueError(f'Missing source file: {name}')
        payload[name] = source.read_bytes()
    payload['SHA256SUMS'] = ''.join(
        f'{hashlib.sha256(data).hexdigest()}  {name}\n'
        for name, data in payload.items()).encode()
    # No current time, filesystem owner/name, extended attributes or Git archive header.
    with output.open('xb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name, data in sorted(payload.items()):
                    info = tarfile.TarInfo('DictionaryReaders/' + name)
                    info.size = len(data)
                    info.mode = 0o644
                    archive.addfile(info, io.BytesIO(data))
    print(f'{hashlib.sha256(output.read_bytes()).hexdigest()}  {output.name}')
    print(f'{len(payload)} files; {output.stat().st_size} bytes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    export(parser.parse_args().output)
