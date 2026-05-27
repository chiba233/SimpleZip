//
//  ShowDetailsToggleButton.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/28.
//

import SwiftUI

struct ShowDetailsToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(L10n.text("operation.showDetails"), systemImage: "sidebar.right")
        }
        .toggleStyle(.button)
        .controlSize(.small)
    }
}
