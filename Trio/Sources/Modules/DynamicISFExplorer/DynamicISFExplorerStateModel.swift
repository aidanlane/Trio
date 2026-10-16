import Foundation

extension DynamicISFExplorer {
    final class StateModel: BaseStateModel<Provider> {
        @Published var inputs = Inputs()

        private(set) var savedInputs = Inputs()
        private(set) var units: GlucoseUnits = .mgdL
        /// The custom peak times the loop accepts for the user's insulin curve.
        private(set) var insulinPeakTimeRange: ClosedRange<Decimal> = 35 ... 120

        /// Whether anything shown differs from the user's settings. Edits to the formula not being explored don't count:
        /// its steppers are hidden and neither curve uses them. They're kept, and count again on switching back to it.
        var hasChanges: Bool {
            var shown = inputs
            if inputs.sigmoid {
                shown.adjustmentFactor = savedInputs.adjustmentFactor
                shown.insulinPeakTime = savedInputs.insulinPeakTime
            } else {
                shown.adjustmentFactorSigmoid = savedInputs.adjustmentFactorSigmoid
                shown.target = savedInputs.target
            }
            return shown != savedInputs
        }

        var curve: Curve? {
            Curve(inputs: inputs)
        }

        /// The curve for the user's actual settings, shown for comparison once something has been changed.
        var savedCurve: Curve? {
            hasChanges ? Curve(inputs: savedInputs) : nil
        }

        /// The last 24 hours' TDD. An edit stands for both of the loop's 24-hour figures, and stepping back to the
        /// saved value restores the saved newest total, so nothing reads as changed.
        var tddLast24Hours: Decimal {
            get { inputs.tddLast24Hours }
            set {
                inputs.tddLast24Hours = newValue
                inputs.currentTDD = newValue == savedInputs.tddLast24Hours ? savedInputs.currentTDD : newValue
            }
        }

        override func subscribe() {
            units = settingsManager.settings.units

            let preferences = settingsManager.preferences
            let peakSetting = PickerSettingsProvider.shared.settings.insulinPeakTime
            let now = Date()

            load(
                saved: Inputs(
                    preferences: preferences,
                    sensitivity: provider.sensitivity(at: now),
                    target: provider.target(at: now),
                    orefVariables: provider.orefVariables
                )
            )
            insulinPeakTimeRange = Inputs.customPeak(peakSetting.min, for: preferences.curve) ...
                Inputs.customPeak(peakSetting.max, for: preferences.curve)
        }

        /// Starts exploring from the user's settings.
        func load(saved: Inputs) {
            savedInputs = saved
            inputs = saved
        }

        func reset() {
            inputs = savedInputs
        }
    }
}
