import AppKit
import SwiftUI

enum Theme {
    static let background = Color(red: 0.118, green: 0.118, blue: 0.125)
    static let panel = Color(white: 0.165)
    static let tile = Color(white: 0.22)
    static let tileHover = Color(white: 0.28)
    static let separator = Color.white.opacity(0.08)
    static let record = Color(red: 0.98, green: 0.27, blue: 0.25)
    /// Brand green (also the app icon): #22C07A.
    static let accent = Color(red: 0.133, green: 0.753, blue: 0.478)
    static let accentNS = NSColor(srgbRed: 0.133, green: 0.753, blue: 0.478, alpha: 1)
    static let level = accent
    static let secondary = Color.white.opacity(0.55)
}

/// Round icon button used in the bars and the list rows.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 26
    var help: String = ""
    var tint: Color = .white
    var active = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .medium))
                .foregroundStyle(active ? tint : Theme.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

/// Toggle button with an on/off symbol, like the mouse / camera / sound / mic switches.
struct ToggleIcon: View {
    let on: String
    let off: String
    @Binding var isOn: Bool
    var help: String = ""
    var size: CGFloat = 30
    var level: Float? = nil

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                if let level, isOn {
                    Circle().trim(from: 0, to: CGFloat(level))
                        .stroke(Theme.level, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.08), value: level)
                }
                Image(systemName: isOn ? on : off)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Theme.secondary)
            }
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(isOn ? 0.14 : 0.05)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? L("On") : L("Off"))
    }
}

/// Small chevron menu to pick a capture device.
struct DeviceMenu: View {
    let devices: [CaptureDevice]
    @Binding var selection: String?

    var body: some View {
        Menu {
            ForEach(devices) { d in
                Button {
                    selection = d.id
                } label: {
                    if d.id == (selection ?? devices.first?.id) { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
            if devices.isEmpty { Text(L("No device found")) }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.secondary)
        .accessibilityLabel(L("Choose device"))
    }
}

/// Big red record / stop button.
struct RecordButton: View {
    var recording: Bool
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.9)).frame(width: size, height: size)
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.record).frame(width: size * 0.38, height: size * 0.38)
                } else {
                    Circle().fill(Theme.record).frame(width: size * 0.74, height: size * 0.74)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(recording ? L("Stop Recording") : L("Start Recording"))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Converts a rect in this screen's top-left-origin points to global AppKit coordinates.
    func globalRect(fromLocal r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func localRect(fromGlobal r: CGRect) -> CGRect {
        CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }
}
