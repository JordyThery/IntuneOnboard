import OnboardCore
import SwiftUI

/// Device details: serial number, OS build, network state and elapsed time.
struct AboutThisMacPopover: View {
    let device: DeviceInfo?
    let startedAt: Date?

    /// Updates the elapsed time while open.
    @State private var now = Date.now

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 54, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .padding(.top, 22)
                .padding(.bottom, 12)

            if let device {
                Text(device.marketingName ?? device.modelIdentifier)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                Text(device.computerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }

            Divider()
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            VStack(spacing: 7) {
                if let device {
                    if let chip = device.chip {
                        row(ProvisioningStrings.chip, chip)
                    }
                    if let memory = device.memory {
                        row(ProvisioningStrings.memory, memory)
                    }
                    if let storage = device.storage {
                        row(ProvisioningStrings.storage, storage)
                    }
                    if device.marketingName != nil {
                        row(ProvisioningStrings.model, device.modelIdentifier)
                    }
                    if let serial = device.serialNumber {
                        row(ProvisioningStrings.serialNumber, serial)
                    }
                    // A product name; not translated.
                    row(verbatim: "macOS", device.osVersion)
                    if let online = device.isOnline {
                        networkRow(online)
                    }
                }
                if let elapsed {
                    row(ProvisioningStrings.elapsed, elapsed)
                }
            }
            .padding(.horizontal, 20)

            Text(verbatim: "Intune Onboard")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
                .padding(.bottom, 18)
        }
        .frame(width: 300)
        .task {
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ label: LocalizedStringResource, _ value: String) -> some View {
        row(label: Text(label), value: value)
    }

    /// For names such as `macOS`, which are not translated.
    private func row(verbatim label: String, _ value: String) -> some View {
        row(label: Text(verbatim: label), value: value)
    }

    private func row(label: Text, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func networkRow(_ online: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ProvisioningStrings.network)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            HStack(spacing: 5) {
                Circle()
                    .fill(online ? .green : .red)
                    .frame(width: 7, height: 7)
                Text(online ? ProvisioningStrings.online : ProvisioningStrings.offline)
                    .font(.caption)
            }
        }
    }

    /// Formatted by the system, so units follow the locale.
    private var elapsed: String? {
        guard let startedAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let units: Set<Duration.UnitsFormatStyle.Unit> =
            seconds >= 60 ? [.minutes, .seconds] : [.seconds]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .abbreviated))
    }
}

#Preview("About") {
    AboutThisMacPopover(
        device: DeviceInfo(
            marketingName: "MacBook Air (13-inch, M4, 2025)",
            computerName: "Contoso - MacBook Pro 14 - C02ABC123DEF",
            modelIdentifier: "Mac15,13",
            chip: "Apple M4",
            memoryBytes: 16 * 1024 * 1024 * 1024,
            storageBytes: 494_384_795_648,
            serialNumber: "C02ABC123DEF",
            osVersion: "macOS 27.0 (26A428)",
            isOnline: true
        ),
        startedAt: Date.now.addingTimeInterval(-174)
    )
}

#Preview("About — offline, minimal") {
    AboutThisMacPopover(
        device: DeviceInfo(
            computerName: "MacBook Air",
            modelIdentifier: "Mac15,13",
            serialNumber: nil,
            osVersion: "macOS 27.0",
            isOnline: false
        ),
        startedAt: nil
    )
}
