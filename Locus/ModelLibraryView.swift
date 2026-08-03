import SwiftUI

@MainActor
final class ModelLibraryViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [HuggingFaceModel] = []
    @Published var selectedModel: HuggingFaceModel?
    @Published var variants: [HuggingFaceVariant] = []
    @Published var selectedVariant: HuggingFaceVariant?
    /// The quantization the RAM-aware selection picked, for the badge.
    @Published var recommendedQuant: String?
    @Published var isSearching = false
    @Published var isLoadingVariants = false
    @Published var isDownloading = false
    @Published var progress: ModelPullProgress?
    @Published var errorMessage: String?
    @Published var installedReference: String?

    private let service = ModelLibraryService()
    private var searchTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var didLoad = false
    // Generation counters so a stale search/selection that finishes late can
    // never clobber the state of the one the user is actually looking at.
    private var searchGeneration = 0
    private var selectGeneration = 0

    func loadInitial() async {
        guard !didLoad else { return }
        didLoad = true
        search()
    }

    func search() {
        searchTask?.cancel()
        searchTask = Task { await performSearch() }
    }

    func openRepositoryFromQuery() {
        let repository = service.normalizeRepository(query)
        guard repository.split(separator: "/").count == 2 else {
            errorMessage = ModelLibraryError.invalidRepository.localizedDescription
            return
        }
        // Select without inserting a fabricated row — if the repository does
        // not exist, the variants scan reports it and no phantom result stays.
        let model = results.first {
            $0.id.caseInsensitiveCompare(repository) == .orderedSame
        } ?? HuggingFaceModel(
            id: repository,
            downloads: nil,
            likes: nil,
            lastModified: nil,
            tags: ["gguf"]
        )
        select(model)
    }

    func select(_ model: HuggingFaceModel) {
        selectGeneration += 1
        let generation = selectGeneration
        selectedModel = model
        selectedVariant = nil
        variants = []
        recommendedQuant = nil
        errorMessage = nil
        isLoadingVariants = true
        Task {
            do {
                let loaded = try await service.variants(for: model.id)
                guard generation == selectGeneration else { return }
                variants = loaded
                // RAM-aware, not just "Q4_K_M": pre-selecting a quant that
                // cannot fit this Mac is how a 22 GB model ends up starving
                // a 32 GB machine.
                let recommended = HuggingFaceVariant.recommendedVariant(
                    in: loaded,
                    physicalMemory: ProcessInfo.processInfo.physicalMemory
                )
                recommendedQuant = recommended?.quantization
                selectedVariant = recommended ?? loaded.first
            } catch {
                guard generation == selectGeneration else { return }
                errorMessage = error.localizedDescription
            }
            if generation == selectGeneration {
                isLoadingVariants = false
            }
        }
    }

    func download(
        ollamaHost: String,
        onInstalled: @escaping @MainActor (String) async -> Void
    ) {
        guard let model = selectedModel, let variant = selectedVariant else { return }
        guard !isDownloading else { return }
        errorMessage = nil
        installedReference = nil
        progress = ModelPullProgress(status: "Preparing download", completed: 0, total: 0)
        isDownloading = true
        downloadTask = Task {
            do {
                let reference = try await service.pull(
                    repository: model.id,
                    quantization: variant.quantization,
                    ollamaHost: ollamaHost
                ) { [weak self] update in
                    Task { @MainActor in self?.progress = update }
                }
                installedReference = reference
                progress = ModelPullProgress(status: "Installed", completed: 1, total: 1)
                isDownloading = false
                await onInstalled(reference)
            } catch {
                if error.isCancellation {
                    progress = ModelPullProgress(status: "Download cancelled", completed: 0, total: 0)
                } else {
                    errorMessage = error.localizedDescription
                }
                isDownloading = false
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if isDownloading {
            progress = ModelPullProgress(status: "Download cancelled", completed: 0, total: 0)
            isDownloading = false
        }
    }

    private func performSearch() async {
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        errorMessage = nil
        do {
            let found = try await service.search(query: query)
            guard generation == searchGeneration else { return }
            results = found
            if let current = selectedModel,
               found.contains(where: { $0.id == current.id })
            {
                selectedModel = current
            } else if let first = found.first {
                select(first)
            }
        } catch {
            guard generation == searchGeneration else { return }
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
        }
        if generation == searchGeneration {
            isSearching = false
        }
    }
}

private extension Error {
    /// Swift cancellation surfaces as CancellationError from Task APIs but as
    /// URLError(.cancelled) from URLSession — treat both as "cancelled".
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

struct ModelLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = ModelLibraryViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Rectangle().fill(LocusTheme.line).frame(height: 1)

            HStack(spacing: 0) {
                resultList
                    .frame(width: 300)
                Rectangle().fill(LocusTheme.line).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 620)
        .background(LocusTheme.panel)
        .task { await library.loadInitial() }
        .onDisappear { library.cancelDownload() }
        .onExitCommand {
            dismiss()
            model.modelLibraryPresented = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LocusTheme.signal.opacity(0.15))
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("Local Model Library")
                    .font(.system(size: 18, weight: .bold))
                Text("Discover GGUF models on Hugging Face and install them through Ollama.")
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)
            }

            Spacer()

            if model.isModelOnline {
                Label("Ollama ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.success)
            } else {
                Label("Ollama unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.coral)
            }

            Button {
                dismiss()
                model.modelLibraryPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close model library")
            .accessibilityIdentifier("modelLibrary.close")
        }
        .padding(18)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LocusTheme.muted)
            TextField(
                "Search models or paste a huggingface.co model URL",
                text: $library.query
            )
            .textFieldStyle(.plain)
            .onSubmit { library.search() }
            .accessibilityIdentifier("modelLibrary.search")

            if library.isSearching {
                ProgressView().controlSize(.small)
            }

            Button("Open Repository") { library.openRepositoryFromQuery() }
                .buttonStyle(.bordered)
                .disabled(library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("modelLibrary.openRepository")

            Button("Search") { library.search() }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .accessibilityIdentifier("modelLibrary.searchButton")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(library.query.isEmpty ? "POPULAR GGUF MODELS" : "SEARCH RESULTS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                Text("\(library.results.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(library.results) { item in
                        Button { library.select(item) } label: {
                            modelRow(item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("modelLibrary.result.\(item.id)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background(LocusTheme.white.opacity(0.55))
    }

    private func modelRow(_ item: HuggingFaceModel) -> some View {
        let selected = library.selectedModel?.id == item.id
        return VStack(alignment: .leading, spacing: 5) {
            Text(item.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.ink)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(item.owner)
                if let downloads = item.downloads {
                    Label(downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down")
                }
                if let likes = item.likes {
                    Label(likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(LocusTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selected ? LocusTheme.signal.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? LocusTheme.signalDeep.opacity(0.25) : Color.clear, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = library.selectedModel {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected.displayName)
                            .font(.system(size: 19, weight: .bold))
                            .textSelection(.enabled)
                        Text(selected.id)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                            .textSelection(.enabled)
                    }

                    if library.isLoadingVariants {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Scanning GGUF files…")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                    } else {
                        variants
                    }

                    if let error = library.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(LocusTheme.coral)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LocusTheme.coral.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }

                    downloadPanel
                }
                .padding(24)
            }
        } else {
            ContentUnavailableView(
                "Choose a model",
                systemImage: "shippingbox",
                description: Text("Search Hugging Face or select a popular GGUF model.")
            )
        }
    }

    private var variants: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CHOOSE A QUANTIZATION")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                Text("This Mac has \(Self.memoryLabel) of unified memory")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("modelLibrary.machineMemory")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 9)], spacing: 9) {
                ForEach(library.variants) { variant in
                    Button { library.selectedVariant = variant } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(variant.quantization)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                Spacer()
                                fitBadge(for: variant)
                            }
                            Text(variant.sizeLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(LocusTheme.muted)
                            Text(variant.fileName)
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted.opacity(0.75))
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        .padding(10)
                        .background(
                            library.selectedVariant == variant
                                ? LocusTheme.signal.opacity(0.13)
                                : LocusTheme.white
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    library.selectedVariant == variant
                                        ? LocusTheme.signalDeep.opacity(0.5)
                                        : LocusTheme.line,
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("modelLibrary.variant.\(variant.quantization)")
                }
            }
        }
    }

    private static let memoryLabel = ByteCountFormatter.string(
        fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
        countStyle: .memory
    )

    /// One honest badge per card: the RAM-aware recommendation when it truly
    /// fits, otherwise how tight this quant runs on this machine.
    @ViewBuilder
    private func fitBadge(for variant: HuggingFaceVariant) -> some View {
        let fit = variant.fit(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        if fit == .fits, variant.quantization == library.recommendedQuant {
            Text("RECOMMENDED")
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                .foregroundStyle(LocusTheme.signalDeep)
                .accessibilityLabel("Recommended for this Mac")
        } else if fit == .tight {
            Text("TIGHT FIT")
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                .foregroundStyle(LocusTheme.warning)
                .accessibilityLabel("Tight fit for this Mac's memory")
        } else if fit == .exceeds {
            Text("TOO LARGE")
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                .foregroundStyle(LocusTheme.coral)
                .accessibilityLabel("Too large for this Mac's memory")
        }
    }

    private var downloadPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = library.progress {
                HStack {
                    Text(progress.status.capitalized)
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    if let fraction = progress.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(LocusTheme.signalDeep)
                        .accessibilityIdentifier("modelLibrary.downloadProgress")
                } else if library.isDownloading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(downloadTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(downloadTitleColor)
                    Text(downloadCaption)
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if library.isDownloading {
                    Button("Cancel") { library.cancelDownload() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("modelLibrary.cancelDownload")
                } else {
                    Button("Download & Use") {
                        library.download(ollamaHost: model.ollamaHost) { reference in
                            await model.activateInstalledModel(reference)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(
                        library.selectedVariant == nil
                            || !model.isModelOnline
                            || library.isLoadingVariants
                    )
                    .accessibilityIdentifier("modelLibrary.download")
                }
            }
        }
        .padding(14)
        .locusCard(radius: 10)
    }

    /// The panel's copy tells the truth about the selected quant before the
    /// user commits to a multi-gigabyte download. Warned, not blocked: it is
    /// the user's machine.
    private var selectedFit: HuggingFaceVariant.MemoryFit? {
        library.selectedVariant?.fit(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    private var downloadTitle: String {
        switch selectedFit {
        case .exceeds: "Larger than this Mac can comfortably serve"
        case .tight: "A tight fit for this Mac"
        default: "Installed models remain local"
        }
    }

    private var downloadTitleColor: Color {
        switch selectedFit {
        case .exceeds: LocusTheme.coral
        case .tight: LocusTheme.warning
        default: LocusTheme.ink
        }
    }

    private var downloadCaption: String {
        switch selectedFit {
        case .exceeds:
            "This quantization may fail to load, or run very slowly with a "
                + "shrunken context window. A smaller quantization or model is safer."
        case .tight:
            "It will use most of this Mac's memory while loaded — expect memory "
                + "pressure and a limited context window."
        default:
            "Ollama stores the model and Locus adds it to the model picker."
        }
    }
}
