import SwiftUI

// MARK: - Active Tool Options — reference design language
//
// This file recreates the "Active Tool Options Panel — Decluttered Shell"
// design handoff (Design Reference/design_handoff_tool_options_panel) as a small
// reusable SwiftUI control library. It is a *shell + a set of rules*: every tool
// looks different inside, but they all share these tokens and controls.
//
// The reference is specified dark-only; the values below are appearance-adaptive
// so the app's light theme still works, but the dark values match the handoff's
// tokens exactly (panel #0f1014, field #181a20, accent #2f7ff6, …).

// MARK: Tokens

extension Color {
    // Surfaces
    static let to_panel       = dynamic(dark: "0f1014", light: "ffffff")  // panel surface
    static let to_panelDeep   = dynamic(dark: "0d0e12", light: "f7f8fa")  // layers tray
    static let to_panelBorder = dynamic(dark: "20232a", light: "e2e3e8")  // panel border
    static let to_divider     = dynamic(dark: "191c22", light: "ececef")  // section divider
    static let to_field       = dynamic(dark: "181a20", light: "f1f2f5")  // field / inset surface
    static let to_card        = dynamic(dark: "15171c", light: "f6f7f9")  // card / track surface
    static let to_fieldBorder = dynamic(dark: "2a2d34", light: "d6d8dd")  // field border (consolidated)
    static let to_trackBorder = dynamic(dark: "272a31", light: "dcdee3")  // segmented-track border

    // Text tiers
    static let to_textPri   = dynamic(dark: "e7e9ee", light: "1b1b22")
    static let to_textSec   = dynamic(dark: "c4c8d0", light: "33363d")
    static let to_textTer   = dynamic(dark: "9aa0ab", light: "65696f")  // labels
    static let to_textMut   = dynamic(dark: "6b7079", light: "8b8f97")  // summaries
    static let to_textFaint = dynamic(dark: "5a5f68", light: "a4a8af")

    // Accent + status
    static let to_accent     = Color(hex: "2f7ff6")
    static let to_accentTint = Color(hex: "2f7ff6").opacity(0.13)
    static let to_warn       = Color(hex: "f5a623")
    static let to_ok         = Color(hex: "3ecf8e")
}

/// Neutral panel-elevation shadow from the handoff — the *only* shadow in the
/// system, never tinted with a colour.
extension View {
    func toPanelShadow() -> some View {
        self.shadow(color: Color.black.opacity(0.55), radius: 30, x: 0, y: 24)
    }
}

// MARK: Number formatting (tabular, trailing-zero-trimmed)

/// Formats a value for steppers / readouts / summaries: up to `maxFrac` decimals
/// with trailing zeros trimmed, so 2.0 → "2", 1.50 → "1.5".
func toNum(_ v: Double, maxFrac: Int = 2) -> String {
    if v.rounded() == v && abs(v) < 1e9 { return String(Int(v.rounded())) }
    var s = String(format: "%.\(maxFrac)f", v)
    while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
    return s
}

// MARK: Tool title + help popover (pinned chrome, Shell A & B)

/// Tool name (uppercase, accent glyph) with a circular "ⓘ" help toggle. The help
/// copy lives in a popover card directly below — collapsed by default, never
/// shown expanded by default (a tool is used hundreds of times).
struct TOToolTitle: View {
    let icon: String            // SF Symbol
    let title: String
    var help: String? = nil
    @Binding var helpOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.to_accent)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(1.05)
                    .foregroundColor(Color.to_textPri)
                    .textCase(.uppercase)
                Spacer(minLength: 6)
                if help != nil {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { helpOpen.toggle() } } label: {
                        // SF Symbol "info" is optically centered in its frame, so the
                        // glyph sits dead-center in the ring (a plain italic "i" does
                        // not — its slant + metrics push it down-left).
                        Image(systemName: "info")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(helpOpen ? Color.to_accent : Color.to_textTer)
                            .frame(width: 19, height: 19)
                            .overlay(Circle().stroke(helpOpen ? Color.to_accent : Color.to_textTer.opacity(0.55),
                                                     lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Show tool help")
                }
            }
            if helpOpen, let help {
                Text(help)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color.to_textTer)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.to_card))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.to_trackBorder, lineWidth: 1))
                    .padding(.top, 12)
            }
        }
    }
}

// MARK: Live status line (pinned, never collapses)

/// Selection / status feedback — a coloured dot + text, optionally a muted hint.
/// Live feedback, not configuration; the handoff keeps this outside any section.
struct TOStatus: View {
    var color: Color = .to_accent
    let text: String
    var hint: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(color)
            if let hint {
                Text("· \(hint)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color.to_textFaint)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Warning card (Stitch's orange MISMATCH-style readout). Pinned, never collapsed.
struct TOWarning: View {
    let title: String
    var detail: String? = nil
    var color: Color = .to_warn

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Color.to_textTer)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(color.opacity(0.45), lineWidth: 1))
    }
}

