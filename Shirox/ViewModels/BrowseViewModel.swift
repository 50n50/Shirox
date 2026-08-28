import Foundation
import Combine

@MainActor
final class BrowseViewModel: ObservableObject {
    let category: BrowseCategory

    @Published var items: [Media] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasMore = true

    private var currentPage = 0
    private var cancellables = Set<AnyCancellable>()

    init(category: BrowseCategory) {
        self.category = category
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reset() }
            }
            .store(in: &cancellables)
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        let nextPage = currentPage + 1
        do {
            let newItems = try await ProviderManager.shared.call { try await $0.browse(category: self.category, page: nextPage) }
            var seen = Set(items.map(\.uniqueId))
            let deduped = newItems.filter { seen.insert($0.uniqueId).inserted }
            items.append(contentsOf: deduped)
            currentPage = nextPage
            if newItems.count < 20 { hasMore = false }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Backs both the error-state Retry button and pull-to-refresh, so it must start over rather
    /// than continue paging: it previously left `currentPage` and `items` untouched, so pulling to
    /// refresh a populated grid just appended the *next* page to the bottom instead of reloading.
    func retry() async {
        await reset()
    }

    private func reset() async {
        items = []
        currentPage = 0
        hasMore = true
        error = nil
        await loadMore()
    }
}
