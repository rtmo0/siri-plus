import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(WorkspaceTab.allCases, selection: $model.selectedTab) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            Group {
                switch model.selectedTab ?? .chat {
                case .chat:
                    ChatView(model: model)
                case .meeting:
                    HistoryView(history: model.history, meeting: model.meeting, askAbout: model.askAbout) {
                        MeetingView(
                            meeting: model.meeting,
                            permissions: model.permissions,
                            isModelReady: model.isHintModelReady,
                            showPanel: { model.showHintPanel?() },
                            openSettings: { model.selectedTab = .settings }
                        )
                    }
                case .settings:
                    PreferencesView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Errors float over the content as tinted glass instead of pushing it down.
            .overlay(alignment: .top) {
                if let error = model.errorMessage ?? model.meeting.errorMessage ?? model.history.errorMessage ?? model.chats.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: model.errorMessage ?? model.meeting.errorMessage ?? model.history.errorMessage ?? model.chats.errorMessage)
        }
        .frame(minWidth: 820, minHeight: 480)
        .tint(.indigo)
        .task { await model.refreshAccounts() }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.errorMessage = nil
                model.meeting.errorMessage = nil
                model.history.errorMessage = nil
                model.chats.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .accessibilityLabel("Dismiss the error")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
