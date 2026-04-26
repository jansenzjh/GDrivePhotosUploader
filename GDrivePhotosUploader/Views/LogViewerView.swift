import SwiftUI
import UIKit

struct LogViewerView: View {
    @State private var logText = ""
    @State private var isShowingClearConfirmation = false
    @State private var copyStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            if let copyStatus {
                Text(copyStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
            }

            ScrollView {
                Text(logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .navigationTitle("App Log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh") {
                    loadLog()
                }

                Button("Copy") {
                    copyLog()
                }

                Button("Clear", role: .destructive) {
                    isShowingClearConfirmation = true
                }
            }
        }
        .confirmationDialog(
            "Clear app log?",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Log", role: .destructive) {
                AppLogger.clearLog()
                loadLog()
                copyStatus = "Log cleared."
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local log text. It does not affect uploaded photos or sync records.")
        }
        .onAppear {
            loadLog()
        }
    }

    private func loadLog() {
        logText = AppLogger.readLog()
    }

    private func copyLog() {
        UIPasteboard.general.string = logText
        copyStatus = "Log copied to clipboard."
    }
}

#Preview {
    NavigationStack {
        LogViewerView()
    }
}
