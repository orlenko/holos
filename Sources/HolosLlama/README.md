# HolosLlama

Tidy Up on Qwen through llama.cpp (docs/design.md "Tidy Up").

**Owns**
- `LlamaModel`: a GGUF model and one context loaded with llama.cpp on the GPU; greedy decoding, one request at a time.
- `QwenTidy`: the Qwen chat format with thinking off, and the tidier on it.

**Must not own:** being linked by the app (it tidies through `voiceislocal tidy`), the tidying rules (`TextTidier`, HolosCore).

**Depends on:** HolosCore; llama.cpp (`llama`, a pinned prebuilt framework).

**Tests:** the real-model test needs `HOLOS_TIDY_GGUF` (a path to the model file).
