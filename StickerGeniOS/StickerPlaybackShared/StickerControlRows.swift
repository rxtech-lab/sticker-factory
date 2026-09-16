import AnimatedView
import SwiftUI

/// The rows a configurable sticker is posed with: the controls its creator declared, then the three
/// every sticker gets — animate, speed, and which frame a still freezes on.
///
/// Split out of `StickerControlsSheet` because the drawer is no longer the only place a pose is
/// made: the pack preview shows the same rows inline under the artwork. Two copies of the
/// binding-into-`AnimatedControlValue` mapping would be two places for a control type to be
/// forgotten, and the defaulting rules here are not obvious enough to retype.
struct StickerControlRows: View {
    let document: AnimatedDocument
    @Binding var settings: StickerControlSettings
    var sequenceEntry = false

    /// The controls bucketed by the character they pose, but only once there are two characters to
    /// tell apart. One character needs no heading, and a sticker that has always shown a plain list
    /// should not grow one.
    private var groups: [AnimatedControlConfiguration.ControlGroup] {
        guard let groups = document.configuration?.controlGroups,
              groups.filter({ $0.layerID != nil }).count >= 2 else { return [] }
        return groups
    }

    var body: some View {
        VStack(spacing: 10) {
            if groups.isEmpty {
                ForEach(document.configuration?.controls ?? []) { control in controlRow(control) }
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    heading(for: group).padding(.top, index == 0 ? 0 : 6)
                    ForEach(group.controls) { control in controlRow(control, under: group.layerID) }
                }
                // The three built-ins belong to the sticker rather than to anyone in it, so once the
                // cast has headings they need one of their own to stop reading as the last character's.
                if groups.last?.layerID != nil { PosterListHeader("General").padding(.top, 6) }
            }

            if !sequenceEntry { PosterToggleRow(
                title: String(localized: "Animate"),
                isOn: $settings.animate,
                identifier: "sticker-controls-animate"
            ) }

            // A document that binds its own number control to speed already offers this, under the
            // creator's name for it; a second slider would be two ways to set one value.
            if document.configuration?.controls.contains(where: { $0.type == .number && $0.binding == "speed" }) != true {
                PosterSliderRow(
                    title: String(localized: "Speed"),
                    value: $settings.speed,
                    range: 0.25 ... 2,
                    step: 0.05,
                    identifier: "sticker-controls-speed"
                )
            }

            if !sequenceEntry && !settings.animate {
                PosterSliderRow(
                    title: String(localized: "Still frame"),
                    value: $settings.stillPosition,
                    fractionDigits: nil,
                    identifier: "sticker-controls-frame"
                )
            }
        }
    }

    /// The character's name, or the sticker's own settings when the bucket belongs to no one layer.
    @ViewBuilder private func heading(for group: AnimatedControlConfiguration.ControlGroup) -> some View {
        if let layerID = group.layerID {
            PosterListHeader(verbatim: document.layers.first { $0.id == layerID }?.name ?? layerID)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            PosterListHeader("General").frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A plan names a cast's controls for the character they pose — "Cat pose", "Dog mood" — so the
    /// rows stay legible wherever they are shown ungrouped. Under that character's own heading the
    /// prefix is the heading again, so it comes off; the stored label is untouched.
    private func rowTitle(_ control: AnimatedControl, under layerID: String?) -> String {
        guard let layerID, let name = document.layers.first(where: { $0.id == layerID })?.name,
              !name.isEmpty, control.label.count > name.count,
              control.label.lowercased().hasPrefix(name.lowercased()) else { return control.label }
        let remainder = control.label.dropFirst(name.count).drop { $0 == " " || $0 == "’" || $0 == "'" || $0 == "s" }
        return remainder.isEmpty ? control.label : remainder.prefix(1).uppercased() + remainder.dropFirst()
    }

    @ViewBuilder private func controlRow(_ control: AnimatedControl, under layerID: String? = nil) -> some View {
        let title = rowTitle(control, under: layerID)
        switch control.type {
        case .choice:
            if sequenceEntry {
                StickerSequenceChoiceRow(control: control, title: title, settings: $settings)
            } else {
                PosterMenuRow(
                    caption: title,
                    value: selectedOptionLabel(control),
                    identifier: "sticker-control-\(control.id)"
                ) {
                    Picker(control.label, selection: Binding(
                        get: { settings.values[control.id]?.string ?? control.defaultValue.string ?? "" },
                        set: { settings.values[control.id] = .string($0) }
                    )) {
                        ForEach(control.options ?? []) { option in Text(option.label).tag(option.id) }
                    }
                }
            }
        case .number:
            PosterSliderRow(
                title: title,
                value: Binding(
                    get: { settings.values[control.id]?.number ?? control.defaultValue.number ?? 1 },
                    set: { settings.values[control.id] = .number($0) }
                ),
                range: (control.minimum ?? 0.25) ... (control.maximum ?? 2),
                step: control.step ?? 0.05,
                identifier: "sticker-control-\(control.id)"
            )
        case .toggle:
            PosterToggleRow(
                title: title,
                isOn: Binding(
                    get: { settings.values[control.id]?.bool ?? control.defaultValue.bool ?? true },
                    set: { settings.values[control.id] = .bool($0) }
                ),
                identifier: "sticker-control-\(control.id)"
            )
        }
    }

    /// The row shows the answer rather than the id behind it, and falls back to the id only when a
    /// document names an option its own list has dropped.
    private func selectedOptionLabel(_ control: AnimatedControl) -> String {
        let selected = settings.values[control.id]?.string ?? control.defaultValue.string ?? ""
        return control.options?.first { $0.id == selected }?.label ?? selected
    }
}

/// Use a navigation page for choices inside the stacked animation editor sheet. This keeps
/// long option lists accessible without presenting another popover over the two drawers.
private struct StickerSequenceChoiceRow: View {
    let control: AnimatedControl
    let title: String
    @Binding var settings: StickerControlSettings

    private var selected: String {
        settings.values[control.id]?.string ?? control.defaultValue.string ?? ""
    }

    var body: some View {
        NavigationLink {
            StickerSequenceChoicePage(control: control, selection: Binding(
                get: { selected },
                set: { settings.values[control.id] = .string($0) }
            ))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).posterLabelStyle(9, color: AppColors.muted)
                    Text(control.options?.first { $0.id == selected }?.label ?? selected)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.subheadline.bold())
            }
            .foregroundStyle(AppColors.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .posterSurface(cornerRadius: Poster.chipRadius, fill: AppColors.paper, lineWidth: Poster.hairline, offset: .zero)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sticker-control-\(control.id)")
    }
}

private struct StickerSequenceChoicePage: View {
    let control: AnimatedControl
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StickerBackground {
            List(control.options ?? []) { option in
                Button {
                    selection = option.id
                    dismiss()
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        if selection == option.id { Image(systemName: "checkmark") }
                    }
                    .foregroundStyle(AppColors.ink)
                    .contentShape(Rectangle())
                }
                .listRowBackground(AppColors.paper)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(control.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
