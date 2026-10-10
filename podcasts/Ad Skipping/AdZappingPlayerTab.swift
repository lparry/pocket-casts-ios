import Combine
import PocketCastsDataModel
import SwiftUI
import UIKit

/// The player's Ad Zapping tab, showing what was found in the playing episode
@MainActor
final class AdZappingPlayerTabController: PlayerItemViewController {
    private let controller = UIHostingController(rootView: AdZappingPlayerTab())

    override func loadView() {
        let view = UIStackView(arrangedSubviews: [controller.view])
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        controller.view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(controller)
        controller.didMove(toParent: self)
    }
}

/// Ad Zapping for the playing episode, updated as it's scanned and when the episode changes
struct AdZappingPlayerTab: View {
    @State private var episode = PlaybackManager.shared.currentEpisode

    var body: some View {
        ScrollView {
            if let episode {
                VStack(alignment: .leading, spacing: 16) {
                    AdZappingDetails(episode: episode, showsStatus: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                // A different episode has its own transcripts to read
                .id(episode.uuid)
            }
        }
        // The player is always dark
        .environment(\.colorScheme, .dark)
        .tint(Color(PlayerColorHelper.playerHighlightColor01(episode: episode)))
        .onReceive(NotificationCenter.default.publisher(for: Constants.Notifications.playbackTrackChanged)) { _ in
            episode = PlaybackManager.shared.currentEpisode
        }
        .onReceive(NotificationCenter.default.publisher(for: Constants.Notifications.episodeDownloaded)) { _ in
            // The playing episode's copy needs to know it's downloaded now
            episode = PlaybackManager.shared.currentEpisode.flatMap { DataManager.shared.findBaseEpisode(uuid: $0.uuid) }
        }
    }
}
