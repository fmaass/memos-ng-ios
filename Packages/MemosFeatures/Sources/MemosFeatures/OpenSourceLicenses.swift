import Foundation
import SwiftUI

/// One package the app is built with, as the Licenses sheet lists it.
///
/// Read from `Resources/spm-licenses.json`, which is written from the tracked `Package.resolved`:
/// one entry per pin, its licence as the repository's host identifies it (an SPDX id), or
/// "see repository" where the host could not say.
nonisolated struct OpenSourcePackage: Decodable, Equatable, Sendable, Identifiable {
    let name: String
    let version: String
    let license: String
    let repository: URL

    var id: String { name }
}

/// The file's shape: one object, its `packages` array, so a field added later has somewhere to go.
nonisolated private struct LicenseFile: Decodable {
    let packages: [OpenSourcePackage]
}

enum OpenSourceLicenses {
    nonisolated static func decode(_ data: Data) throws -> [OpenSourcePackage] {
        try JSONDecoder().decode(LicenseFile.self, from: data).packages
    }

    /// The list this build was made with, read once. An unreadable file is an empty list, which
    /// the sheet says, rather than a crash on the way to a courtesy.
    static let bundled: [OpenSourcePackage] = {
        guard let url = Bundle.module.url(forResource: "spm-licenses", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let packages = try? decode(data)
        else { return [] }
        return packages
    }()
}

/// The open-source packages the app is built with and the licence each is published under.
struct LicensesSheet: View {
    let packages: [OpenSourcePackage]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if packages.isEmpty {
                    Text("The package list is missing from this build.")
                        .foregroundStyle(.secondary)
                }
                ForEach(packages) { package in
                    Link(destination: package.repository) {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.tight) {
                            Text(package.name)
                                .foregroundStyle(.primary)
                            Text("\(package.license) · \(package.version)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(DesignTokens.accent)
    }
}
