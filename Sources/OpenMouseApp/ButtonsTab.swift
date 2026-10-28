import SwiftUI
import OpenMouseKit

/// One of the six physical buttons, numbered like the vendor app numbers them.
struct PhysicalButton: Identifiable {
    let number: Int
    let name: String
    /// Index into the mouse's key table. Buttons 4 and 5 are in the opposite order to flash:
    /// the vendor app shows 4 = Forward (`01 10`, flash slot 4) and 5 = Back (`01 08`, slot 3).
    /// Which side button is which is inferred from that layout, not confirmed by pressing them.
    let slot: Int
    /// Marker position on the 300 x 440 mouse drawing.
    let marker: CGPoint
    var id: Int { number }

    static let all: [PhysicalButton] = [
        PhysicalButton(number: 1, name: "Left button", slot: 0, marker: CGPoint(x: 100, y: 105)),
        PhysicalButton(number: 2, name: "Right button", slot: 1, marker: CGPoint(x: 200, y: 105)),
        PhysicalButton(number: 3, name: "Middle button", slot: 2, marker: CGPoint(x: 150, y: 71)),
        PhysicalButton(number: 4, name: "Side button, front", slot: 4, marker: CGPoint(x: 46, y: 215)),
        PhysicalButton(number: 5, name: "Side button, rear", slot: 3, marker: CGPoint(x: 46, y: 270)),
        PhysicalButton(number: 6, name: "DPI button", slot: 5, marker: CGPoint(x: 150, y: 130)),
    ]
}

/// Our own top-view drawing of a right-handed mouse; no vendor artwork.
private struct MouseBody: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 300, sy = rect.height / 440
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var p = Path()
        p.move(to: pt(150, 8))
        p.addCurve(to: pt(238, 60), control1: pt(200, 8), control2: pt(228, 30))
        p.addCurve(to: pt(262, 200), control1: pt(250, 100), control2: pt(266, 150))
        p.addCurve(to: pt(240, 360), control1: pt(258, 260), control2: pt(256, 320))
        p.addCurve(to: pt(150, 432), control1: pt(228, 405), control2: pt(196, 432))
        p.addCurve(to: pt(62, 360), control1: pt(104, 432), control2: pt(72, 405))
        p.addCurve(to: pt(44, 220), control1: pt(50, 320), control2: pt(40, 270))
        p.addCurve(to: pt(62, 60), control1: pt(48, 150), control2: pt(50, 100))
        p.addCurve(to: pt(150, 8), control1: pt(72, 30), control2: pt(100, 8))
        p.closeSubpath()
        return p
    }
}

struct ButtonsTab: View {
    @EnvironmentObject var model: AppModel
    var enabled: Bool
    /// False only for the preview image: `ImageRenderer` cannot draw a Menu.
    var scrollable = true
    @State private var selected: Int? = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 48) {
                illustration
                VStack(alignment: .leading, spacing: 10) {
                    if model.keys.count < KeyMap.physicalSlots.count {
                        Text("Waiting for the mouse…").foregroundStyle(Theme.dim)
                    } else {
                        ForEach(PhysicalButton.all) { row($0) }
                    }
                    Text("Pick a number on the mouse or in the list, then choose its function. At least one button always stays Left click. Macros and shortcuts can't be edited yet.")
                        .font(.caption).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: drawing

    private var illustration: some View {
        ZStack {
            MouseBody()
                .fill(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            MouseBody().stroke(Color(white: 0.35), lineWidth: 2)
            // Split between the two main buttons and the palm area.
            Path { p in
                p.move(to: CGPoint(x: 150, y: 8)); p.addLine(to: CGPoint(x: 150, y: 46))
                p.move(to: CGPoint(x: 150, y: 96)); p.addLine(to: CGPoint(x: 150, y: 166))
                p.move(to: CGPoint(x: 56, y: 172))
                p.addQuadCurve(to: CGPoint(x: 252, y: 172), control: CGPoint(x: 150, y: 190))
            }
            .stroke(Color(white: 0.45), lineWidth: 1.5)
            // Scroll wheel.
            RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.25))
                .frame(width: 24, height: 54).position(x: 150, y: 71)
            // DPI button.
            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.55))
                .frame(width: 22, height: 12).position(x: 150, y: 130)
            // Side buttons on the thumb side.
            ForEach([PhysicalButton.all[3], PhysicalButton.all[4]]) { b in
                RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.55))
                    .frame(width: 12, height: 40).position(x: b.marker.x + 12, y: b.marker.y)
            }
            ForEach(PhysicalButton.all) { marker($0) }
        }
        .frame(width: 300, height: 440)
    }

    private func marker(_ b: PhysicalButton) -> some View {
        let on = selected == b.number
        return Button { selected = b.number } label: {
            Text("\(b.number)").font(.callout.weight(.semibold)).monospacedDigit()
                .frame(width: 28, height: 28)
                .background(on ? Theme.accent : Color(white: 0.12), in: Circle())
                .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .position(b.marker)
    }

    // MARK: list

    private func row(_ b: PhysicalButton) -> some View {
        let on = selected == b.number
        return HStack(spacing: 12) {
            Text("\(b.number)").font(.caption.weight(.semibold)).monospacedDigit()
                .frame(width: 22, height: 22)
                .background(on ? Theme.accent : Color.clear, in: Circle())
                .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
            Text(b.name).foregroundStyle(on ? .white : Theme.dim).frame(width: 150, alignment: .leading)
            functionMenu(slot: b.slot)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = b.number }
    }

    @ViewBuilder private func functionMenu(slot: Int) -> some View {
        let current = model.keys[slot]
        if let current, current.isEditable, scrollable {
            Menu {
                ForEach(KeyFunction.choices, id: \.title) { choice in
                    Button(choice.title) { model.changeKey(slot: slot, to: choice) }
                }
            } label: { chip(current.title) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(!enabled)
        } else if let current, current.isEditable {
            // ImageRenderer can't draw a Menu, so the preview image shows the same chip as text.
            chip(current.title)
        } else {
            Text(current?.title ?? "unreadable").foregroundStyle(Theme.dim)
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title).frame(width: 150, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
    }
}
