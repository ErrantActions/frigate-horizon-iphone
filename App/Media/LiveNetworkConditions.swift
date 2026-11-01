import Foundation
import Network
import Combine

@MainActor
final class LiveNetworkConditions: ObservableObject {
    static let shared = LiveNetworkConditions()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Horizon.live-network")
    @Published private(set) var restricted = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let restricted = path.status != .satisfied || path.isConstrained
            Task { @MainActor [weak self] in self?.restricted = restricted }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
