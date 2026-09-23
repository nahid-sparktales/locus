import AppKit
import EventKit
import SwiftUI

enum CalendarAccessState: Equatable {
    case notDetermined
    case denied
    case writeOnly
    case fullAccess

    var canRead: Bool { self == .fullAccess }
}

struct LocusCalendarEntry: Codable, Identifiable, Equatable {
    var id: String = "locus-event:" + UUID().uuidString
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool = false
    var location: String = ""
    var notes: String = ""
    var agentIDs: [UUID] = []
    var calendarID: String = "locus"
    var calendarTitle: String = "Locus Calendar"
    var account: String = "Built in"
    var writable: Bool = true
    var isLocal: Bool { calendarID == "locus" }
}

private struct LocusCalendarDocument: Codable {
    var version = 1
    var events: [LocusCalendarEntry] = []
    var externalAgentIDs: [String: [UUID]] = [:]
}

/// The built-in calendar and external overlays shared by the inspector and agent bridge.
/// Google and Microsoft accounts connected to macOS appear here automatically;
/// Locus never receives or stores their OAuth credentials.
@MainActor
final class LocusCalendarStore: ObservableObject {
    static let shared = LocusCalendarStore()

    @Published private(set) var accessState: CalendarAccessState = .notDetermined
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var events: [EKEvent] = []
    @Published var selectedDate = Date()
    @Published var displayedMonth = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())
    ) ?? Date()
    @Published var visibleCalendarIDs: Set<String> = []
    @Published var errorMessage: String?

    @Published private(set) var localEvents: [LocusCalendarEntry] = []
    @Published var showsLocalCalendar = true
    private var document = LocusCalendarDocument()
    private var localLoadError: Error?
    private let localFileURL: URL
    private let externalCalendarsEnabled: Bool
    private let eventStore: EKEventStore
    private var storeChangedObserver: NSObjectProtocol?
    private var hasInitializedVisibleCalendars = false

    init(eventStore: EKEventStore = EKEventStore(), applicationSupport: URL = NotesStore.applicationSupportDirectory, externalCalendarsEnabled: Bool = true) {
        self.externalCalendarsEnabled = externalCalendarsEnabled
        self.eventStore = eventStore
        localFileURL = applicationSupport.appendingPathComponent(AppEdition.current.displayName).appendingPathComponent("Calendar/events.json")
        if FileManager.default.fileExists(atPath: localFileURL.path) {
            do {
                document = try JSONDecoder().decode(LocusCalendarDocument.self, from: Data(contentsOf: localFileURL))
                guard document.version == 1 else { throw CalendarStoreError.unsupportedVersion }
                localEvents = document.events
            } catch { localLoadError = error; errorMessage = "Couldn’t load Locus Calendar: \(error.localizedDescription)" }
        }
        updateAccessState()
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if accessState.canRead { refresh() }
    }

    deinit {
        if let storeChangedObserver { NotificationCenter.default.removeObserver(storeChangedObserver) }
    }

    var writableCalendars: [EKCalendar] {
        calendars.filter(\.allowsContentModifications)
    }

    func requestAccess() async {
        guard externalCalendarsEnabled else { return }
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            updateAccessState()
            refresh()
            // macOS answers from its stored decision when it has one, so the
            // prompt never appears and the button looks dead. Say so instead.
            if !granted && accessState == .notDetermined {
                errorMessage = "macOS did not grant calendar access and showed no prompt. "
                    + "Open Privacy Settings and allow Calendars for Locus."
            }
        } catch {
            updateAccessState()
            errorMessage = error.localizedDescription
        }
    }

    func updateAccessState() {
        guard externalCalendarsEnabled else { accessState = .denied; return }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            accessState = .notDetermined
        case .denied, .restricted:
            accessState = .denied
        case .writeOnly:
            accessState = .writeOnly
        case .fullAccess, .authorized:
            accessState = .fullAccess
        @unknown default:
            accessState = .denied
        }
    }

    func refresh() {
        updateAccessState()
        guard accessState.canRead else {
            calendars = []
            events = []
            return
        }
        let loadedCalendars = eventStore.calendars(for: .event).sorted {
            if $0.source.title != $1.source.title { return $0.source.title < $1.source.title }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let loadedIDs = Set(loadedCalendars.map(\.calendarIdentifier))
        if !hasInitializedVisibleCalendars || (calendars.isEmpty && !loadedCalendars.isEmpty) {
            visibleCalendarIDs = loadedIDs
            hasInitializedVisibleCalendars = true
        } else {
            visibleCalendarIDs.formIntersection(loadedIDs)
        }
        calendars = loadedCalendars

        let interval = visibleMonthInterval
        let selectedCalendars = loadedCalendars.filter {
            visibleCalendarIDs.contains($0.calendarIdentifier)
        }
        let predicate = eventStore.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: selectedCalendars
        )
        events = (selectedCalendars.isEmpty ? [] : eventStore.events(matching: predicate)).sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        if localLoadError == nil { errorMessage = nil }
    }

    func moveMonth(by value: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: value, to: displayedMonth)
        else { return }
        displayedMonth = next
        refresh()
    }

    func showToday() {
        selectedDate = Date()
        displayedMonth = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: Date())
        ) ?? Date()
        refresh()
    }

    func toggleCalendar(_ identifier: String) {
        if visibleCalendarIDs.contains(identifier) {
            visibleCalendarIDs.remove(identifier)
        } else {
            visibleCalendarIDs.insert(identifier)
        }
        refresh()
    }

    func events(on date: Date) -> [LocusCalendarEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let local = showsLocalCalendar ? localEvents : []
        return (local + events.map(entry)).filter { $0.startDate < end && $0.endDate > start }
            .sorted { $0.startDate == $1.startDate ? $0.title < $1.title : $0.startDate < $1.startDate }
    }

    private func saveDocument(_ next: LocusCalendarDocument) throws {
        // Never overwrite a file we could not read or a newer schema.
        if let localLoadError { throw localLoadError }
        try FileManager.default.createDirectory(at: localFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: localFileURL, options: .atomic)
        document = next
        localEvents = next.events
    }

    @discardableResult
    func saveLocalEvent(_ event: LocusCalendarEntry) throws -> LocusCalendarEntry {
        var event = event
        event.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !event.title.isEmpty else { throw CalendarStoreError.titleRequired }
        guard event.endDate > event.startDate else { throw CalendarStoreError.invalidRange }
        guard event.isLocal, event.id.hasPrefix("locus-event:") else { throw CalendarStoreError.calendarNotFound }
        event.agentIDs = Array(Set(event.agentIDs)).sorted { $0.uuidString < $1.uuidString }
        var next = document
        if let index = next.events.firstIndex(where: { $0.id == event.id }) { next.events[index] = event }
        else { next.events.append(event) }
        try saveDocument(next)
        return event
    }

    func removeLocalEvent(_ id: String) throws {
        guard document.events.contains(where: { $0.id == id }) else { throw CalendarStoreError.eventNotFound }
        var next = document
        next.events.removeAll { $0.id == id }
        try saveDocument(next)
    }

    func setExternalAgentIDs(_ ids: [UUID], eventID: String) throws {
        var next = document
        next.externalAgentIDs[eventID] = Array(Set(ids))
        try saveDocument(next)
        objectWillChange.send()
    }

    private func entry(_ event: EKEvent) -> LocusCalendarEntry {
        LocusCalendarEntry(id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "Untitled event", startDate: event.startDate, endDate: event.endDate,
            isAllDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "",
            agentIDs: document.externalAgentIDs[event.eventIdentifier ?? ""] ?? [],
            calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
            account: event.calendar.source.title, writable: event.calendar.allowsContentModifications)
    }

    func createEvent(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool,
        location: String,
        notes: String,
        calendarID: String?
    ) throws -> EKEvent {
        guard accessState.canRead else { throw CalendarStoreError.accessRequired }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw CalendarStoreError.titleRequired }
        guard end > start else { throw CalendarStoreError.invalidRange }
        let target = try writableCalendar(identifier: calendarID)
        let event = EKEvent(eventStore: eventStore)
        event.title = normalizedTitle
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        event.calendar = target
        try eventStore.save(event, span: .thisEvent, commit: true)
        refresh()
        return event
    }

    /// Execute the native Calendar tool family. Calendar identifiers come only
    /// from EventKit, and event identifiers are opaque values returned by a
    /// prior list/create call. Provider credentials never cross this boundary.
    func perform(tool: String, arguments: [String: Any]) -> [String: Any] {
        updateAccessState()
        do {
            let requestedAgentIDs = arguments["agent_ids"] == nil ? nil : try agentIDs(arguments["agent_ids"])
            switch tool {
            case "calendar_list":
                return try listEvents(arguments: arguments)
            case "calendar_create":
                let start = try requiredDate(arguments["start"], name: "start")
                let end = try requiredDate(arguments["end"], name: "end")
                guard let title = arguments["title"] as? String else {
                    throw CalendarStoreError.titleRequired
                }
                if arguments["calendar_id"] == nil || arguments["calendar_id"] as? String == "locus" {
                    let event = try saveLocalEvent(LocusCalendarEntry(title: title, startDate: start, endDate: end,
                        isAllDay: arguments["all_day"] as? Bool ?? false,
                        location: arguments["location"] as? String ?? "", notes: arguments["notes"] as? String ?? "",
                        agentIDs: try agentIDs(arguments["agent_ids"])))
                    return ["text": "Created \(event.title) on Locus Calendar.", "event_id": event.id]
                }
                let event = try createEvent(
                    title: title,
                    start: start,
                    end: end,
                    isAllDay: arguments["all_day"] as? Bool ?? false,
                    location: arguments["location"] as? String ?? "",
                    notes: arguments["notes"] as? String ?? "",
                    calendarID: arguments["calendar_id"] as? String
                )
                if let requestedAgentIDs {
                    do { try setExternalAgentIDs(requestedAgentIDs, eventID: event.eventIdentifier ?? "") }
                    catch { errorMessage = "Event saved, but agent tags could not be saved: \(error.localizedDescription)" }
                }
                return [
                    "text": "Created \(event.title ?? "event") on \(event.calendar.title).",
                    "event_id": event.eventIdentifier ?? "",
                ]
            case "calendar_update":
                return try updateEvent(arguments: arguments)
            case "calendar_delete":
                return try deleteEvent(arguments: arguments)
            default:
                return ["error": "Unknown Calendar tool: \(tool)."]
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private var visibleMonthInterval: DateInterval {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: displayedMonth)
            ?? DateInterval(start: displayedMonth, duration: 31 * 86_400)
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start ?? month.start
        let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? month.end
        return DateInterval(start: gridStart, end: gridEnd)
    }

    private func writableCalendar(identifier: String?) throws -> EKCalendar {
        if let identifier {
            guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
                throw CalendarStoreError.calendarNotFound
            }
            guard calendar.allowsContentModifications else { throw CalendarStoreError.readOnlyCalendar }
            return calendar
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarStoreError.noWritableCalendar
        }
        return calendar
    }

    private func listEvents(arguments: [String: Any]) throws -> [String: Any] {
        let now = Date()
        let start = try optionalDate(arguments["start"]) ?? Calendar.current.startOfDay(for: now)
        let proposedEnd = try optionalDate(arguments["end"])
            ?? Calendar.current.date(byAdding: .day, value: 14, to: start)!
        guard proposedEnd > start else { throw CalendarStoreError.invalidRange }
        let maximumEnd = Calendar.current.date(byAdding: .day, value: 90, to: start)!
        let end = min(proposedEnd, maximumEnd)
        let external: [LocusCalendarEntry]
        if accessState.canRead {
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            external = eventStore.events(matching: predicate).map(entry)
        } else { external = [] }
        let all = (localEvents + external).filter { $0.startDate < end && $0.endDate > start }
            .sorted { $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate }
        let matches = all.prefix(200)
        let formatter = ISO8601DateFormatter()
        let payload: [[String: Any]] = matches.map { event in
            ["id": event.id, "title": event.title,
             "start": formatter.string(from: event.startDate), "end": formatter.string(from: event.endDate),
             "all_day": event.isAllDay, "calendar_id": event.calendarID, "calendar": event.calendarTitle,
             "account": event.account, "location": event.location, "notes": event.notes,
             "agent_ids": event.agentIDs.map(\.uuidString)]
        }
        let calendarLines = calendars.map { calendar in
            let access = calendar.allowsContentModifications ? "writable" : "read-only"
            return "Calendar [\(calendar.calendarIdentifier)] \(calendar.title) (\(calendar.source.title), \(access))"
        }
        let lines = payload.map { item in
            let allDay = (item["all_day"] as? Bool) == true ? " (all day)" : ""
            var line = "Event [\(item["id"] ?? "")] \(item["start"] ?? "") – \(item["end"] ?? ""): \(item["title"] ?? "") [calendar_id=\(item["calendar_id"] ?? ""), \(item["calendar"] ?? ""), \(item["account"] ?? "")]\(allDay)"
            if let location = (item["location"] as? String)?.nilIfEmpty {
                line += "\n  Location: \(location)"
            }
            if let notes = (item["notes"] as? String)?.nilIfEmpty {
                line += "\n  Notes: \(notes)"
            }
            return line
        }
        let eventText = lines.isEmpty ? "No events in this range." : lines.joined(separator: "\n")
        return [
            "text": ("Calendar [locus] Locus Calendar (built in, writable)\n" + calendarLines.joined(separator: "\n"))
                + "\n\n" + eventText,
            "events": payload,
            "truncated": all.count > 200,
        ]
    }

    private func updateEvent(arguments: [String: Any]) throws -> [String: Any] {
        if let id = arguments["event_id"] as? String, id.hasPrefix("locus-event:") {
            guard var event = localEvents.first(where: { $0.id == id }) else { throw CalendarStoreError.eventNotFound }
            if let calendar = arguments["calendar_id"] as? String, calendar != "locus" { throw CalendarStoreError.cannotMoveCalendar }
            if let title = arguments["title"] as? String { event.title = title }
            if arguments["start"] != nil { event.startDate = try requiredDate(arguments["start"], name: "start") }
            if arguments["end"] != nil { event.endDate = try requiredDate(arguments["end"], name: "end") }
            if let allDay = arguments["all_day"] as? Bool { event.isAllDay = allDay }
            if let location = arguments["location"] as? String { event.location = location }
            if let notes = arguments["notes"] as? String { event.notes = notes }
            if arguments["agent_ids"] != nil { event.agentIDs = try agentIDs(arguments["agent_ids"]) }
            try saveLocalEvent(event)
            return ["text": "Updated \(event.title).", "event_id": id]
        }
        guard accessState.canRead else { throw CalendarStoreError.accessRequired }
        guard let identifier = arguments["event_id"] as? String,
              let event = eventStore.event(withIdentifier: identifier)
        else { throw CalendarStoreError.eventNotFound }
        guard event.calendar.allowsContentModifications else { throw CalendarStoreError.readOnlyCalendar }
        if let title = arguments["title"] as? String {
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw CalendarStoreError.titleRequired }
            event.title = normalized
        }
        if arguments["start"] != nil { event.startDate = try requiredDate(arguments["start"], name: "start") }
        if arguments["end"] != nil { event.endDate = try requiredDate(arguments["end"], name: "end") }
        guard event.endDate > event.startDate else { throw CalendarStoreError.invalidRange }
        if let allDay = arguments["all_day"] as? Bool { event.isAllDay = allDay }
        if let location = arguments["location"] as? String { event.location = location.nilIfEmpty }
        if let notes = arguments["notes"] as? String { event.notes = notes.nilIfEmpty }
        if let calendarID = arguments["calendar_id"] as? String {
            event.calendar = try writableCalendar(identifier: calendarID)
        }
        try eventStore.save(event, span: .thisEvent, commit: true)
        refresh()
        if arguments["agent_ids"] != nil {
            do { try setExternalAgentIDs(agentIDs(arguments["agent_ids"]), eventID: identifier) }
            catch { errorMessage = "Event saved, but agent tags could not be saved: \(error.localizedDescription)" }
        }
        return ["text": "Updated \(event.title ?? "event").", "event_id": identifier]
    }

    private func deleteEvent(arguments: [String: Any]) throws -> [String: Any] {
        if let id = arguments["event_id"] as? String, id.hasPrefix("locus-event:") {
            try removeLocalEvent(id)
            return ["text": "Deleted event."]
        }
        guard accessState.canRead else { throw CalendarStoreError.accessRequired }
        guard let identifier = arguments["event_id"] as? String,
              let event = eventStore.event(withIdentifier: identifier)
        else { throw CalendarStoreError.eventNotFound }
        guard event.calendar.allowsContentModifications else { throw CalendarStoreError.readOnlyCalendar }
        let title = event.title ?? "event"
        try eventStore.remove(event, span: .thisEvent, commit: true)
        refresh()
        return ["text": "Deleted \(title)."]
    }

    private func agentIDs(_ value: Any?) throws -> [UUID] {
        guard let value else { return [] }
        guard let values = value as? [String], values.count <= 64,
              values.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CalendarStoreError.invalidAgentIDs }
        return values.compactMap(UUID.init(uuidString:))
    }

    private func requiredDate(_ value: Any?, name: String) throws -> Date {
        guard let date = try optionalDate(value) else {
            throw CalendarStoreError.invalidDate(name)
        }
        return date
    }

    private func optionalDate(_ value: Any?) throws -> Date? {
        guard let raw = value as? String else {
            if value == nil { return nil }
            throw CalendarStoreError.invalidDate("date")
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: raw) else { throw CalendarStoreError.invalidDate(raw) }
        return date
    }
}

