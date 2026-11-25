import CoreImage.CIFilterBuiltins
import SwiftUI

struct PYLinkSettingsView: View {
    @State private var server = PYLinkServer.shared

    var body: some View {
        Form {
            Section {
                Toggle("Allow PullYard for iPhone to connect", isOn: Binding(get: { server.enabled }, set: { server.enabled = $0 }))
                LabeledContent("Status") {
                    if server.enabled {
                        if let port = server.port {
                            Text("Listening on port \(port)\(server.connected.isEmpty ? "" : " · \(server.connected.count) connected")").foregroundStyle(Color.syGreen)
                        } else if let error = server.lastError {
                            Text(error).foregroundStyle(Color.syRed)
                        } else {
                            Text("Starting…").foregroundStyle(Color.syMuted)
                        }
                    } else {
                        Text("Off").foregroundStyle(Color.syMuted)
                    }
                }
            } footer: {
                Text("Your iPhone can start agent fixes on this Mac and follow the chat live. The connection is end-to-end encrypted with keys exchanged through the QR code. It works on the same Wi‑Fi or over Tailscale and other VPNs.")
            }

            Section("Pair an iPhone") {
                if let pairing = server.pairing, let expires = server.pairingExpires {
                    HStack(alignment: .top, spacing: 18) {
                        if let image = Self.qr(pairing.url) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 190, height: 190)
                                .padding(10)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("In PullYard on your iPhone open Settings → Mac, tap Pair and scan this code.")
                            Text("Code \(pairing.code)").font(.system(.title3, design: .monospaced).weight(.semibold))
                            Text("Expires \(expires.formatted(date: .omitted, time: .shortened))").foregroundStyle(Color.syMuted)
                            Button("Cancel") { server.cancelPairing() }
                        }
                    }
                } else {
                    Button("Show pairing code") { server.beginPairing() }
                }
            }

            Section("Paired iPhones") {
                if server.devices.isEmpty {
                    Text("No iPhones yet.").foregroundStyle(Color.syMuted)
                }
                ForEach(server.devices) { device in
                    HStack {
                        Image(systemName: "iphone")
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(server.connected.contains(device.id) ? "Connected" : device.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Never connected")
                                .font(.caption).foregroundStyle(server.connected.contains(device.id) ? Color.syGreen : Color.syMuted)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { server.remove(device) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
