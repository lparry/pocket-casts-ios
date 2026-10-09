import AVFoundation
import Foundation
import Speech

/// Turns a local audio file into timestamped transcript lines
protocol EpisodeTranscriber {
    func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment]
}

/// Transcribes on device with `SpeechAnalyzer` and `SpeechTranscriber`
@available(iOS 26, *)
struct SpeechAnalyzerTranscriber: EpisodeTranscriber {
    /// Split long results so the classifier can place ad boundaries more precisely
    private let maxSegmentDuration: TimeInterval = 15

    @concurrent
    func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
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
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let maxSegmentDuration = maxSegmentDuration
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                segments.append(contentsOf: Self.segments(from: result, maxDuration: maxSegmentDuration))
            }
            return segments
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        return try await collector.value
    }

    /// Splits a result into sentences using the per-word time ranges, falling back to the whole result
    private static func segments(from result: SpeechTranscriber.Result, maxDuration: TimeInterval) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var text = ""
        var start: TimeInterval?
        var end: TimeInterval?

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let start, let end {
                segments.append(TranscriptSegment(start: start, end: end, text: trimmed))
            }
            text = ""
            start = nil
            end = nil
        }

        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            if let timeRange = run.audioTimeRange {
                if start == nil {
                    start = timeRange.start.seconds
                }
                end = timeRange.end.seconds
            }
            text += piece

            let endsSentence = piece.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false
            let tooLong = (end ?? 0) - (start ?? 0) >= maxDuration
            if endsSentence || tooLong {
                flush()
            }
        }
        flush()

        if segments.isEmpty {
            let wholeText = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !wholeText.isEmpty {
                segments.append(TranscriptSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: wholeText))
            }
        }

        return segments
    }
}
