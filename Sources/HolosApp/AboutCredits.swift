import AppKit

/// The credits of the About panel (docs/meeting-design.md §4.8): the app has no resource bundle, so the text of
/// THIRD_PARTY_NOTICES.md's speaker-model section and the FluidAudio line are embedded here.
enum AboutCredits {
    static let fluidAudio = """
        Speaker labels are made by the bundled voiceislocal tool with FluidAudio 0.17.1 \
        (https://github.com/FluidInference/FluidAudio, tag v0.17.1, commit 5c51c5c9), licensed under the Apache \
        License 2.0. The Voice is Local app does not link FluidAudio or include the models; see THIRD_PARTY_NOTICES.md for the \
        full license texts.
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

    static var text: String { fluidAudio + "\n\n" + models }

    /// The credits as the About panel shows them.
    static func attributed() -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
