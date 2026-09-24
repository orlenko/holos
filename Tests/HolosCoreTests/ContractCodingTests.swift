import Foundation
import Testing
@testable import HolosCore

// Contract coding tests (docs/meeting-design.md §3). The JSON examples below are copied verbatim from §3.4.

@Test func openCodesDecodeUnknownValues() throws {
    let stages = try HolosJSON.decoder().decode([PostProcessingStage].self, from: Data(#"["minutes"]"#.utf8))
    let stage = try #require(stages.first)
    #expect(stage.rawValue == "minutes")
    for known in [PostProcessingStage.transcript, .render, .diarize, .align, .recognize, .export] {
        #expect(stage != known)
    }
    #expect(String(decoding: try HolosJSON.encoder(pretty: false).encode(stages), as: UTF8.self) == #"["minutes"]"#)

    let reasons = try HolosJSON.decoder().decode([StopReason].self, from: Data(#"["x"]"#.utf8))
    let reason = try #require(reasons.first)
    #expect(reason.rawValue == "x")
    for known in [StopReason.requested, .signal, .duration, .diskLow, .sleepTimeout, .captureFailed,
                  .startFailed, .pauseTimeout, .interrupted] {
        #expect(reason != known)
    }
    #expect(String(decoding: try HolosJSON.encoder(pretty: false).encode(reasons), as: UTF8.self) == #"["x"]"#)
}

@Test func unknownPhaseIsActive() throws {
    let phases = try HolosJSON.decoder().decode([RecorderPhase].self, from: Data(#"["fancyNew"]"#.utf8))
    #expect(phases == [.unknown])
    #expect(RecorderPhase.unknown.isMeetingActive)
}

@Test func floatVectorRoundTripsBitExactly() throws {
    let values: [Float] = [1, -0.0, .nan, 3.5, Float(bitPattern: 0x7FC0_1234), .infinity, -.leastNonzeroMagnitude]
    let encoded = try HolosJSON.encoder().encode([FloatVector(values)])
    let decoded = try HolosJSON.decoder().decode([FloatVector].self, from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded.first?.values.map(\.bitPattern) == values.map(\.bitPattern))
}

@Test func floatVectorRejectsBadBase64() {
    #expect(throws: DecodingError.self) {
        try HolosJSON.decoder().decode([FloatVector].self, from: Data(#"["abc"]"#.utf8))
    }
    // Valid base64 whose length is not a whole number of Float32 values.
    #expect(throws: DecodingError.self) {
        try HolosJSON.decoder().decode([FloatVector].self, from: Data(#"["AAAA"]"#.utf8))
    }
}

@Test func contractExamplesRoundTrip() throws {
    try expectRoundTrip(MeetingInfo.self, meetingExample)
    try expectRoundTrip(MeetingVocabulary.self, vocabularyExample)
    try expectRoundTrip(ControlRequest.self, controlExample)
    try expectRoundTrip(RecorderStatus.self, recordingStatusExample)
    try expectRoundTrip(RecorderStatus.self, exitedStatusExample)
    try expectRoundTrip(PostProcessingRecord.self, postprocessExample)
    try expectRoundTrip(SpeakerHead.self, headExample)
    try expectRoundTrip(DiarizationRun.self, runExample)
    try expectRoundTrip(SessionVoiceData.self, voiceExample)
    try expectRoundTrip(RecognitionResult.self, recognitionExample)

    let lines = editsExample.split(separator: "\n").map(String.init)
    #expect(lines.count == 4)
    for line in lines {
        let edit = try HolosJSON.decoder().decode(SpeakerEdit.self, from: Data(line.utf8))
        #expect(String(decoding: try HolosJSON.line(edit), as: UTF8.self) == line + "\n")
    }

    let run = try HolosJSON.decoder().decode(DiarizationRun.self, from: Data(runExample.utf8))
    #expect(run.speakers.first?.provenance == .channelAssumption)
    #expect(run.tracks.first?.policy == .channel(speakerID: "mic:me", displayName: "Me"))
    let voice = try HolosJSON.decoder().decode(SessionVoiceData.self, from: Data(voiceExample.utf8))
    #expect(voice.centroids["system:S1"]?.count == 2)
}

private func expectRoundTrip<T: Codable & Equatable>(_ type: T.Type, _ text: String,
                                                     sourceLocation: SourceLocation = #_sourceLocation) throws {
    let value = try HolosJSON.decoder().decode(type, from: Data(text.utf8))
    let encoded = String(decoding: try HolosJSON.encoder().encode(value), as: UTF8.self)
    #expect(encoded == text, "\(T.self) does not re-encode to the §3.4 example", sourceLocation: sourceLocation)
    #expect(try HolosJSON.decoder().decode(type, from: Data(encoded.utf8)) == value, sourceLocation: sourceLocation)
}

// MARK: - §3.4 examples

/// §3.4 meeting.json
private let meetingExample = #"""
{
  "applicationBundleID" : "us.zoom.xos",
  "createdAt" : "2026-09-23T14:00:00Z",
  "mode" : "call",
  "origin" : "recorded",
  "othersInRoom" : false,
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10"
}
"""#

/// §3.4 vocabulary.json
private let vocabularyExample = #"""
{
  "schemaVersion" : 1,
  "strings" : [
    "Maria Chen",
    "strata",
    "bylaw 12"
  ]
}
"""#

/// §3.4 control/7C0E….json (marker)
private let controlExample = #"""
{
  "command" : "marker",
  "createdAt" : "2026-09-23T15:02:03Z",
  "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
  "label" : "Budget vote",
  "schemaVersion" : 1,
  "sender" : "app",
  "sentAtNanos" : 912345678901234,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10"
}
"""#

/// §3.4 status.json (recording)
private let recordingStatusExample = #"""
{
  "bytesWritten" : 715000000,
  "elapsedSeconds" : 3723.6,
  "freeBytes" : 22800000000,
  "handledRequests" : [
    {
      "command" : "marker",
      "handledAt" : "2026-09-23T15:02:03Z",
      "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
      "result" : "applied"
    }
  ],
  "lastPhrase" : "…",
  "markers" : 1,
  "microphoneName" : "AirPods Pro",
  "name" : "Council meeting",
  "phase" : "recording",
  "pid" : 48211,
  "recordedSeconds" : 3601.2,
  "schemaVersion" : 1,
  "sequence" : 3724,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "source" : "mic+system",
  "startedAt" : "2026-09-23T14:00:00Z",
  "tracks" : [
    {
      "backlogSeconds" : 0.2,
      "channels" : 1,
      "lastFinalizedSeconds" : 3719.8,
      "lastFrameSeconds" : 3723.5,
      "sampleRate" : 48000,
      "stalled" : false,
      "track" : "mic",
      "transcription" : "live"
    },
    {
      "backlogSeconds" : 0.1,
      "channels" : 1,
      "lastFinalizedSeconds" : 2410,
      "lastFrameSeconds" : 3723.4,
      "sampleRate" : 48000,
      "stalled" : false,
      "track" : "system",
      "transcription" : "behind"
    }
  ],
  "updatedAt" : "2026-09-23T15:02:04Z",
  "warnings" : [
    {
      "code" : "transcriptionBehind",
      "message" : "System audio transcription is behind; it will finish after you stop.",
      "since" : "2026-09-23T14:40:11Z"
    }
  ]
}
"""#

/// §3.4 status.json (exited)
private let exitedStatusExample = #"""
{
  "bytesWritten" : 2072000000,
  "elapsedSeconds" : 10795.2,
  "exit" : {
    "archiveStatus" : "complete",
    "postprocessing" : "succeeded",
    "reason" : "requested"
  },
  "freeBytes" : 21400000000,
  "handledRequests" : [
    {
      "command" : "marker",
      "handledAt" : "2026-09-23T15:02:03Z",
      "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
      "result" : "applied"
    }
  ],
  "markers" : 1,
  "microphoneName" : "AirPods Pro",
  "name" : "Council meeting",
  "phase" : "exited",
  "pid" : 48211,
  "recordedSeconds" : 10790,
  "schemaVersion" : 1,
  "sequence" : 11020,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "source" : "mic+system",
  "startedAt" : "2026-09-23T14:00:00Z",
  "tracks" : [

  ],
  "updatedAt" : "2026-09-23T17:03:40Z",
  "warnings" : [

  ]
}
"""#

/// §3.4 postprocess.json (running)
private let postprocessExample = #"""
{
  "othersInRoom" : false,
  "pid" : 48211,
  "progress" : {
    "fraction" : 0.42,
    "message" : "Labelling speakers (system audio)…",
    "stage" : "diarize",
    "track" : "system"
  },
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "stages" : [
    {
      "result" : "succeeded",
      "seconds" : 0.4,
      "stage" : "transcript"
    },
    {
      "result" : "succeeded",
      "seconds" : 21.7,
      "stage" : "render"
    }
  ],
  "startedAt" : "2026-09-23T17:00:00Z",
  "state" : "running",
  "transcriptID" : "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A",
  "updatedAt" : "2026-09-23T17:00:40Z"
}
"""#

/// §3.4 speakers/head.json
private let headExample = #"""
{
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "updatedAt" : "2026-09-23T17:01:40Z"
}
"""#

/// §3.4 speakers/runs/5C1D….json (no voice embeddings)
private let runExample = #"""
{
  "alignment" : {
    "parameters" : {
      "echoMinRunWords" : 3,
      "flickerBoundarySeconds" : 0.3,
      "flickerMaxGapSeconds" : 0.25,
      "flickerMaxSeconds" : 0.4,
      "flickerMaxWords" : 2,
      "flickerMinOwnSegmentSeconds" : 0.3,
      "gapSnapSeconds" : 0.5,
      "offsetSearchSeconds" : 0.5,
      "offsetStepSeconds" : 0.02,
      "overlapMinFraction" : 0.5,
      "overlapMinSeconds" : 0.1,
      "turnPauseSeconds" : 1.5
    },
    "trackOffsets" : {
      "system" : 0.06
    },
    "version" : 1
  },
  "createdAt" : "2026-09-23T17:01:40Z",
  "droppedWords" : [

  ],
  "engine" : {
    "configuration" : {
      "clusteringThreshold" : "0.6",
      "exclusiveSegments" : "false",
      "exposeChunkEmbeddings" : "true"
    },
    "embeddingDimension" : 256,
    "embeddingModel" : {
      "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
      "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    },
    "engine" : "FluidAudio.OfflineDiarizerManager",
    "engineVersion" : "0.17.1",
    "models" : [
      {
        "id" : "FluidInference/speaker-diarization-coreml",
        "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        "sha256" : "<tree digest>"
      }
    ]
  },
  "id" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "speakers" : [
    {
      "clusterIDs" : [

      ],
      "displayName" : "Me",
      "id" : "mic:me",
      "ordinal" : 1,
      "provenance" : {
        "channelAssumption" : {

        }
      }
    },
    {
      "clusterIDs" : [
        "system:S1"
      ],
      "id" : "system:S1",
      "ordinal" : 2,
      "provenance" : {
        "diarizer" : {

        }
      }
    },
    {
      "clusterIDs" : [
        "system:S2"
      ],
      "id" : "system:S2",
      "ordinal" : 3,
      "provenance" : {
        "diarizer" : {

        }
      }
    }
  ],
  "tracks" : [
    {
      "clusters" : [

      ],
      "policy" : {
        "channel" : {
          "displayName" : "Me",
          "speakerID" : "mic:me"
        }
      },
      "segments" : [

      ],
      "track" : "mic"
    },
    {
      "clusters" : [
        {
          "clusterID" : "system:S1",
          "speechSeconds" : 2472.3,
          "track" : "system"
        },
        {
          "clusterID" : "system:S2",
          "speechSeconds" : 1323,
          "track" : "system"
        }
      ],
      "policy" : {
        "diarized" : {

        }
      },
      "segments" : [
        {
          "clusterID" : "system:S1",
          "end" : 19.4,
          "overlapCount" : 0,
          "quality" : 0.91,
          "start" : 12,
          "track" : "system"
        },
        {
          "clusterID" : "system:S2",
          "end" : 25,
          "overlapCount" : 1,
          "quality" : 0.84,
          "start" : 18.9,
          "track" : "system"
        }
      ],
      "track" : "system"
    }
  ],
  "transcriptID" : "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A",
  "turns" : [
    {
      "assignmentScore" : 0.97,
      "clusterID" : "system:S1",
      "end" : 18.7,
      "id" : "T1",
      "otherClusters" : [

      ],
      "overlap" : false,
      "spans" : [
        {
          "end" : 17,
          "first" : 0,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000001"
        }
      ],
      "speakerID" : "system:S1",
      "start" : 12.1,
      "timing" : "measured",
      "track" : "system"
    },
    {
      "assignmentScore" : 0.88,
      "clusterID" : "system:S2",
      "end" : 24.8,
      "id" : "T2",
      "otherClusters" : [
        "system:S1"
      ],
      "overlap" : true,
      "spans" : [
        {
          "end" : 21,
          "first" : 17,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000001"
        },
        {
          "end" : 9,
          "first" : 0,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000002"
        }
      ],
      "speakerID" : "system:S2",
      "start" : 19,
      "timing" : "measured",
      "track" : "system"
    }
  ]
}
"""#

/// §3.4 speakers/voice/5C1D….json (only while Remember voices is on; 2-d vectors shown, real ones are 256-d)
private let voiceExample = #"""
{
  "centroids" : {
    "system:S1" : "fPKwPbN78rw=",
    "system:S2" : "CtejPK5H4T0="
  },
  "createdAt" : "2026-09-23T17:01:40Z",
  "embeddingModel" : {
    "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
    "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
  },
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "turnEmbeddings" : [
    {
      "speechSeconds" : 6.6,
      "turnID" : "T1",
      "vector" : "uB4FPgrXo7w="
    }
  ]
}
"""#

/// §3.4 speakers/recognition/5C1D….json
private let recognitionExample = #"""
{
  "createdAt" : "2026-09-23T17:01:41Z",
  "embeddingModel" : {
    "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
    "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
  },
  "matches" : [
    {
      "distance" : 0.21,
      "profileID" : "D4C3B2A1-1111-4222-8333-944455566677",
      "profileName" : "Jim",
      "speakerID" : "system:S1",
      "tier" : "possible"
    },
    {
      "distance" : 0.33,
      "profileID" : "E5F6A7B8-1111-4222-8333-944455566677",
      "profileName" : "Maria",
      "speakerID" : "system:S2",
      "tier" : "possible"
    }
  ],
  "mergeSuggestions" : [

  ],
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "skippedProfiles" : [

  ],
  "thresholds" : {
    "likelyMaxDistance" : 0,
    "likelyMinMargin" : 0.1,
    "minSampleSeconds" : 20,
    "possibleMaxDistance" : 0.4
  }
}
"""#

/// §3.4 speakers/edits.jsonl (four lines: one two-line batch, then two single edits)
private let editsExample = #"""
{"action":{"linkProfile":{"profileID":"E5F6A7B8-1111-4222-8333-944455566677","speakerID":"system:S2"}},"at":"2026-09-23T17:11:40Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","expected":"","id":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","schemaVersion":1,"source":"app"}
{"action":{"rename":{"name":"Maria","speakerID":"system:S2"}},"at":"2026-09-23T17:11:40Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","expected":"","id":"0B1C2D3E-4F50-4162-8374-95A6B7C8D9EA","schemaVersion":1,"source":"app"}
{"action":{"reassignTurns":{"to":"system:S1","turnIDs":["T7","T9"]}},"at":"2026-09-23T17:12:00Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"1B2C3D4E-5F60-4172-8384-95A6B7C8D9EA","expected":"system:S2,system:S2","id":"1B2C3D4E-5F60-4172-8384-95A6B7C8D9EA","schemaVersion":1,"source":"cli"}
{"action":{"splitTurn":{"at":{"segmentID":"A1B2C3D4-0000-4000-8000-000000000031","word":6},"turnID":"T12"}},"at":"2026-09-23T17:12:20Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"2C3D4E5F-6071-4283-9495-A6B7C8D9EAFB","id":"2C3D4E5F-6071-4283-9495-A6B7C8D9EAFB","schemaVersion":1,"source":"app"}
"""#
