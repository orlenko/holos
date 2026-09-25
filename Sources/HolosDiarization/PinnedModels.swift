import Foundation

/// Every file FluidAudio 0.17.1 downloads for the offline diarizer from
/// `FluidInference/speaker-diarization-coreml` at revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`, relative to
/// `FluidModels.repoFolder(in:)` (docs/meeting-design.md §4.8).
///
/// Recorded on 2026-09-24 with `HOLOS_RECORD_MODEL_MANIFEST=1 voiceislocal setup --speakers`. The 22 model artifacts match
/// the SHA-256 and size the repo's own `provenance.json` lists for them; all 24 files, including `config.json` and
/// `provenance.json` (which `provenance.json` does not list), match the Hugging Face tree API at the pinned revision
/// (`lfs.oid` for LFS files, the git blob SHA-1 for the others). The `.fluidaudio-revision` marker is checked
/// separately (`FluidModels.status`).
public enum PinnedModels {
    /// `ModelTreeDigest.digest(of: files)`, the `sha256` every run records for these models.
    public static let treeDigest = "9540dc3b91e348d28110db4caf560d7c2d5bdd6d54e3658ad8e7ae0a7d809da6"

    public static let files: [PinnedFile] = [
        PinnedFile(relativePath: "Embedding.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
        PinnedFile(relativePath: "Embedding.mlmodelc/coremldata.bin", size: 704,
                   sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
        PinnedFile(relativePath: "Embedding.mlmodelc/metadata.json", size: 2_818,
                   sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
        PinnedFile(relativePath: "Embedding.mlmodelc/model.mil", size: 78_432,
                   sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
        PinnedFile(relativePath: "Embedding.mlmodelc/weights/weight.bin", size: 13_412_288,
                   sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
        PinnedFile(relativePath: "FBank.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
        PinnedFile(relativePath: "FBank.mlmodelc/coremldata.bin", size: 853,
                   sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
        PinnedFile(relativePath: "FBank.mlmodelc/metadata.json", size: 3_409,
                   sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
        PinnedFile(relativePath: "FBank.mlmodelc/model.mil", size: 15_667,
                   sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
        PinnedFile(relativePath: "FBank.mlmodelc/weights/weight.bin", size: 1_776_896,
                   sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
        PinnedFile(relativePath: "PldaRho.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
        PinnedFile(relativePath: "PldaRho.mlmodelc/coremldata.bin", size: 763,
                   sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
        PinnedFile(relativePath: "PldaRho.mlmodelc/metadata.json", size: 2_749,
                   sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
        PinnedFile(relativePath: "PldaRho.mlmodelc/model.mil", size: 7_613,
                   sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
        PinnedFile(relativePath: "PldaRho.mlmodelc/weights/weight.bin", size: 200_192,
                   sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
        PinnedFile(relativePath: "Segmentation.mlmodelc/analytics/coremldata.bin", size: 243,
                   sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
        PinnedFile(relativePath: "Segmentation.mlmodelc/coremldata.bin", size: 812,
                   sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
        PinnedFile(relativePath: "Segmentation.mlmodelc/metadata.json", size: 3_410,
                   sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
        PinnedFile(relativePath: "Segmentation.mlmodelc/model.mil", size: 43_063,
                   sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
        PinnedFile(relativePath: "Segmentation.mlmodelc/weights/weight.bin", size: 5_959_360,
                   sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
        PinnedFile(relativePath: "config.json", size: 2,
                   sha256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"),
        PinnedFile(relativePath: "plda-parameters.json", size: 89_416,
                   sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
        PinnedFile(relativePath: "provenance.json", size: 10_048,
                   sha256: "0353430db062715c411ba32e66cb435b9caee2662bccdb298f9e5d1bae760872"),
        PinnedFile(relativePath: "xvector-transform.json", size: 177_499,
                   sha256: "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688"),
    ]
}
