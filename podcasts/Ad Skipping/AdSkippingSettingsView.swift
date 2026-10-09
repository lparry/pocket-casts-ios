import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI

/// Where the listener sees how ads are found, picks which kinds to skip, and enters an OpenRouter key
struct AdSkippingSettingsView: View {
    @ObservedObject private var manager = AdSkippingManager.shared

    /// Shows the list of downloads and their scan states
    let showAdScanning: () -> Void

    @State private var apiKeyDraft = ""
    @State private var modelDraft = ""

    var body: some View {
        List {
            classifierSection
            kindsSection
            limitsSection
            openRouterSection
            Section {
                Button(L10n.adScanningTitle, action: showAdScanning)
            }
        }
        .miniPlayerSafeAreaInset()
        .onAppear {
            modelDraft = manager.openRouterModel
        }
        .onDisappear {
            manager.openRouterModel = modelDraft
        }
    }

    // MARK: - Classifier

    private var classifierSection: some View {
        Section {
            if let active = manager.classifiers.first {
                Text(L10n.adSkippingClassifierActive(Self.displayName(forClassifier: active.identifier)))
            } else {
                Text(AdSkippingError.noClassifier.localizedDescription)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.adSkippingClassifierFooter)
        }
    }

    // MARK: - Kinds

    private var kindsSection: some View {
        Section {
            ForEach(AdSpan.Kind.allCases, id: \.self) { kind in
                Toggle(kind.displayName, isOn: Binding(
                    get: { manager.skippedKinds.contains(kind) },
                    set: { manager.setSkipping(kind, $0) }
                ))
            }
        } header: {
            Text(L10n.adSkippingKindsHeader)
        } footer: {
            Text(L10n.adSkippingKindsFooter)
        }
    }

    // MARK: - Limits

    private var limitsSection: some View {
        Section {
            Picker(L10n.adSkippingUpNextLimit, selection: Binding(
                get: { manager.upNextLimit ?? 0 },
                set: { manager.upNextLimit = $0 > 0 ? $0 : nil }
            )) {
                ForEach(AdSkippingManager.upNextLimitOptions, id: \.self) { limit in
                    Text(limit == 1 ? L10n.adSkippingUpNextLimitSingular : L10n.adSkippingUpNextLimitPlural(limit.localized()))
                        .tag(limit)
                }
                Text(L10n.adSkippingUpNextLimitAll)
                    .tag(0)
            }
        } header: {
            Text(L10n.adSkippingLimitsHeader)
        } footer: {
            Text(L10n.adSkippingLimitsFooter)
        }
    }

    // MARK: - OpenRouter

    private var openRouterSection: some View {
        Section {
            if manager.openRouterApiKey == nil {
                SecureField(L10n.adSkippingApiKeyPlaceholder, text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.adSkippingApiKeySave) {
                    manager.openRouterApiKey = apiKeyDraft
                    apiKeyDraft = ""
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(L10n.adSkippingApiKeySaved)
                Button(L10n.adSkippingApiKeyRemove, role: .destructive) {
                    manager.openRouterApiKey = nil
                }
            }

            LabeledContent(L10n.adSkippingModel) {
                TextField(OpenRouterAdClassifier.defaultModel, text: $modelDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        manager.openRouterModel = modelDraft
                        modelDraft = manager.openRouterModel
                    }
            }
        } header: {
            Text(L10n.adSkippingApiKeyHeader)
        } footer: {
            Text(L10n.adSkippingApiKeyFooter)
        }
    }

    static func displayName(forClassifier identifier: String) -> String {
        if identifier.hasPrefix(OpenRouterAdClassifier.identifierPrefix) {
            return L10n.adSkippingClassifierOpenrouter(String(identifier.dropFirst(OpenRouterAdClassifier.identifierPrefix.count)))
        }
        return L10n.adSkippingClassifierOnDevice
    }
}

extension AdSkippingManager.Status: CustomStringConvertible {
    var description: String {
        switch self {
        case .queued:
            L10n.adSkippingStatusQueued
        case .transcribing(let progress?, let timeLeft?):
            L10n.adSkippingStatusTranscribingTimeLeft(progress.localized(.percent), TimeFormatter.shared.playTimeFormat(time: timeLeft))
        case .transcribing(let progress?, nil):
            L10n.adSkippingStatusTranscribingProgress(progress.localized(.percent))
        case .transcribing:
            L10n.adSkippingStatusTranscribing
        case .classifying:
            L10n.adSkippingStatusClassifying
        case .finished(let adCount, let classifier):
            L10n.adSkippingStatusFinished(adCount.localized(), AdSkippingSettingsView.displayName(forClassifier: classifier))
        case .failed(let message):
            L10n.adSkippingStatusFailed(message)
        case .waitingForUpNext:
            L10n.adSkippingStatusWaitingForUpNext
        case .waitingForPower:
            L10n.adSkippingStatusWaitingForPower
        }
    }
}

extension AdSpan.Kind {
    var displayName: String {
        switch self {
        case .hostRead:
            L10n.adSkippingKindHostRead
        case .inserted:
            L10n.adSkippingKindInserted
        case .crossPromo:
            L10n.adSkippingKindCrossPromo
        case .selfPromo:
            L10n.adSkippingKindSelfPromo
        }
    }
}
