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

/// The single EventKit owner used by both the inspector and the agent bridge.
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

    private let eventStore: EKEventStore
    private var storeChangedObserver: NSObjectProtocol?
    private var hasInitializedVisibleCalendars = false

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
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
        events = eventStore.events(matching: predicate).sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        errorMessage = nil
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

    func events(on date: Date) -> [EKEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return events.filter { $0.startDate < end && $0.endDate > start }
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
        guard accessState.canRead else {
            return ["error": "Calendar access is not enabled. Open the Calendar panel and choose Allow Calendar Access."]
        }
        do {
            switch tool {
            case "calendar_list":
                return try listEvents(arguments: arguments)
            case "calendar_create":
                let start = try requiredDate(arguments["start"], name: "start")
                let end = try requiredDate(arguments["end"], name: "end")
                guard let title = arguments["title"] as? String else {
                    throw CalendarStoreError.titleRequired
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
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let matches = eventStore.events(matching: predicate).prefix(200)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [[String: Any]] = matches.map { event in
            [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "Untitled event",
                "start": formatter.string(from: event.startDate),
                "end": formatter.string(from: event.endDate),
                "all_day": event.isAllDay,
                "calendar_id": event.calendar.calendarIdentifier,
                "calendar": event.calendar.title,
                "account": event.calendar.source.title,
                "location": event.location ?? "",
                "notes": event.notes ?? "",
            ]
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
            "text": (calendarLines.isEmpty ? "No connected calendars." : calendarLines.joined(separator: "\n"))
                + "\n\n" + eventText,
            "events": payload,
            "truncated": matches.count == 200,
        ]
    }

    private func updateEvent(arguments: [String: Any]) throws -> [String: Any] {
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
        return ["text": "Updated \(event.title ?? "event").", "event_id": identifier]
    }

    private func deleteEvent(arguments: [String: Any]) throws -> [String: Any] {
        guard let identifier = arguments["event_id"] as? String,
              let event = eventStore.event(withIdentifier: identifier)
        else { throw CalendarStoreError.eventNotFound }
        guard event.calendar.allowsContentModifications else { throw CalendarStoreError.readOnlyCalendar }
        let title = event.title ?? "event"
        try eventStore.remove(event, span: .thisEvent, commit: true)
        refresh()
        return ["text": "Deleted \(title)."]
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
    case titleRequired
    case invalidRange
    case invalidDate(String)
    case calendarNotFound
    case eventNotFound
    case readOnlyCalendar
    case noWritableCalendar

    var errorDescription: String? {
        switch self {
        case .accessRequired: "Calendar access is required."
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
    @ObservedObject private var store = LocusCalendarStore.shared
    @State private var showingNewEvent = false

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
            switch store.accessState {
            case .fullAccess:
                calendarContent
            case .notDetermined:
                permissionState(
                    symbol: "calendar.badge.plus",
                    title: "Bring your calendars into Locus",
                    detail: "See events from Calendar, Google, and Microsoft, and let agents schedule with your approval.",
                    action: "Allow Calendar Access",
                    handler: { Task { await store.requestAccess() } },
                    settingsAction: "Open Privacy Settings"
                )
            case .denied, .writeOnly:
                permissionState(
                    symbol: "calendar.badge.exclamationmark",
                    title: "Calendar access is off",
                    detail: "Enable full Calendar access for Locus in System Settings to show and manage events.",
                    action: "Open Privacy Settings",
                    handler: openCalendarPrivacy
                )
            }
        }
        .onAppear { store.refresh() }
        .sheet(isPresented: $showingNewEvent) {
            CalendarEventComposer(store: store)
        }
        .accessibilityIdentifier("calendar.content")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(LocusTheme.signalDeep)
            Text("Calendar")
                .font(.locus(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            if store.accessState.canRead {
                Menu {
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
                .disabled(store.writableCalendars.isEmpty)
                .help("New event")
                .accessibilityLabel("New event")
                .accessibilityIdentifier("calendar.newEvent")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var calendarContent: some View {
        VStack(spacing: 0) {
            monthToolbar
            monthGrid
            Divider().padding(.top, 8)
            agenda
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

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(monthDates, id: \.self) { date in
                dayCell(date)
            }
        }
        .padding(.horizontal, 9)
    }

    private func dayCell(_ date: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: store.selectedDate)
        let isToday = calendar.isDateInToday(date)
        let isCurrentMonth = calendar.isDate(date, equalTo: store.displayedMonth, toGranularity: .month)
        let hasEvents = !store.events(on: date).isEmpty
        return Button {
            store.selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(String(calendar.component(.day, from: date)))
                    .font(.locus(size: 11, weight: isToday ? .semibold : .regular))
                Circle()
                    .fill(hasEvents ? (isSelected ? Color.white : LocusTheme.signalDeep) : .clear)
                    .frame(width: 3, height: 3)
            }
            .foregroundStyle(isSelected ? Color.white : isCurrentMonth ? LocusTheme.ink : LocusTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 29)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? LocusTheme.signalDeep : isToday ? LocusTheme.signalDeep.opacity(0.10) : .clear)
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
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if dayEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.locus(size: 20))
                        .foregroundStyle(LocusTheme.muted)
                    Text("Nothing scheduled")
                        .font(.locus(size: 12, weight: .semibold))
                    Text("A clear day across your visible calendars.")
                        .font(.locus(size: 10))
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(dayEvents, id: \.eventIdentifier) { event in
                            CalendarEventRow(event: event)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func permissionState(
        symbol: String,
        title: String,
        detail: String,
        action: String,
        handler: @escaping () -> Void,
        settingsAction: String? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.locus(size: 30))
                .foregroundStyle(LocusTheme.signalDeep)
            Text(title)
                .font(.locus(size: 14, weight: .semibold))
            Text(detail)
                .font(.locus(size: 11))
                .foregroundStyle(LocusTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action, action: handler)
                .buttonStyle(.locus(.primary))
            if let settingsAction {
                Button(settingsAction, action: openCalendarPrivacy)
                    .buttonStyle(.locus())
            }
            Button("Connect Google or Microsoft", action: openInternetAccounts)
                .buttonStyle(.locus())
            if let message = store.errorMessage {
                Text(message)
                    .font(.locus(size: 11))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.permission.error")
            }
        }
        .padding(28)
        .frame(maxWidth: 360, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
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
    let event: EKEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calendarColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title.nilIfEmpty ?? "Untitled event")
                    .font(.locus(size: 12, weight: .semibold))
                    .lineLimit(2)
                Text(timeText)
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.textSecondary)
                Text("\(event.calendar.title) · \(event.calendar.source.title)")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
                if let location = (event.location ?? "").nilIfEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var calendarColor: Color {
        guard let color = NSColor(cgColor: event.calendar.cgColor) else { return LocusTheme.signalDeep }
        return Color(nsColor: color)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}

private struct CalendarEventComposer: View {
    @ObservedObject var store: LocusCalendarStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3600)
    @State private var end = Date().addingTimeInterval(7200)
    @State private var allDay = false
    @State private var location = ""
    @State private var notes = ""
    @State private var calendarID = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Event")
                .font(.locus(size: 18, weight: .semibold))
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("calendar.event.title")
            Toggle("All day", isOn: $allDay)
            DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            DatePicker("Ends", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            Picker("Calendar", selection: $calendarID) {
                ForEach(store.writableCalendars, id: \.calendarIdentifier) { calendar in
                    Text("\(calendar.title) · \(calendar.source.title)")
                        .tag(calendar.calendarIdentifier)
                }
            }
            TextField("Location", text: $location)
                .textFieldStyle(.roundedBorder)
            TextField("Notes", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            if let errorMessage {
                Text(errorMessage)
                    .font(.locus(size: 11))
                    .foregroundStyle(LocusTheme.coral)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Event", action: save)
                    .buttonStyle(.locus(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear {
            if calendarID.isEmpty {
                calendarID = store.writableCalendars.first?.calendarIdentifier ?? ""
            }
        }
    }

    private func save() {
        do {
            _ = try store.createEvent(
                title: title,
                start: start,
                end: end,
                isAllDay: allDay,
                location: location,
                notes: notes,
                calendarID: calendarID.nilIfEmpty
            )
            store.selectedDate = start
            store.displayedMonth = Calendar.current.date(
                from: Calendar.current.dateComponents([.year, .month], from: start)
            ) ?? start
            store.refresh()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
