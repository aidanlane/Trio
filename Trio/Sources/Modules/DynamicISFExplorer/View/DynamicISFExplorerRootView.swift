import SwiftUI
import Swinject

extension DynamicISFExplorer {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private let pickerSettings = PickerSettingsProvider.shared.settings

        private var sensitivityUnit: TherapySettingUnit {
            state.units == .mgdL ? .mgdLPerUnit : .mmolLPerUnit
        }

        var body: some View {
            List {
                Section(
                    content: {
                        if let curve = state.curve {
                            DynamicISFExplorerChart(curve: curve, savedCurve: state.savedCurve, units: state.units)
                                .padding(.vertical)
                        } else {
                            Text(
                                "Dynamic ISF cannot be calculated with these values. It needs a total daily dose above zero and an Autosens Max of at least 100%, with Autosens Min below it."
                            )
                            .foregroundStyle(.secondary)
                        }
                    },
                    footer: {
                        Text(
                            "Shows what Dynamic ISF does when enabled and active. Starts from your current settings and TDD. Does not consider overrides or temp targets. Changes here are not saved."
                        )
                    }
                ).listRowBackground(Color.chart)

                Section(
                    content: {
                        Picker("Formula", selection: $state.inputs.sigmoid) {
                            Text("Logarithmic").tag(false)
                            Text("Sigmoid").tag(true)
                        }
                        .pickerStyle(.segmented)

                        if state.inputs.sigmoid {
                            factorStepper(
                                String(localized: "Sigmoid Adjustment Factor"),
                                value: $state.inputs.adjustmentFactorSigmoid,
                                setting: pickerSettings.adjustmentFactorSigmoid
                            )
                        } else {
                            factorStepper(
                                String(localized: "Adjustment Factor (AF)"),
                                value: $state.inputs.adjustmentFactor,
                                setting: pickerSettings.adjustmentFactor
                            )
                            stepper(
                                String(localized: "Insulin Peak Time"),
                                value: $state.inputs.insulinPeakTime,
                                in: state.insulinPeakTimeRange,
                                step: pickerSettings.insulinPeakTime.step,
                                formatted: "\(state.inputs.insulinPeakTime)",
                                unit: String(localized: "min", comment: "Minutes abbreviation"),
                                spokenUnit: UnitSpelling.spoken("min")
                            )
                        }
                    },
                    header: { Text("Dynamic ISF") },
                    footer: {
                        if !state.inputs.sigmoid {
                            Text(
                                "Without a custom peak time, Dynamic ISF uses 65 min for rapid-acting and 50 min for ultra-rapid insulin."
                            )
                        }
                    }
                ).listRowBackground(Color.chart)

                Section(header: Text("Autosens")) {
                    factorStepper(
                        String(localized: "Autosens Max"),
                        value: $state.inputs.autosensMax,
                        setting: pickerSettings.autosensMax
                    )
                    factorStepper(
                        String(localized: "Autosens Min"),
                        value: $state.inputs.autosensMin,
                        setting: pickerSettings.autosensMin
                    )
                }.listRowBackground(Color.chart)

                Section(
                    header: Text("Profile"),
                    footer: Text("From your schedule for this time of day.")
                ) {
                    glucoseStepper(
                        String(localized: "Insulin Sensitivity"),
                        \.sensitivity,
                        in: 9 ... 540,
                        unit: sensitivityUnit.displayName,
                        spokenUnit: sensitivityUnit.spokenName
                    )
                    if state.inputs.sigmoid {
                        // the loop raises any target below 80 mg/dL to 80
                        glucoseStepper(
                            String(localized: "Target Glucose"),
                            \.target,
                            in: 80 ... 180,
                            unit: state.units.rawValue,
                            spokenUnit: state.units.spokenValue
                        )
                    }
                }.listRowBackground(Color.chart)

                Section(
                    header: Text("Total Daily Dose"),
                    footer: Text("Weighted TDD: \(insulin(state.inputs.weightedTDD)) \(insulinUnit)")
                        .accessibilityLabel(
                            Text("Weighted TDD: \(insulin(state.inputs.weightedTDD)) \(UnitSpelling.spoken("U"))")
                        )
                ) {
                    stepper(
                        String(localized: "Last 24 Hours"),
                        value: $state.tddLast24Hours,
                        in: 0 ... 300,
                        step: 1,
                        formatted: insulin(state.inputs.tddLast24Hours),
                        unit: insulinUnit,
                        spokenUnit: UnitSpelling.spoken("U")
                    )
                    stepper(
                        String(localized: "10-Day Average"),
                        value: $state.inputs.tddTenDayAverage,
                        in: 0 ... 300,
                        step: 1,
                        formatted: insulin(state.inputs.tddTenDayAverage),
                        unit: insulinUnit,
                        spokenUnit: UnitSpelling.spoken("U")
                    )
                    factorStepper(
                        String(localized: "Weighted Average of TDD"),
                        value: $state.inputs.weightPercentage,
                        setting: pickerSettings.weightPercentage
                    )
                }.listRowBackground(Color.chart)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Dynamic ISF Explorer")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset", action: state.reset)
                        .disabled(!state.hasChanges)
                }
            }
        }

        private func stepper(
            _ title: String,
            value: Binding<Decimal>,
            in range: ClosedRange<Decimal>,
            step: Decimal,
            formatted: String,
            unit: String,
            spokenUnit: String
        ) -> some View {
            Stepper(value: value, in: range, step: step) {
                LabeledContent(title, value: "\(formatted) \(unit)")
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: "\(formatted) \(spokenUnit)"))
        }

        private func factorStepper(_ title: String, value: Binding<Decimal>, setting: PickerSetting) -> some View {
            stepper(
                title,
                value: value,
                in: setting.min ... setting.max,
                step: setting.step,
                formatted: "\(value.wrappedValue * 100)",
                unit: String(localized: "%", comment: "Percentage symbol"),
                spokenUnit: UnitSpelling.spoken("%")
            )
        }

        /// Steps through glucose values in the user's units while the inputs stay in mg/dL.
        private func glucoseStepper(
            _ title: String,
            _ keyPath: WritableKeyPath<Inputs, Decimal>,
            in range: ClosedRange<Decimal>,
            unit: String,
            spokenUnit: String
        ) -> some View {
            let units = state.units
            let displayed = Binding(
                get: { state.inputs[keyPath: keyPath].asUnit(units) },
                set: {
                    let saved = state.savedInputs[keyPath: keyPath]
                    state.inputs[keyPath: keyPath] = Inputs.glucose($0, in: units, saved: saved, range: range)
                }
            )

            return stepper(
                title,
                value: displayed,
                in: range.lowerBound.asUnit(units) ... range.upperBound.asUnit(units),
                step: units == .mgdL ? 1 : 0.1,
                formatted: NumberFormatter.glucoseFormatter(for: units).string(from: displayed.wrappedValue as NSNumber) ?? "",
                unit: unit,
                spokenUnit: spokenUnit
            )
        }

        private var insulinUnit: String {
            String(localized: "U", comment: "Insulin unit abbreviation")
        }

        private func insulin(_ value: Decimal) -> String {
            value.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
    }
}
