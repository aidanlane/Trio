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
            for input in inputs.unused {
                shown[keyPath: input] = savedInputs[keyPath: input]
            }
            return shown != savedInputs
        }

        /// Whether a value differs from the user's setting, so its row can be marked. Glucose values land back on the
        /// saved mg/dL value whenever they display as it, so this matches what's shown. Writable key paths keep this to
        /// stored inputs: the weighted TDD is derived, and compared as shown by `isWeightedTDDChanged`.
        func isChanged<Value: Equatable>(_ keyPath: WritableKeyPath<Inputs, Value>) -> Bool {
            inputs[keyPath: keyPath] != savedInputs[keyPath: keyPath]
        }

        /// Whether the weighted TDD differs from the one for the user's settings, as shown: a 5% weighting step can
        /// move it by less than the 0.1 U it's rounded to.
        var isWeightedTDDChanged: Bool {
            Format.insulin(inputs.weightedTDD) != Format.insulin(savedInputs.weightedTDD)
        }

        var curve: Curve? {
            Curve(inputs: inputs)
        }

        /// Why there's no curve, for the screen to say in its place.
        var unavailable: [Curve.Unavailable] {
            Curve.unavailable(for: inputs)
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

        /// The ISF in the user's units, for stepping. A step lands back on the saved mg/dL value whenever it displays
        /// as it, so mmol/L rounding doesn't leave a change nobody can see.
        var sensitivityInUnits: Decimal {
            get { inputs.sensitivity.asUnit(units) }
            set {
                inputs.sensitivity = Inputs.glucose(
                    newValue,
                    in: units,
                    saved: savedInputs.sensitivity,
                    range: Inputs.sensitivityRange
                )
            }
        }

        /// The target in the user's units, for stepping like `sensitivityInUnits`.
        var targetInUnits: Decimal {
            get { inputs.target.asUnit(units) }
            set {
                inputs.target = Inputs.glucose(newValue, in: units, saved: savedInputs.target, range: Inputs.targetRange)
            }
        }

        var glucoseStep: Decimal {
            units == .mgdL ? 1 : 0.1
        }

        /// A range of mg/dL values in the user's units.
        func inUnits(_ range: ClosedRange<Decimal>) -> ClosedRange<Decimal> {
            range.lowerBound.asUnit(units) ... range.upperBound.asUnit(units)
        }

        override func subscribe() {
            let preferences = settingsManager.preferences
            let peakSetting = PickerSettingsProvider.shared.settings.insulinPeakTime
            let now = Date()

            let saved = Inputs(
                preferences: preferences,
                sensitivity: provider.sensitivity(at: now),
                target: provider.target(at: now),
                orefVariables: provider.orefVariables
            )
            load(saved: saved, units: settingsManager.settings.units)
            insulinPeakTimeRange = Inputs.customPeak(peakSetting.min, for: preferences.curve) ...
                Inputs.customPeak(peakSetting.max, for: preferences.curve)
            let unavailable = Curve.unavailable(for: saved)
            debug(.default, "Starting from \(saved)\(unavailable.isEmpty ? "" : "; no curve: \(unavailable)")")
        }

        /// Starts exploring from the user's settings, shown in `units`.
        func load(saved: Inputs, units: GlucoseUnits = .mgdL) {
            self.units = units
            savedInputs = saved
            inputs = saved
        }

        func reset() {
            inputs = savedInputs
        }
    }

    /// How the explorer writes its numbers, shared by its rows, chart and readout. Units are left to the caller.
    enum Format {
        /// A glucose or ISF in the user's units from its mg/dL value: whole in mg/dL and to 0.1 in mmol/L, rounding
        /// half up, as Trio's glucose formatter does.
        static func glucose(_ mgdL: Decimal, units: GlucoseUnits, locale: Locale = .current) -> String {
            glucose(inUnits: mgdL.asUnit(units), units: units, locale: locale)
        }

        /// A glucose or ISF already in the user's units, written as `glucose(_:units:locale:)` writes it.
        static func glucose(inUnits value: Decimal, units: GlucoseUnits, locale: Locale = .current) -> String {
            value.formatted(
                .number.precision(.fractionLength(units == .mgdL ? 0 : 1))
                    .rounded(rule: .toNearestOrAwayFromZero)
                    .locale(locale)
            )
        }

        /// Insulin to 0.1 U, rounding half to even. The weighted TDD is marked as changed by comparing these.
        static func insulin(_ value: Decimal, locale: Locale = .current) -> String {
            value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
        }

        /// A factor as a percentage, without the sign: 0.35 as 35. Up to `decimals` places show, so a setting off the
        /// 5% steps reads as it is.
        static func percent(_ factor: Decimal, decimals: Int = 1, locale: Locale = .current) -> String {
            (factor * 100).formatted(.number.precision(.fractionLength(0 ... decimals)).locale(locale))
        }

        /// Whole minutes.
        static func minutes(_ value: Decimal, locale: Locale = .current) -> String {
            value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        }

        /// The values in `range` that can take the most room, as `format` writes them, so a row can keep room for the
        /// widest: the ends, and the top less 0.1, 0.01 and 0.001. A value with every decimal a format shows, to 0.1 U
        /// or 0.1%, can be wider than either end, as 46.4 U is wider than 300 U.
        static func widest(in range: ClosedRange<Decimal>, format: (Decimal) -> String) -> [String] {
            let top = range.upperBound
            let values = [range.lowerBound, top, top - 0.1, top - 0.01, top - 0.001]
            var widest: [String] = []
            // Once each, as the row tells them apart by their text
            for written in values.map(format) where !widest.contains(written) {
                widest.append(written)
            }
            return widest
        }
    }
}
