import Accelerate
import AVFoundation
import Foundation
import PocketCastsUtils

/// Moves each ad's edges onto the exact first and last word, by showing the classifier the words around each edge
struct AdBoundaryRefiner {
    /// How far either side of an edge to show the classifier
    static let windowRadius: TimeInterval = 15

    let classifier: AdClassifier

    func refine(_ spans: [AdSpan], words: [TimedWord], context: AdClassificationContext) async -> [AdSpan] {
        let requests = spans.flatMap { span in
            [AdBoundaryEdge.start, .end].map { edge in
                AdBoundaryRequest(edge: edge, ad: span, words: Self.window(around: edge == .start ? span.start : span.end, in: words), context: context)
            }
        }
        let askable = requests.filter { !$0.words.isEmpty }
        guard !askable.isEmpty else { return spans }

        let answers: [Int?]
        do {
            answers = try await classifier.boundaryWordIndices(for: askable)
        } catch {
            FileLog.shared.addMessage("AdBoundaryRefiner: couldn't refine \(spans.count) ads: \(error)")
            return spans
        }

        // Look up each answer by its request, since requests without words weren't asked
        var times: [Int: TimeInterval] = [:]
        var askedIndex = 0
        for (index, request) in requests.enumerated() where !request.words.isEmpty {
            if askedIndex < answers.count {
                times[index] = Self.time(of: request.edge, wordAt: answers[askedIndex], in: request.words)
            }
            askedIndex += 1
        }

        return spans.enumerated().map { index, span in
            let start = times[index * 2] ?? span.start
            let end = times[index * 2 + 1] ?? span.end
            // Keep the original if the refined edges don't make sense together
            return end > start ? AdSpan(start: start, end: end, kind: span.kind, sponsor: span.sponsor) : span
        }
    }

    static func window(around time: TimeInterval, in words: [TimedWord]) -> [TimedWord] {
        words.filter { $0.end >= time - windowRadius && $0.start <= time + windowRadius }
    }

    /// An ad starts as its first word starts and ends as its last word ends
    static func time(of edge: AdBoundaryEdge, wordAt index: Int?, in window: [TimedWord]) -> TimeInterval? {
        guard let index, window.indices.contains(index) else { return nil }
        return edge == .start ? window[index].start : window[index].end
    }
}

/// Widens each ad onto a nearby silence, or failing that a sudden change in loudness, in the audio itself.
/// Ads are often wrapped in a jingle or a fade that has no words to place an edge on.
///
/// Edges only ever move outwards, so no more of the ad plays, and never past the show's neighbouring words.
enum AudioBoundarySnapper {
    /// How far an edge can move
    static let searchRadius: TimeInterval = 2
    /// The length of each loudness measurement
    static let blockDuration: TimeInterval = 0.02

    @concurrent
    static func snap(_ spans: [AdSpan], words: [TimedWord], fileURL: URL) async -> [AdSpan] {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return spans }

        return spans.map { span in
            let start = snappedTime(near: span.start, allowed: startRange(for: span, words: words), in: file) ?? span.start
            let end = snappedTime(near: span.end, allowed: endRange(for: span, words: words), in: file) ?? span.end
            return AdSpan(start: start, end: end, kind: span.kind, sponsor: span.sponsor)
        }
    }

    /// From the end of the word before the ad, or the search radius, up to the ad's start
    static func startRange(for span: AdSpan, words: [TimedWord]) -> ClosedRange<TimeInterval> {
        let previousWordEnd = words.last { $0.end <= span.start }?.end ?? 0
        return max(previousWordEnd, span.start - searchRadius)...span.start
    }

    /// From the ad's end up to the start of the word after it, or the search radius
    static func endRange(for span: AdSpan, words: [TimedWord]) -> ClosedRange<TimeInterval> {
        let nextWordStart = words.first { $0.start >= span.end }?.start ?? .greatestFiniteMagnitude
        return span.end...min(nextWordStart, span.end + searchRadius)
    }

    private static func snappedTime(near time: TimeInterval, allowed: ClosedRange<TimeInterval>, in file: AVAudioFile) -> TimeInterval? {
        // Measure the whole neighbourhood, so silence is judged against the audio around it
        let levelsStart = max(0, time - searchRadius)
        guard allowed.upperBound > allowed.lowerBound, let levels = levels(in: file, from: levelsStart, to: time + searchRadius) else { return nil }
        return snappedTime(near: time, allowed: allowed, levels: levels, levelsStart: levelsStart)
    }

    /// The loudness of each block between `start` and `end`, in dBFS
    private static func levels(in file: AVAudioFile, from start: TimeInterval, to end: TimeInterval) -> [Float]? {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(start * sampleRate)
        guard startFrame < file.length else { return nil }

        let frameCount = AVAudioFrameCount(min(Double(file.length - startFrame), (end - start) * sampleRate))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return nil }

        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            return nil
        }

        guard let channels = buffer.floatChannelData else { return nil }

        let blockLength = max(1, Int(blockDuration * sampleRate))
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        return stride(from: 0, to: frames - blockLength + 1, by: blockLength).map { offset in
            var total: Float = 0
            for channel in 0..<channelCount {
                var rms: Float = 0
                vDSP_rmsqv(channels[channel] + offset, 1, &rms, vDSP_Length(blockLength))
                total += rms
            }
            let rms = total / Float(channelCount)
            return 20 * log10(max(rms, 1e-7))
        }
    }

    /// Where to move an edge at `time`, given the loudness of each block from `levelsStart`, or nil to leave it alone.
    /// Prefers the middle of the nearest silence of at least 100ms, then the nearest jump of at least 12dB between
    /// 100ms stretches, as long as it's within `allowed`.
    static func snappedTime(near time: TimeInterval, allowed: ClosedRange<TimeInterval>, levels: [Float], levelsStart: TimeInterval, blockDuration: TimeInterval = blockDuration) -> TimeInterval? {
        guard !levels.isEmpty else { return nil }

        func nearest(_ candidates: [TimeInterval]) -> TimeInterval? {
            candidates
                .filter { allowed.contains($0) }
                .min { abs($0 - time) < abs($1 - time) }
        }

        // Silence is quiet in absolute terms, as well as compared with what's around it
        let median = levels.sorted()[levels.count / 2]
        let silenceThreshold = min(median - 20, -45)
        let minimumSilentBlocks = max(1, Int((0.1 / blockDuration).rounded()))

        var silences: [TimeInterval] = []
        var runStart: Int?
        for (index, level) in levels.enumerated() + [(levels.count, Float.greatestFiniteMagnitude)] {
            if level <= silenceThreshold {
                runStart = runStart ?? index
            } else if let start = runStart {
                if index - start >= minimumSilentBlocks {
                    silences.append(levelsStart + (Double(start + index) / 2) * blockDuration)
                }
                runStart = nil
            }
        }

        if let silence = nearest(silences) {
            return silence
        }

        // Average the blocks into 100ms stretches and look for a sudden jump
        let stretchLength = minimumSilentBlocks
        let stretches = stride(from: 0, to: levels.count - stretchLength + 1, by: stretchLength).map { offset in
            levels[offset..<offset + stretchLength].reduce(0, +) / Float(stretchLength)
        }
        let jumps = stretches.indices.dropFirst().compactMap { index -> TimeInterval? in
            abs(stretches[index] - stretches[index - 1]) >= 12 ? levelsStart + Double(index * stretchLength) * blockDuration : nil
        }

        return nearest(jumps)
    }
}