// MARK: Collapsible section

/// One collapsible settings group. Header = chevron · uppercase label · optional
/// "Default" badge · spacer · muted one-line summary. Sections are independent
/// (each owns its open state); pass `defaultOpen: true` to the one section that
/// should open the first time the tool is activated.
struct TOSection<Content: View>: View {
    let title: String
    var isDefault: Bool = false
    var summary: String = ""
    var defaultOpen: Bool = false
    var showsTopDivider: Bool = true
    @ViewBuilder var content: () -> Content

    @State private var open: Bool

    init(_ title: String,
         isDefault: Bool = false,
         summary: String = "",
         defaultOpen: Bool = false,
         showsTopDivider: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isDefault = isDefault
        self.summary = summary
        self.defaultOpen = defaultOpen
        self.showsTopDivider = showsTopDivider
        self.content = content
        _open = State(initialValue: defaultOpen)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.to_textMut)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.0)
                        .textCase(.uppercase)
                        .foregroundColor(Color.to_textTer)
                        .fixedSize()
                    if isDefault { TODefaultBadge() }
                    Spacer(minLength: 8)
                    // The summary hides while a "Default" section is open — the live
                    // controls already show the same numbers.
                    if !summary.isEmpty && !(isDefault && open) {
                        Text(summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.to_textMut)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 13) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .top) {
            if showsTopDivider {
                Rectangle().fill(Color.to_divider).frame(height: 1)
            }
        }
    }
}

struct TODefaultBadge: View {
    var body: some View {
        Text("Default")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.45)
            .textCase(.uppercase)
            .foregroundColor(Color.to_accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.to_accentTint))
            .fixedSize()
    }
}

// MARK: Control label + row

/// A control label (500 / 13px), used at the leading edge of a control row.
struct TOLabel: View {
    let text: String
    var color: Color = .to_textSec
    init(_ text: String, color: Color = .to_textSec) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(color)
    }
}

/// Uppercase group subheader for flat (non-collapsible) tools — same type as a
/// section label, used to break a short tool's controls into named groups.
struct TOGroupLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.0)
            .textCase(.uppercase)
            .foregroundColor(Color.to_textTer)
    }
}

/// label · spacer · trailing control row.
struct TORow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 14) {
            TOLabel(label)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// Muted helper / hint paragraph (500 / 12px).
struct TOHint: View {
    let text: String
    var leadingInset: CGFloat = 0
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color.to_textMut)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Stepper pill  ( − value unit + )

/// `− [value][unit] +` in one bordered pill, value centred, unit muted inline.
/// The centre is an editable field so an exact value can still be typed.
struct TOStepper: View {
    @Binding var value: Double
    var unit: String = "mm"
    var step: Double = 0.5
    var range: ClosedRange<Double> = 0...100000
    var maxFrac: Int = 2
    var width: CGFloat = 122
    var onChange: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            stepButton("−") { set(value - step) }
            HStack(spacing: 3) {
                TextField("", value: Binding(
                    get: { value },
                    set: { set($0) }
                ), format: .number.precision(.fractionLength(0...maxFrac)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.to_textPri)
                    .fixedSize()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.to_textMut)
                }
            }
            .frame(maxWidth: .infinity)
            stepButton("+") { set(value + step) }
        }
        .frame(width: width, height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_fieldBorder, lineWidth: 1))
    }

    private func set(_ v: Double) {
        let clamped = min(range.upperBound, max(range.lowerBound, v))
        // Round to the formatter precision so repeated stepping stays clean.
        let p = pow(10.0, Double(maxFrac))
        value = (clamped * p).rounded() / p
        onChange?()
    }

    private func stepButton(_ glyph: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color.to_textTer)
                .frame(width: 32, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Segmented control (2+ equal-width pills)

/// Equal-width pills in a bordered track; active pill filled accent with white
/// text, inactive transparent with muted text. For Fill/Count, Single/Saddle, …
struct TOSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var onChange: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                let active = opt.0 == selection
                Button {
                    selection = opt.0
                    onChange?()
                } label: {
                    Text(opt.1)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(active ? .white : Color.to_textTer)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(active ? Color.to_accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_trackBorder, lineWidth: 1))
    }
}

// MARK: Checkbox

/// 18px rounded square; off = field fill + neutral border, on = accent fill +
/// white check. The whole row is clickable, not just the box.
struct TOCheck: View {
    let label: String
    @Binding var isOn: Bool
    var sub: String? = nil
    var labelColor: Color = .to_textSec
    var onChange: (() -> Void)? = nil

