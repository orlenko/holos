import AppKit
import HolosCore

/// The credits of the About panel (docs/meeting-design.md §4.8): the app has no resource bundle, so the text of
/// THIRD_PARTY_NOTICES.md's speaker-model section and the FluidAudio and Readability lines are embedded here.
enum AboutCredits {
    /// The notice GPLv3 §5(d) asks an interactive program to show. It points to the LICENSE.txt and TRADEMARKS.md
    /// the build scripts copy into this bundle, and to the release tag's copies online when the build recorded one.
    static var license: String {
        LicenseNotice.text(
            bundleName: Bundle.main.bundleURL.lastPathComponent,
            sourceTag: Bundle.main.object(forInfoDictionaryKey: LicenseNotice.sourceTagInfoKey) as? String)
    }

    static let fluidAudio = """
        Speaker labels are made by the bundled voiceislocal tool with FluidAudio 0.17.1 \
        (https://github.com/FluidInference/FluidAudio, tag v0.17.1, commit 5c51c5c9), licensed under the Apache \
        License 2.0. The Voice is Local app does not link FluidAudio or include the models; see THIRD_PARTY_NOTICES.md for the \
        full license texts.
        """

    static let readability = """
        The bundled voiceislocal tool reads web articles with Mozilla Readability 0.6.0 \
        (https://github.com/mozilla/readability, tag 0.6.0), Copyright (c) 2010 Arc90 Inc, licensed under the \
        Apache License 2.0; see THIRD_PARTY_NOTICES.md.
        """

    static let models = """
        Speaker labels use Segmentation.mlmodelc, FBank.mlmodelc, Embedding.mlmodelc, PldaRho.mlmodelc, \
        plda-parameters.json, and xvector-transform.json from \
        https://huggingface.co/FluidInference/speaker-diarization-coreml (revision \
        df2625ac79a7ac6b65ad868fee6d80f320da4232), downloaded by `voiceislocal setup --speakers` and not included in the \
        app. They are licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0, \
        https://creativecommons.org/licenses/by/4.0/). They are modified Core ML conversions, made by Fluid \
        Inference, of the pyannote Community-1 speaker diarization pipeline (pyannote, CC BY 4.0), which uses \
        WeSpeaker speaker embeddings and PLDA parameters licensed by BUT Speech@FIT under CC BY 4.0. The model card \
        describes the segmentation and embedding conversions as historically reconstructed, not build-attested.

        Citations:
        - Alexis Plaquet and Hervé Bredin. "Powerset multi-class cross entropy loss for neural speaker \
        diarization." Proc. INTERSPEECH 2023.
        - Hongji Wang, Chengdong Liang, Shuai Wang, Zhengyang Chen, Binbin Zhang, Xu Xiang, Yanlei Deng, and \
        Yanmin Qian. "Wespeaker: A research and production oriented speaker embedding learning toolkit." ICASSP \
        2023.
        - Federico Landini, Ján Profant, Mireia Diez, and Lukáš Burget. "Bayesian HMM clustering of x-vector \
        sequences (VBx) in speaker diarization: theory, implementation and analysis on standard tasks." Computer \
        Speech & Language, 2022.
        """

    static let whisper = """
        Final transcripts are made by the bundled voiceislocal tool with WhisperKit 1.1.0 \
        (https://github.com/argmaxinc/WhisperKit, tag v1.1.0), MIT License, Copyright (c) 2024 argmax, inc., which \
        includes parts of Hugging Face's swift-transformers (Apache License 2.0). The model, \
        openai_whisper-large-v3-v20240930_turbo from https://huggingface.co/argmaxinc/whisperkit-coreml (MIT), is \
        Argmax's Core ML conversion of OpenAI's Whisper large-v3-turbo (MIT), downloaded by \
        `voiceislocal setup --whisper` and not included in the app; see THIRD_PARTY_NOTICES.md.
        """

    static let pocket = """
        Natural Reading voices are made by the bundled voiceislocal tool with Pocket TTS by Kyutai \
        (https://huggingface.co/kyutai/pocket-tts), licensed under the Creative Commons Attribution 4.0 International \
        License (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/), in Fluid Inference's Core ML conversion \
        (https://huggingface.co/FluidInference/pocket-tts-coreml, CC BY 4.0), downloaded by `voiceislocal setup \
        --natural-voices` and not included in the app. Voices: Alba (voiced by Alba MacKenna, CC BY 4.0); Anna, \
        Azelma, Charles, Eponine, Eve, Fantine, George, Jane, Mary, Michael, Paul, and Vera (from the VCTK corpus, \
        CSTR, The University of Edinburgh, CC BY 4.0); Bill Boerst, Caro Davy, Javert, Marius, Peter Yearsley, Stuart \
        Bell, and Estelle (CC0); see THIRD_PARTY_NOTICES.md.
        """

    static var text: String { [license, fluidAudio, readability, models, whisper, pocket].joined(separator: "\n\n") }

    /// The credits as the About panel shows them.
    static func attributed() -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
