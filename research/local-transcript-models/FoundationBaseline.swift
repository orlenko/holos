import Darwin
import Foundation
import FoundationModels

private struct Fixture: Decodable, Sendable {
    struct Item: Decodable, Sendable { let id: String; let mode: String; let expected: String; let prompt: String }
    let system: String
    let items: [Item]
}

@main struct FoundationBaseline {
    static func emit(_ fields: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    }
    static func parse(_ text: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(value.keys) == ["choice"], let choice = value["choice"] as? String,
              ["keep", "replace"].contains(choice) else { return "invalid" }
        return choice
    }
    static func cpu(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    static func main() async throws {
        // A stalled synchronous availability lookup/native await must not leave a benchmark running indefinitely.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
            emit(["event": "hard_timeout", "seconds": 120]); exit(124)
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: FileHandle.standardInput.readDataToEndOfFile())
        emit(["event": "fixture_ready", "items": fixture.items.count])
        let job = Task.detached(priority: .utility) {
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            emit(["event": "checking_availability"])
            guard case .available = model.availability else {
                emit(["event": "unavailable", "reason": String(describing: model.availability)]); return
            }
            emit(["event": "baseline", "model": "Apple Foundation Models", "max_response_tokens": 64,
                  "sampling": "greedy", "context_size": model.contextSize])
            let started = ContinuousClock.now
            var consecutiveErrors = 0
            for item in fixture.items {
                // A conservative outer work budget; no assertion about the host's wall-clock performance.
                if started.duration(to: .now) > .seconds(120) || consecutiveErrors >= 3 { break }
                let session = LanguageModelSession(model: model, instructions: fixture.system)
                emit(["event": "begin", "case": item.id, "mode": item.mode])
                var before = rusage(); getrusage(RUSAGE_SELF, &before)
                let begin = ContinuousClock.now
                var choice = "error"
                do {
                    let response = try await session.respond(to: item.prompt,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64))
                    choice = parse(response.content)
                    consecutiveErrors = 0
                } catch { consecutiveErrors += 1 }
                var after = rusage(); getrusage(RUSAGE_SELF, &after)
                emit(["event": "decision", "case": item.id, "mode": item.mode, "choice": choice,
                      "correct": choice == item.expected,
                      "false_replacement": choice == "replace" && item.expected == "keep",
                      "seconds": seconds(begin.duration(to: .now)), "cpu_seconds": cpu(after) - cpu(before),
                      "peak_rss_bytes_macos": after.ru_maxrss])
                try? await Task.sleep(for: .seconds(2))
            }
        }
        await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }
}