enum CalendarStoreError: LocalizedError {
    case accessRequired
    case unsupportedVersion, cannotMoveCalendar, invalidAgentIDs
    case titleRequired
    case invalidRange
    case invalidDate(String)
    case calendarNotFound
    case eventNotFound
    case readOnlyCalendar
    case noWritableCalendar

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This calendar was saved by a newer version of Locus. Update Locus to edit it."
        case .cannotMoveCalendar: "Create a new event to move between Locus Calendar and an external account."
        case .invalidAgentIDs: "Use at most 64 valid agent IDs."
        case .accessRequired: "Enable Calendar access to use external calendars. Locus Calendar is available now."
        case .titleRequired: "An event title is required."
        case .invalidRange: "The event end must be after its start."
        case .invalidDate(let value): "Invalid ISO 8601 date: \(value)."
        case .calendarNotFound: "That calendar is no longer available."
        case .eventNotFound: "That event is no longer available."
        case .readOnlyCalendar: "That calendar is read-only."
        case .noWritableCalendar: "No writable calendar is available. Add an account in System Settings first."
        }
    }
}

struct InspectorCalendarTab: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @ObservedObject private var store = LocusCalendarStore.shared
    @State private var showingNewEvent = false
    @State private var editingEvent: LocusCalendarEntry?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let values = calendar.veryShortStandaloneWeekdaySymbols
        let index = max(0, min(calendar.firstWeekday - 1, values.count - 1))
        return Array(values[index...] + values[..<index])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.accessState.canRead {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Locus Calendar is ready").font(.locus(size: 12, weight: .semibold))
                        Text("Add an account to overlay your other calendars.").font(.locus(size: 11)).foregroundStyle(viewColors.muted)
                    }
                    Spacer()
                    Button("Connect calendars") {
                        if store.accessState == .notDetermined { Task { await store.requestAccess() } }
                        else { openCalendarPrivacy() }
                    }.buttonStyle(.locus())
                }.padding(12).background(viewColors.surfaceCard)
            }
            if let error = store.errorMessage {
                Text(error).font(.locus(size: 11)).foregroundStyle(viewColors.coral).padding(8)
            }
            calendarContent
        }
        .onAppear { store.refresh() }
        .locusSheet(isPresented: $showingNewEvent) {
            CalendarEventComposer(store: store).modifier(LocusWorldSheetTheme())
        }
        .locusSheet(item: $editingEvent) { event in
            CalendarEventComposer(store: store, event: event).modifier(LocusWorldSheetTheme())
        }
        .accessibilityIdentifier("calendar.content")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(viewColors.signalDeep)
            Text("Calendar")
                .font(.locus(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Group {
                Menu {
                    Button { store.showsLocalCalendar.toggle() } label: {
                        Label("Locus Calendar · Built in", systemImage: store.showsLocalCalendar ? "checkmark.circle.fill" : "circle")
                    }
                    ForEach(store.calendars, id: \.calendarIdentifier) { calendar in
                        Button {
                            store.toggleCalendar(calendar.calendarIdentifier)
                        } label: {
                            Label(
                                "\(calendar.title) · \(calendar.source.title)",
                                systemImage: store.visibleCalendarIDs.contains(calendar.calendarIdentifier)
                                    ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                    Divider()
                    Button("Add Google or Microsoft…", action: openInternetAccounts)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .help("Choose calendars and connect accounts")
                .accessibilityIdentifier("calendar.accounts")

                Button { showingNewEvent = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.locus())
                .help("New event")
                .accessibilityLabel("New event")
                .accessibilityIdentifier("calendar.newEvent")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var calendarContent: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 && geometry.size.height >= 340 {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 0) {
                        monthToolbar
                        monthGrid(expanded: true, dayHeight: max(34, min(58, (geometry.size.height - 124) / 6)))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(viewColors.surfaceCard.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    agenda.frame(width: max(270, geometry.size.width * 0.36))
                        .background(viewColors.surfaceCard.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }.padding(16)
            } else {
                VStack(spacing: 0) {
                    monthToolbar
                    monthGrid(expanded: false)
                    Divider().padding(.top, 8)
                    agenda
                }
            }
        }
    }

    private var monthToolbar: some View {
        HStack(spacing: 6) {
            Button { store.moveMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.locus()).accessibilityLabel("Previous month")
            Text(store.displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.locus(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
            Button("Today") { store.showToday() }
                .buttonStyle(.locus())
            Button { store.moveMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.locus()).accessibilityLabel("Next month")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func monthGrid(expanded: Bool, dayHeight: CGFloat = 29) -> some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(viewColors.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(monthDates, id: \.self) { date in
                dayCell(date, expanded: expanded, dayHeight: dayHeight)
            }
        }
        .padding(.horizontal, 9)
    }

    private func dayCell(_ date: Date, expanded: Bool, dayHeight: CGFloat) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: store.selectedDate)
        let isToday = calendar.isDateInToday(date)
        let isCurrentMonth = calendar.isDate(date, equalTo: store.displayedMonth, toGranularity: .month)
        let dayEvents = store.events(on: date)
        let hasEvents = !dayEvents.isEmpty
        return Button {
            store.selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(String(calendar.component(.day, from: date)))
                    .font(.locus(size: 11, weight: isToday ? .semibold : .regular))
                Circle()
                    .fill(hasEvents ? (isSelected ? viewColors.brandInk : viewColors.signalDeep) : .clear)
                    .frame(width: 3, height: 3)
                if expanded {
                    Text(dayEvents.first?.title ?? " ").font(.locus(size: 9)).lineLimit(1)
                        .padding(.horizontal, 3)
                }
            }
            .foregroundStyle(isSelected ? viewColors.brandInk : isCurrentMonth ? viewColors.ink : viewColors.muted)
            .frame(maxWidth: .infinity, minHeight: dayHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? viewColors.signalDeep : isToday ? viewColors.signalDeep.opacity(0.10) : .clear)
            }
        }
        .buttonStyle(.locus())
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(hasEvents ? "Has events" : "No events")
    }

    private var agenda: some View {
        let dayEvents = store.events(on: store.selectedDate)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.locus(size: 12, weight: .semibold))
                Spacer()
                Text("\(dayEvents.count) event\(dayEvents.count == 1 ? "" : "s")")
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if dayEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.locus(size: 20))
                        .foregroundStyle(viewColors.muted)
                    Text("Nothing scheduled")
                        .font(.locus(size: 12, weight: .semibold))
                    Text("A clear day across your visible calendars.")
                        .font(.locus(size: 10))
                        .foregroundStyle(viewColors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(dayEvents) { event in
                            Button { editingEvent = event } label: { CalendarEventRow(event: event) }
                                .buttonStyle(.plain)
                                .help(event.writable ? "Edit event" : "View event")
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var monthDates: [Date] {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: store.displayedMonth)
        let start = month.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0.start)?.start }
            ?? store.displayedMonth
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func openInternetAccounts() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.internetaccounts",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { break }
        }
    }

    private func openCalendarPrivacy() {
        // System Settings replaced the old preference-pane identifier; the
        // legacy one stays as a fallback for older macOS.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { break }
        }
    }
}

