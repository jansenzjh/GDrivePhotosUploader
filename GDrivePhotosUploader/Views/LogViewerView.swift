import SwiftUI
import UIKit

struct LogViewerView: View {
    @State private var logText = ""
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
        .navigationTitle("Warnings & Errors")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh") {
                    loadLog()
                }

                Button("Copy") {
                    copyLog()
                }
            }
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
