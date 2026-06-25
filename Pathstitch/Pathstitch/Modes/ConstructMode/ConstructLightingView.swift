import SwiftUI
import AppKit

/// The Mockup lighting panel — modelled on Adobe Illustrator's 3D lighting UI:
/// a row of named presets, a draggable sphere that shows (and sets) the active
/// light's direction, a list of lights, and colour / intensity / rotation /
/// height / softness controls plus a global ambient. Drives `AppState` lighting,
/// which is pushed live to the construct viewport.
struct ConstructLightingView: View {
    @Bindable var state: AppState

    private var activeIndex: Int {
        min(max(0, state.activeLightIndex), max(0, state.constructLights.count - 1))
    }
    private var activeLight: ConstructLight {
        state.constructLights.indices.contains(activeIndex) ? state.constructLights[activeIndex]
            : ConstructLight()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Lighting")

            // Presets — the Standard / Diffuse / Top-Left / Right thumbnails.
            HStack(spacing: 8) {
                ForEach(ConstructLightPreset.allCases) { preset in
                    Button { state.applyLightPreset(preset) } label: {
                        VStack(spacing: 4) {
                            PresetThumb(preset: preset)
                                .frame(width: 44, height: 44)
                            Text(preset.label)
                                .font(.system(size: 9))
                                .foregroundColor(.text_secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Draggable sphere — drag the dot to aim the active light.
            HStack {
                Spacer()
                LightSpherePreview(
                    rotation: activeLight.rotation,
                    height: activeLight.height,
                    color: Color(hex: activeLight.colorHex)
                ) { rot, h in state.setLightDirection(rotation: rot, height: h) }
                .frame(width: 150, height: 150)
                Spacer()
            }

            // Lights list (eye toggle + select), with add / remove.
            VStack(spacing: 2) {
                ForEach(Array(state.constructLights.enumerated()), id: \.element.id) { idx, light in
                    HStack(spacing: 8) {
                        Button { state.setActiveLight(idx); state.setLightOn(!light.on) } label: {
                            Image(systemName: light.on ? "eye" : "eye.slash")
                                .font(.system(size: 11))
                                .foregroundColor(light.on ? .text_primary : .text_secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        Circle().fill(Color(hex: light.colorHex)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.border_subtle, lineWidth: 1))
                        Text("Light \(idx + 1)").font(PlasticityFont.label)
                            .foregroundColor(idx == activeIndex ? .accent : .text_primary)
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(idx == activeIndex ? Color.bg_selected : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture { state.setActiveLight(idx) }
                }
            }
            HStack {
                Button { state.addConstructLight() } label: {
                    Image(systemName: "plus").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(.text_secondary).help("Add light")
                Button { state.removeConstructLight(activeIndex) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(state.constructLights.count > 1 ? .text_secondary : .text_secondary.opacity(0.3))
                .disabled(state.constructLights.count <= 1)
                .help("Remove light")
                Spacer()
            }

            // Active-light parameters.
            HStack {
                Text("Color").font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { Color(hex: activeLight.colorHex) },
                    set: { state.setLightColor(Self.hex(from: $0)) }), supportsOpacity: false)
                    .labelsHidden().frame(width: 40)
            }
            lightSlider("Intensity", value: activeLight.intensity, range: 0...5, pct: true) {
                state.setLightIntensity($0)
            }
            lightSlider("Rotation", value: activeLight.rotation, range: 0...360, unit: "°") {
                state.setLightDirection(rotation: $0, height: activeLight.height)
            }
            lightSlider("Height", value: activeLight.height, range: 0...90, unit: "°") {
                state.setLightDirection(rotation: activeLight.rotation, height: $0)
            }
            lightSlider("Softness", value: activeLight.softness, range: 0...1, pct: true) {
                state.setLightSoftness($0)
            }

            Divider().background(Color.border_subtle).padding(.vertical, 2)
            lightSlider("Ambient", value: state.constructAmbient, range: 0...1, pct: true) {
                state.setConstructAmbient($0)
            }
        }
    }

    private func lightSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                             unit: String = "", pct: Bool = false,
                             onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(PlasticityFont.label).foregroundColor(.text_secondary)
                Spacer()
                Text(pct ? "\(Int(value / range.upperBound * 100))%"
                         : (unit == "°" ? "\(Int(value))\(unit)" : String(format: "%.2f", value)))
                    .font(PlasticityFont.label.monospacedDigit()).foregroundColor(.text_secondary)
            }
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
                .controlSize(.small)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(PlasticityFont.label)
            .foregroundColor(.text_secondary).tracking(1)
    }

    /// SwiftUI Color → "RRGGBB" hex.
    static func hex(from c: Color) -> String {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255)), g = Int(round(ns.greenComponent * 255)),
            b = Int(round(ns.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

/// A shaded sphere with a draggable highlight that maps to a light's azimuth
/// (rotation) and elevation (height). Centre = overhead, rim = grazing.
struct LightSpherePreview: View {
    let rotation: Double      // azimuth degrees
    let height: Double        // elevation degrees (0 = rim … 90 = centre)
    let color: Color
    var onChange: (Double, Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let R = min(geo.size.width, geo.size.height) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let dot = Self.dotPoint(rotation: rotation, height: height, center: center, R: R)
            let u = UnitPoint(x: dot.x / geo.size.width, y: dot.y / geo.size.height)
            ZStack {
                // matte backing disk
                Circle().fill(Color.black.opacity(0.25))
                // lit sphere: highlight follows the light dot
                Circle().fill(RadialGradient(
                    gradient: Gradient(colors: [color, color.opacity(0.85), Color.black.opacity(0.92)]),
                    center: u, startRadius: 1, endRadius: R * 1.7))
                Circle().stroke(Color.border_subtle, lineWidth: 1)
                // the draggable light handle
                Circle().stroke(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.white.opacity(0.2)))
                    .frame(width: 12, height: 12)
                    .position(dot)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let (rot, h) = Self.angles(from: v.location, center: center, R: R)
                onChange(rot, h)
            })
        }
    }

    static func dotPoint(rotation: Double, height: Double, center: CGPoint, R: CGFloat) -> CGPoint {
        let rr = CGFloat(cos(height * .pi / 180))            // 1 at rim … 0 at centre
        let rad = rotation * .pi / 180
        return CGPoint(x: center.x + R * rr * CGFloat(sin(rad)),
                       y: center.y + R * rr * CGFloat(cos(rad)))
    }

    static func angles(from p: CGPoint, center: CGPoint, R: CGFloat) -> (Double, Double) {
        let ux = Double((p.x - center.x) / max(R, 1)), uy = Double((p.y - center.y) / max(R, 1))
        let rr = min(1.0, (ux * ux + uy * uy).squareRoot())
        let h = acos(rr) * 180 / .pi                          // centre → 90°, rim → 0°
        var rot = atan2(ux, uy) * 180 / .pi
        if rot < 0 { rot += 360 }
        return (rot, h)
    }
}

/// Tiny shaded-sphere thumbnail previewing a preset's key direction.
struct PresetThumb: View {
    let preset: ConstructLightPreset
    var body: some View {
        let key = preset.lights.first ?? ConstructLight()
        GeometryReader { geo in
            let R = min(geo.size.width, geo.size.height) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let dot = LightSpherePreview.dotPoint(rotation: key.rotation, height: key.height, center: center, R: R)
            let u = UnitPoint(x: dot.x / geo.size.width, y: dot.y / geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3))
                Circle().fill(RadialGradient(
                    gradient: Gradient(colors: [.white, Color.gray.opacity(0.7), Color.black.opacity(0.9)]),
                    center: u, startRadius: 1, endRadius: R * 1.7))
                    .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border_subtle, lineWidth: 1))
        }
    }
}