private struct CalendarEventRow: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let event: LocusCalendarEntry

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calendarColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title.nilIfEmpty ?? "Untitled event")
                    .font(.locus(size: 12, weight: .semibold))
                    .lineLimit(2)
                AgentTagLabels(ids: event.agentIDs)
                Text(timeText)
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textSecondary)
                Text("\(event.calendarTitle) · \(event.account)")
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.muted)
                    .lineLimit(1)
                if let location = event.location.nilIfEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.locus(size: 9))
                        .foregroundStyle(viewColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(viewColors.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var calendarColor: Color {
        event.isLocal ? viewColors.signalDeep : viewColors.blue
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}

private struct CalendarEventComposer: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @ObservedObject var store: LocusCalendarStore
    var event: LocusCalendarEntry? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3600)
    @State private var end = Date().addingTimeInterval(7200)
    @State private var allDay = false
    @State private var location = ""
    @State private var notes = ""
    @State private var calendarID = "locus"
    @State private var taggedAgentIDs: [UUID] = []
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event == nil ? "New Event" : "Event details")
                .font(.locus(size: 18, weight: .semibold))
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("calendar.event.title")
            AgentMentionPicker(selectedIDs: $taggedAgentIDs)
            Toggle("All day", isOn: $allDay)
            DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            DatePicker("Ends", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            Picker("Calendar", selection: $calendarID) {
                Text("Locus Calendar · Built in").tag("locus")
                ForEach(store.calendars.filter { $0.allowsContentModifications || $0.calendarIdentifier == event?.calendarID }, id: \.calendarIdentifier) { calendar in
                    Text("\(calendar.title) · \(calendar.source.title)")
                        .tag(calendar.calendarIdentifier)
                }
            }
            .disabled(event != nil)
            TextField("Location", text: $location)
                .textFieldStyle(.roundedBorder)
            TextField("Notes", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            if let errorMessage {
                Text(errorMessage)
                    .font(.locus(size: 11))
                    .foregroundStyle(viewColors.coral)
            }
            HStack {
                if let event, event.writable {
                    Button("Delete event", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button(event?.writable == false ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(event == nil ? "Add Event" : "Save changes", action: save)
                    .buttonStyle(.locus(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(event?.writable == false || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (allDay ? Calendar.current.startOfDay(for: end) < Calendar.current.startOfDay(for: start) : end <= start))
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear {
            if let event {
                title = event.title; start = event.startDate; end = event.endDate
                allDay = event.isAllDay; location = event.location; notes = event.notes
                if allDay { end = Calendar.current.date(byAdding: .day, value: -1, to: event.endDate) ?? event.endDate }
                calendarID = event.calendarID; taggedAgentIDs = event.agentIDs
            } else {
                start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: store.selectedDate) ?? store.selectedDate
                end = start.addingTimeInterval(3600)
            }
        }
        .alert("Delete this event?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let event else { return }
                let result = store.perform(tool: "calendar_delete", arguments: ["event_id": event.id])
                if let error = result["error"] as? String { errorMessage = error } else { dismiss() }
            }
        } message: { Text("This removes the event from its calendar.") }
    }

    private func save() {
        let formatter = ISO8601DateFormatter()
        let calendar = Calendar.current
        let eventStart = allDay ? calendar.startOfDay(for: start) : start
        // The end date shown for all-day events is inclusive in the editor.
        let eventEnd = allDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))! : end
        var arguments: [String: Any] = ["title": title, "start": formatter.string(from: eventStart),
            "end": formatter.string(from: eventEnd), "all_day": allDay, "location": location,
            "notes": notes, "calendar_id": calendarID, "agent_ids": taggedAgentIDs.map(\.uuidString)]
        if let event { arguments["event_id"] = event.id }
        let result = store.perform(tool: event == nil ? "calendar_create" : "calendar_update", arguments: arguments)
        if let error = result["error"] as? String { errorMessage = error; return }
        store.selectedDate = start
        store.displayedMonth = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: start)
        ) ?? start
        store.refresh()
        dismiss()
    }
}
