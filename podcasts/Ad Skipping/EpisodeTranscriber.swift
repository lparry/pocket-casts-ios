import AVFoundation
import Foundation
import os
import Speech

/// Turns a local audio file into timestamped transcript lines
protocol EpisodeTranscriber {
    /// `progress` is called with how far through the audio the transcript has got, from 0 to 1
    func transcribe(fileURL: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment]
}

/// `SpeechAnalyzer` keeps going when its task is cancelled, so a cancelled transcription used to run to the end anyway, and
/// then have its transcript thrown away. This stops the analysis when the task is cancelled, unless it has already finished.
enum CancellableAnalysis {
    private enum State {
        case running, finished, cancelled
    }

    /// Runs `analysis`, calling `cancel` if the task is cancelled before it finishes. Throws `CancellationError` if it was
    /// cancelled part way, since its results are incomplete, but returns normally if it finished before the cancellation.
    static func run(isolation: isolated (any Actor)? = #isolation,
                    _ analysis: () async throws -> Void,
                    cancel: @escaping @Sendable () async -> Void) async throws {
        let state = OSAllocatedUnfairLock(initialState: State.running)

        try await withTaskCancellationHandler {
            do {
                try await analysis()
            } catch where state.withLock({ $0 == .cancelled }) {
                // Stopping the analysis can make it throw an error of its own
                throw CancellationError()
            }
        } onCancel: {
            let cancelling = state.withLock { state in
                guard state == .running else { return false }
                state = .cancelled
                return true
            }
            if cancelling {
                Task { await cancel() }
            }
        }

        let finished = state.withLock { state in
            guard state == .running else { return false }
            state = .finished
            return true
        }
        if !finished {
            throw CancellationError()
        }
    }
}

/// Transcribes on device with `SpeechAnalyzer` and `SpeechTranscriber`
@available(iOS 26, *)
struct SpeechAnalyzerTranscriber: EpisodeTranscriber {
    /// Keep lines short so the classifier can place ad boundaries precisely
    private let maxSegmentDuration: TimeInterval = 5

    @concurrent
    func transcribe(fileURL: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else {
            throw AdSkippingError.transcriptionUnavailable
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AdSkippingError.unsupportedLocale(locale)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        // Keep the model loaded between episodes, and don't let a background scan crawl
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))

        let maxSegmentDuration = maxSegmentDuration
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                segments.append(contentsOf: Self.segments(from: result, maxDuration: maxSegmentDuration))
                if audioDuration > 0 {
                    progress(min(1, result.range.end.seconds / audioDuration))
                }
            }
            return segments
        }

        do {
            try await CancellableAnalysis.run {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } cancel: {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        return try await collector.value
    }

    /// Pulls the timed words out of a result, falling back to one line for the whole result when it has no word timings
    private static func segments(from result: SpeechTranscriber.Result, maxDuration: TimeInterval) -> [TranscriptSegment] {
        var words: [TimedWord] = []

        for run in result.text.runs {
            let piece = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }

            if let timeRange = run.audioTimeRange {
                words.append(TimedWord(start: timeRange.start.seconds, end: timeRange.end.seconds, text: piece))
            } else if let last = words.last {
                // Punctuation can come without a time of its own, so it joins the word before it
                words[words.count - 1] = TimedWord(start: last.start, end: last.end, text: last.text + piece)
            }
        }

        if !words.isEmpty {
            return TranscriptSegment.lines(from: words, maxDuration: maxDuration)
        }

        let wholeText = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wholeText.isEmpty else { return [] }
        return [TranscriptSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: wholeText)]
    }
}
