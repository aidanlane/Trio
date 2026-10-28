import SwiftUI
import Swinject

extension DynamicISFExplorer {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(\.dynamicTypeSize) var dynamicTypeSize
        @Environment(AppState.self) var appState

        private let pickerSettings = PickerSettingsProvider.shared.settings

        var body: some View {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Pinned above the values, so the curve stays in view while they change
                    chartCard(plotHeight: Self.plotHeight(fitting: geometry.size.height))
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    List {
                        aboutSection
                        formulaSection
                        autosensSection
                        profileSection
                        tddSection
                    }
                    .listSectionSpacing(sectionSpacing)
                    // The card above already sets the values apart from the title
                    .contentMargins(.top, 0, for: .scrollContent)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle(Text("Dynamic ISF Explorer", comment: "Title of the screen that charts Dynamic ISF"))
            // The large title would take room from the values below the chart
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: state.reset) {
                        Text("Reset", comment: "Button that puts the Dynamic ISF Explorer's values back to the user's settings")
                    }
                    .disabled(!state.hasChanges)
                }
            }
        }

        /// The plot's height for a screen `available` points tall: about a third of it, so the rows below keep room
        /// for several values or an open picker.
        private static func plotHeight(fitting available: CGFloat) -> CGFloat {
            min(240, max(150, available * 0.3))
        }

        private func chartCard(plotHeight: CGFloat) -> some View {
            Group {
                if let curve = state.curve {
                    DynamicISFExplorerChart(
                        curve: curve,
                        savedCurve: state.savedCurve,
                        units: state.units,
                        plotHeight: plotHeight
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.unavailable, id: \.self) { reason in
                            switch reason {
                            case .noTDD:
                                Text(
                                    "Dynamic ISF needs a total daily dose above zero.",
                                    comment: "Shown in place of the Dynamic ISF Explorer's chart"
                                )
                            case .noAutosensRoom:
                                Text(
                                    "Dynamic ISF needs Autosens Max and Min to differ, with one at least 100% and the other at most 100%.",
                                    comment: "Shown in place of the Dynamic ISF Explorer's chart"
                                )
                            case .noWeakestLimit:
                                Text(
                                    "Autosens Max and Min need to be above zero to chart Dynamic ISF.",
                                    comment: "Shown in place of the Dynamic ISF Explorer's chart"
                                )
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                    // About the chart's height with its legend, so the values below don't move
                    .frame(maxWidth: .infinity, minHeight: plotHeight + 52)
                }
            }
            .padding()
            .background(Color.chart, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            // Pinned, so larger text would only crowd the chart and take room from the values. Home caps its fixed
            // area at this size too.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }

        /// Scrolls with the values, as it only needs reading once.
        private var aboutSection: some View {
            Section(
                content: {},
                footer: {
                    Text(
                        "Shows what Dynamic ISF does when enabled and active. Starts from your current settings and TDD. Does not consider overrides or temp targets. Changes here are not saved.",
                        comment: "Introduction to the Dynamic ISF Explorer, which is the subject of Shows, Starts and Does"
                    )
                }
            )
        }

        private var formulaSection: some View {
            Section(
                content: {
                    Picker("Formula", selection: $state.inputs.sigmoid) {
                        Text("Logarithmic").tag(false)
                        Text("Sigmoid").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if state.inputs.uses(\.adjustmentFactorSigmoid) {
                        factorStepper(
                            String(localized: "Sigmoid Adjustment Factor"),
                            \.adjustmentFactorSigmoid,
                            setting: pickerSettings.adjustmentFactorSigmoid
                        )
                    }
                    if state.inputs.uses(\.adjustmentFactor) {
                        factorStepper(
                            String(localized: "Adjustment Factor (AF)"),
                            \.adjustmentFactor,
                            setting: pickerSettings.adjustmentFactor
                        )
                    }
                    if state.inputs.uses(\.insulinPeakTime) {
                        stepper(
                            String(localized: "Insulin Peak Time"),
                            value: $state.inputs.insulinPeakTime,
                            changed: state.isChanged(\.insulinPeakTime),
                            in: state.insulinPeakTimeRange,
                            step: pickerSettings.insulinPeakTime.step,
                            unit: String(localized: "min", comment: "Minutes abbreviation"),
                            spokenUnit: UnitSpelling.spoken("min"),
                            format: { Format.minutes($0) }
                        )
                    }
                },
                footer: {
                    if state.inputs.uses(\.insulinPeakTime) {
                        Text(
                            "Without a custom peak time, Dynamic ISF uses 65 min for rapid-acting and 50 min for ultra-rapid insulin.",
                            comment: "Footer below Insulin Peak Time in the Dynamic ISF Explorer; min means minutes"
                        )
                    }
                }
            ).listRowBackground(Color.chart)
        }

        private var autosensSection: some View {
            Section(
                content: {
                    factorStepper(
                        String(localized: "Autosens Max"),
                        \.autosensMax,
                        setting: pickerSettings.autosensMax
                    )
                    factorStepper(
                        String(localized: "Autosens Min"),
                        \.autosensMin,
                        setting: pickerSettings.autosensMin
                    )
                },
                header: { Text("Autosens") }
            ).listRowBackground(Color.chart)
        }

        private var profileSection: some View {
            Section(
                content: {
                    glucoseStepper(
                        String(localized: "ISF"),
                        value: $state.sensitivityInUnits,
                        input: \.sensitivity,
                        in: Inputs.sensitivityRange,
                        unit: state.units.sensitivityUnit.displayName,
                        spokenUnit: state.units.sensitivityUnit.spokenName
                    )
                    if state.inputs.uses(\.target) {
                        glucoseStepper(
                            String(localized: "Target Glucose"),
                            value: $state.targetInUnits,
                            input: \.target,
                            in: Inputs.targetRange,
                            unit: state.units.rawValue,
                            spokenUnit: state.units.spokenValue
                        )
                    }
                },
                header: { Text("Profile") },
                footer: { Text("From your schedule for this time of day.", comment: "Footer below the profile ISF and target") }
            ).listRowBackground(Color.chart)
        }

        private var tddSection: some View {
            Section(
                content: {
                    stepper(
                        String(localized: "Last 24 Hours"),
                        value: $state.tddLast24Hours,
                        changed: state.isChanged(\.tddLast24Hours),
                        in: Inputs.tddRange,
                        step: 1,
                        unit: insulinUnit,
                        spokenUnit: UnitSpelling.spoken("U"),
                        format: { Format.insulin($0) }
                    )
                    stepper(
                        String(localized: "10-Day Average", comment: "Row for the total daily dose averaged over 10 days"),
                        value: $state.inputs.tddTenDayAverage,
                        changed: state.isChanged(\.tddTenDayAverage),
                        in: Inputs.tddRange,
                        step: 1,
                        unit: insulinUnit,
                        spokenUnit: UnitSpelling.spoken("U"),
                        format: { Format.insulin($0) }
                    )
                    factorStepper(
                        String(localized: "Weighted Average of TDD"),
                        \.weightPercentage,
                        setting: pickerSettings.weightPercentage
                    )
                    weightedTDDRow
                },
                header: { Text("Total Daily Dose") }
            ).listRowBackground(Color.chart)
        }

        /// The weighted TDD the rows above blend, marked like them when it differs from the one for the user's settings.
        private var weightedTDDRow: some View {
            let title = String(localized: "Weighted TDD", comment: "Row for the weighted average of the TDDs above")
            let weightedTDD = Format.insulin(state.inputs.weightedTDD)
            let changed = state.isWeightedTDDChanged

            return LabeledContent(title) {
                marked(Text(verbatim: "\(weightedTDD) \(insulinUnit)"), if: changed)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(spoken("\(weightedTDD) \(UnitSpelling.spoken("U"))", changed: changed))
        }

        /// Marks a value that isn't the user's setting: bold, so it doesn't rely on colour alone, and in the accent colour
        /// the Reset button takes once anything has changed.
        private func marked(_ text: Text, if changed: Bool) -> Text {
            changed ? text.bold().foregroundStyle(Color.accentColor) : text
        }

        /// A row for a value, marked when it differs from the user's setting. The value has digits of even width and the
        /// room the widest value in `range` takes, so stepping never moves it, the title or the stepper. Beside the title
        /// it stays on one line, but at the largest text sizes that room would squeeze the title until it broke
        /// mid-word, so the value goes below the title instead.
        private func stepper(
            _ title: String,
            value: Binding<Decimal>,
            changed: Bool,
            in range: ClosedRange<Decimal>,
            step: Decimal,
            unit: String,
            spokenUnit: String,
            format: (Decimal) -> String
        ) -> some View {
            let formatted = format(value.wrappedValue)
            let widest = Format.widest(in: range, format: format)
            let stacked = dynamicTypeSize >= .xxxLarge
            let shown = ZStack(alignment: stacked ? .topLeading : .trailing) {
                // Bold, as a marked value is
                ForEach(widest, id: \.self) { Text(verbatim: "\($0) \(unit)").bold().hidden() }
                marked(Text(verbatim: "\(formatted) \(unit)"), if: changed)
            }
            .monospacedDigit()

            return Stepper(value: value, in: range, step: step) {
                if stacked {
                    VStack(alignment: .leading) {
                        Text(title)
                        // A narrow screen can wrap the value here, so the widest values set its height too
                        shown
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // As a value beside its title is. A marked value keeps its own colour.
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(title) {
                        shown.fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(spoken("\(formatted) \(spokenUnit)", changed: changed))
        }

        /// What VoiceOver reads for a value, which says when it isn't the user's setting since the marking isn't spoken.
        private func spoken(_ value: String, changed: Bool) -> Text {
            changed
                ? Text("\(value), changed", comment: "Accessibility: a Dynamic ISF Explorer value that isn't the user's setting")
                : Text(verbatim: value)
        }

        private func factorStepper(
            _ title: String,
            _ keyPath: WritableKeyPath<Inputs, Decimal>,
            setting: PickerSetting
        ) -> some View {
            stepper(
                title,
                value: $state.inputs[dynamicMember: keyPath],
                changed: state.isChanged(keyPath),
                in: setting.min ... setting.max,
                step: setting.step,
                unit: String(localized: "%", comment: "Percentage symbol"),
                spokenUnit: UnitSpelling.spoken("%"),
                format: { Format.percent($0) }
            )
        }

        /// Steps a glucose value in the user's units. `value` and `range` are converted by the state model, which
        /// keeps the inputs, such as `input`, in mg/dL.
        private func glucoseStepper(
            _ title: String,
            value: Binding<Decimal>,
            input: WritableKeyPath<Inputs, Decimal>,
            in range: ClosedRange<Decimal>,
            unit: String,
            spokenUnit: String
        ) -> some View {
            let units = state.units

            return stepper(
                title,
                value: value,
                changed: state.isChanged(input),
                in: state.inUnits(range),
                step: state.glucoseStep,
                unit: unit,
                spokenUnit: spokenUnit,
                format: { Format.glucose(inUnits: $0, units: units) }
            )
        }

        private var insulinUnit: String {
            String(localized: "U", comment: "Insulin unit abbreviation")
        }
    }
}