    var body: some View {
        Button {
            isOn.toggle()
            onChange?()
        } label: {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.to_accent : Color.to_field)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isOn ? Color.to_accent : Color.to_fieldBorder, lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(labelColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if let sub {
                        Text(sub)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.to_textMut)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Slider + readout

/// Native range with brand-blue accent, min/max labels at each end, plus a
/// separate readout pill with the live value + unit.
struct TOSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String = "mm"
    var minLabel: String? = nil
    var maxLabel: String? = nil
    var maxFrac: Int = 1
    var onCommit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 11) {
            Text(minLabel ?? toNum(range.lowerBound, maxFrac: 0))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.to_textMut)
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit?() }
            }
            .tint(Color.to_accent)
            Text(maxLabel ?? toNum(range.upperBound, maxFrac: 0))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.to_textMut)
            HStack(spacing: 3) {
                Text(toNum(value, maxFrac: maxFrac))
                    .monospacedDigit()
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color.to_textPri)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color.to_textMut)
                }
            }
            .frame(minWidth: 62)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.to_field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.to_fieldBorder, lineWidth: 1))
        }
    }
}

// MARK: Select (styled dropdown)

/// For longer option lists where a chip row would be too wide (Hole Shape, …).
struct TOSelect<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var onChange: (() -> Void)? = nil

    private var currentLabel: String { options.first { $0.0 == selection }?.1 ?? "" }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) {
                    selection = options[i].0
                    onChange?()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.to_textPri)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.to_textTer)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.to_field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.to_fieldBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: Chip card (3+ named presets)

/// One preset card for a chip row: small icon, bold name, muted sub-label. Active
/// card gets an accent border + faint accent-tinted fill.
struct TOChipCard<Icon: View>: View {
    let name: String
    var sub: String? = nil
    let active: Bool
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon()
                    .frame(height: 22)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? Color.to_textPri : Color.to_textSec)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let sub {
                    Text(sub)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.to_textMut)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(active ? Color.to_accentTint : Color.to_field))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(active ? Color.to_accent : Color.to_trackBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Preset chips (one-tap common values)

/// A row of one-tap preset chips that set a `Double` binding to common values, so
/// the user rarely has to type. The chip matching the current value fills accent.
struct TOPresetChips: View {
    let values: [Double]
    @Binding var value: Double
    var unit: String = ""
    var maxFrac: Int = 2
    var onPick: ((Double) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { v in
                let active = abs(value - v) < 1e-6
                Button {
                    value = v
                    onPick?(v)
                } label: {
                    Text(toNum(v, maxFrac: maxFrac) + unit)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(active ? .white : Color.to_textTer)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(active ? Color.to_accent : Color.to_field))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(active ? Color.to_accent : Color.to_fieldBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A small stepper row for integer values (sides, segments, …).
struct TOIntStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...999
    var width: CGFloat = 110

    var body: some View {
        HStack(spacing: 0) {
            button("−") { value = max(range.lowerBound, value - 1) }
            Text("\(value)")
                .monospacedDigit()
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.to_textPri)
                .frame(maxWidth: .infinity)
            button("+") { value = min(range.upperBound, value + 1) }
        }
        .frame(width: width, height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.to_field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.to_fieldBorder, lineWidth: 1))
    }

    private func button(_ glyph: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(.system(size: 18)).foregroundColor(Color.to_textTer)
                .frame(width: 30, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Section divider (full-bleed, inside a tool body)

struct TODivider: View {
    var body: some View {
        Rectangle().fill(Color.to_divider).frame(height: 1)
    }
}

// MARK: Primary action button (pinned footer)

/// Full-width accent action — "Apply Sewing Holes", "Apply Scale", … Flat fill,
/// no gradient or glow.
struct TOPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 11)
                    .fill(enabled ? Color.to_accent : Color.to_accent.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Secondary / bordered action used inside panels (Cancel, Re-pick, Tag…).
struct TOSecondaryButton: View {
    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    var tint: Color = .to_accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundColor(enabled ? tint : Color.to_textMut)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(enabled ? 0.12 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(tint.opacity(enabled ? 0.45 : 0.15), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: Field-style modifier (number / text inputs that aren't steppers)

extension View {
    /// Reference field chrome for a bare TextField: field surface, consolidated
    /// border, 8px radius, tabular text.
    func toFieldStyle(width: CGFloat? = nil, height: CGFloat = 32) -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundColor(Color.to_textPri)
            .padding(.horizontal, 10)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.to_field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.to_fieldBorder, lineWidth: 1))
    }
}
