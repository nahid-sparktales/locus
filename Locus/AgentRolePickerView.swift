import SwiftUI

struct AgentRolePickerView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category = "All roles"
    let roles: [AgentRoleTemplate]
    let selectedID: String?
    let error: String?
    let select: (AgentRoleTemplate?) -> Void

    private var categories: [String] { ["All roles"] + Set(roles.map(\.category)).sorted() }
    private var showsCustom: Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return category == "All roles" && (query.isEmpty || "custom".contains(query))
    }
    private var filtered: [AgentRoleTemplate] {
        roles.filter { (category == "All roles" || $0.category == category) && $0.matches(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose a role").font(.locus(size: 22, weight: .semibold))
                    Text("Start with a specialist. Make every setting your own.")
                        .font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("agent.rolePicker.close")
            }.padding(22)
            HStack(spacing: 14) {
                TextField("Search roles", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if filtered.count == 1, !showsCustom { choose(filtered[0]) }
                        else if filtered.isEmpty, showsCustom { choose(nil) }
                    }
                    .accessibilityIdentifier("agent.rolePicker.search")
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }.frame(width: 230)
                    .accessibilityIdentifier("agent.rolePicker.category")
            }.padding(.horizontal, 22).padding(.bottom, 18)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    if showsCustom {
                        roleCard(id: "custom", name: "Custom", summary: "Write your own instructions and choose your settings.",
                                 category: "Your own role", selected: selectedID == nil) { choose(nil) }
                    }
                    ForEach(filtered) { role in
                        roleCard(id: role.id, name: role.name, summary: role.summary,
                                 category: role.category, selected: selectedID == role.id) { choose(role) }
                    }
                }.padding(22)
                if let error {
                    Text(error).foregroundStyle(viewColors.warningForeground).padding(.horizontal, 22)
                } else if filtered.isEmpty, !showsCustom, !search.isEmpty {
                    Text("No matching roles. Try another search.")
                        .foregroundStyle(viewColors.textSecondary).padding()
                }
            }.accessibilityIdentifier("agent.rolePicker.scroll")
        }
        .frame(width: 760, height: 620)
        .background(viewColors.surfaceCanvas)
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.rolePicker")
    }

    private func choose(_ role: AgentRoleTemplate?) {
        select(role)
        dismiss()
    }

    private func roleCard(id: String, name: String, summary: String, category: String,
                          selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: id == "custom" ? "square.and.pencil" : "person.crop.square")
                        .foregroundStyle(viewColors.accentAction)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(viewColors.accentAction) }
                }.accessibilityHidden(true)
                Text(name).font(.locus(size: 13, weight: .semibold)).foregroundStyle(viewColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary).font(.locus(size: 11)).foregroundStyle(viewColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(category).font(.locus(size: 9, weight: .medium)).foregroundStyle(viewColors.textTertiary)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
            .background(selected ? viewColors.accentAction.opacity(0.08) : viewColors.surfaceCard,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? viewColors.accentAction : viewColors.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.locus())
        .accessibilityLabel("\(name). \(summary)")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier("agent.rolePicker.\(id)")
    }
}
