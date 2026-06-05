# Source origin

The implementation is offered under MIT based on a technical comparison that identified no remaining copied GPL
implementation in the included readers and helpers. This is a scoped technical
assessment, not legal certification or a claim of development without prior exposure.

Apple and Babylon replace earlier readers informed by GPL sources. SDictionary,
DictD and TEI were compared with the references recorded during their development:

- [GoldenDict-NG, revision 2c0f493](https://github.com/xiaoyifang/goldendict-ng/tree/2c0f49367b69c1d2b8942d747da55e8c72cdd118): Babylon, SDictionary, DictD, dictzip and XDXF rendering references.
- [PyGlossary, revision 96408b3](https://github.com/ilius/pyglossary/tree/96408b33979d140b500f3875ee7a436a911b3cb0): Apple, Babylon and FreeDict references.
- [Historical SDictionary reference, revision 42235b0](https://github.com/ilius/pyglossary/blob/42235b00aaebab9e041e00643ca1d92403beee0c/pyglossary/plugins/sdict.py).

These GPL sources were review references, not copied dependencies. Original
consulted revisions were not recorded; the links identify comparison snapshots.
Shared file-layout constants, standard alphabets, XML names and short descriptive
labels were assessed separately from implementation structure. The Swift readers
use their own indexing, parsing and rendering code. TEI vocabulary is documented
in the [TEI Guidelines](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html).

Tests generate original small dictionaries and include no commercial corpus or
upstream fixture archive.
