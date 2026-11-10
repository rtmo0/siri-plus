import SwiftUI

/// How a sign-in, key or model row reads at a glance.
enum RowState {
    case ok, missing, warning, progress

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .missing: "person.crop.circle.badge.questionmark"
        case .warning: "exclamationmark.triangle.fill"
        case .progress: "clock"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .missing, .progress: .secondary
        case .warning: .orange
        }
    }
}

/// A title with a status icon and a caption under it.
struct AccountLabel: View {
    let title: String
    let detail: String
    let state: RowState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol)
                .font(.title2)
                .foregroundStyle(state.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(state == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A saved key or server, with what its last check found.
struct KeyLabel: View {
    let status: KeyStatus
    let title: String
    /// What to say once the check passed; "Saved in the keychain and working" when nil.
    var working: String?

    var body: some View {
        switch status {
        case .unchecked:
            AccountLabel(title: title, detail: working ?? String(localized: "Saved in the keychain"), state: .ok)
        case .checking:
            AccountLabel(title: title, detail: String(localized: "Checking…"), state: .progress)
        case .valid:
            AccountLabel(title: title, detail: working ?? String(localized: "Saved in the keychain and working"), state: .ok)
        case .rejected(let message):
            AccountLabel(title: title, detail: message, state: .warning)
        case .unverified(let message):
            AccountLabel(title: title, detail: String(localized: "Saved, but not checked: \(message)"), state: .warning)
        }
    }
}

struct Footnote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct StatusBadge: View {
    let isOK: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isOK ? Color.green : Color.orange)
    }
}

/// A model list as the provider gives it. A saved model missing from the list stays selectable.
struct ModelPicker: View {
    @Binding var selection: String
    let models: RouteModels

    var body: some View {
        let chosen = selection
        Picker("Model", selection: $selection) {
            if let title = models.defaultTitle {
                Text(verbatim: title).tag("")
            }
            ForEach(models.options) { option in
                Text(verbatim: option.title).tag(option.id)
            }
            if !chosen.isEmpty, !models.options.contains(where: { $0.id == chosen }) {
                Text(verbatim: chosen).tag(chosen)
            }
        }
        if let detail = models.options.first(where: { $0.id == chosen })?.detail, !detail.isEmpty {
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The effort levels the chosen model accepts; a model without effort gets none.
struct EffortPicker: View {
    @Binding var selection: String
    let levels: [String]

    var body: some View {
        if levels.isEmpty {
            LabeledContent("Effort") {
                Text("This model has no effort setting").foregroundStyle(.secondary)
            }
        } else {
            let chosen = selection
            Picker("Effort", selection: $selection) {
                Text(ModelEffort.title(ModelEffort.automatic)).tag(ModelEffort.automatic)
                ForEach(levels, id: \.self) { level in
                    Text(ModelEffort.title(level)).tag(level)
                }
                // A level the newly chosen model lacks is replaced by its nearest one when sent.
                if chosen != ModelEffort.automatic, !levels.contains(chosen) {
                    Text(ModelEffort.title(chosen)).tag(chosen)
                }
            }
            .help("How long the model thinks before answering. Deeper thinking is slower and uses more of the limits.")
        }
    }
}
