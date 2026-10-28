import Foundation

extension DynamicISFExplorer {
    /// The values that shape the Dynamic ISF curve. The explorer edits a copy of these and never saves them.
    /// Glucose values are in mg/dL, as the algorithm expects.
    struct Inputs: Equatable {
        var sigmoid = false
        var adjustmentFactor: Decimal = 0.8
        var adjustmentFactorSigmoid: Decimal = 0.5
        var autosensMin: Decimal = 0.7
        var autosensMax: Decimal = 1.2
        var insulinPeakTime: Decimal = 65
        var sensitivity: Decimal = 50
        var target: Decimal = 100
        /// The mean of the 24-hour totals stored in the last two hours, which the weighted TDD blends in.
        var tddLast24Hours: Decimal = 0
        /// The newest 24-hour total, which Dynamic ISF uses instead of the weighted TDD at a 100% weighting or when
        /// that is 1 U or less.
        var currentTDD: Decimal = 0
        var tddTenDayAverage: Decimal = 0
        var weightPercentage: Decimal = 0.35

        var weightedTDD: Decimal {
            weightPercentage * tddLast24Hours + (1 - weightPercentage) * tddTenDayAverage
        }

        /// The inputs only the logarithmic formula uses: its adjustment factor and the insulin peak time.
        static let logarithmicOnly: [WritableKeyPath<Inputs, Decimal>] = [\.adjustmentFactor, \.insulinPeakTime]
        /// The inputs only the sigmoid formula uses: its adjustment factor and the target it centres on.
        static let sigmoidOnly: [WritableKeyPath<Inputs, Decimal>] = [\.adjustmentFactorSigmoid, \.target]

        /// The inputs the other formula uses, which the one being explored ignores.
        var unused: [WritableKeyPath<Inputs, Decimal>] {
            sigmoid ? Self.logarithmicOnly : Self.sigmoidOnly
        }

        /// Whether the formula being explored uses an input, so its row is shown.
        func uses(_ input: WritableKeyPath<Inputs, Decimal>) -> Bool {
            !unused.contains(input)
        }

        /// The ISF the ISF editor allows, in mg/dL/U.
        static let sensitivityRange: ClosedRange<Decimal> = 9 ... 540
        /// Targets in mg/dL: the loop raises any target below 80 to 80, and 180 is the Targets editor's maximum.
        static let targetRange: ClosedRange<Decimal> = 80 ... 180
        static let tddRange: ClosedRange<Decimal> = 0 ... 300

        /// The mg/dL value, kept within `range`, for a glucose stepped to `displayed` in the user's units. It lands
        /// back on `saved` when that is what's displayed, so mmol/L rounding doesn't leave a change nobody can see.
        static func glucose(
            _ displayed: Decimal,
            in units: GlucoseUnits,
            saved: Decimal,
            range: ClosedRange<Decimal>
        ) -> Decimal {
            guard displayed != saved.asUnit(units) else { return saved }
            let glucose = units == .mgdL ? displayed : displayed.asMgdL
            return glucose.clamp(lowerBound: range.lowerBound, upperBound: range.upperBound)
        }
    }

    /// Dynamic ISF across a range of glucose values, calculated with the same code the loop runs.
    struct Curve {
        struct Point: Identifiable {
            let glucose: Decimal
            let ratio: Decimal
            let sensitivity: Decimal

            var id: Decimal { glucose }
        }

        static let glucoseRange: ClosedRange<Decimal> = 40 ... 400

        /// Why there's no curve: Dynamic ISF would be off, by the checks `DynamicISF.calculate` makes, or its limits
        /// can't be charted.
        enum Unavailable: CaseIterable {
            /// The total daily dose it would use is zero.
            case noTDD
            /// Autosens Max and Min are equal, or both on the same side of 100%, so it has no room to adjust.
            case noAutosensRoom
            /// Autosens Max or Min is 0% or below, which only a hand-edited settings file can set. The loop would still
            /// run Dynamic ISF, but the ISF range it allows would have no weakest end to chart.
            case noWeakestLimit
        }

        /// Profile ISF, before the dynamic ratio is applied.
        let profileSensitivity: Decimal
        /// The ISF range Autosens Max and Min allow, strongest to weakest.
        let sensitivityLimits: ClosedRange<Decimal>
        let points: [Point]

        /// Returns `nil` when Dynamic ISF would be off or can't be charted, for a reason in `unavailable(for:)`.
        init?(inputs: Inputs) {
            // The algorithm accepts the limits either way round
            let strongest = max(inputs.autosensMin, inputs.autosensMax)
            let weakest = min(inputs.autosensMin, inputs.autosensMax)
            // Dividing by a limit of 0% or below would leave the ISF range without a weakest end
            guard weakest > 0 else { return nil }

            let (profile, preferences, variables) = Self.algorithmInputs(inputs)
            var points: [Point] = []
            for glucose in stride(from: Self.glucoseRange.lowerBound, through: Self.glucoseRange.upperBound, by: 5) {
                guard let result = DynamicISF.calculate(
                    profile: profile,
                    preferences: preferences,
                    currentGlucose: glucose,
                    trioCustomOrefVariables: variables
                ) else { return nil }

                let sensitivity = DeterminationGenerator.computeAdjustedSensitivity(
                    sensitivity: inputs.sensitivity,
                    sensitivityRatio: result.ratio,
                    trioCustomOrefVariables: variables
                )
                points.append(Point(glucose: glucose, ratio: result.ratio, sensitivity: sensitivity))
            }

            profileSensitivity = inputs.sensitivity
            sensitivityLimits = profileSensitivity / strongest ... profileSensitivity / weakest
            self.points = points
        }

        /// What stops a curve for these inputs: what turns Dynamic ISF off, in the order the algorithm checks, using its
        /// own TDD choice and Autosens check, then a limit too low to chart. Empty when there's a curve.
        static func unavailable(for inputs: Inputs) -> [Unavailable] {
            let (profile, preferences, variables) = algorithmInputs(inputs)
            var reasons: [Unavailable] = []
            if variables.tdd(profile: profile) <= 0 {
                reasons.append(.noTDD)
            }
            if preferences.dynamicIsfState(profile: profile, trioCustomOrefVariables: variables) == .off {
                reasons.append(.noAutosensRoom)
            }
            if min(inputs.autosensMin, inputs.autosensMax) <= 0 {
                reasons.append(.noWeakestLimit)
            }
            return reasons
        }

        /// The profile, preferences and TDD figures the algorithm reads, from the inputs.
        private static func algorithmInputs(_ inputs: Inputs) -> (Profile, Preferences, TrioCustomOrefVariables) {
            var profile = Profile()
            profile.sens = inputs.sensitivity
            profile.minBg = inputs.target
            profile.autosensMin = inputs.autosensMin
            profile.autosensMax = inputs.autosensMax
            profile.insulinPeakTime = inputs.insulinPeakTime
            profile.weightPercentage = inputs.weightPercentage

            var preferences = Preferences()
            preferences.useNewFormula = true
            preferences.sigmoid = inputs.sigmoid
            preferences.adjustmentFactor = inputs.adjustmentFactor
            preferences.adjustmentFactorSigmoid = inputs.adjustmentFactorSigmoid
            preferences.useCustomPeakTime = true

            return (profile, preferences, TrioCustomOrefVariables(inputs: inputs))
        }

        func point(nearest glucose: Decimal) -> Point? {
            points.min { abs($0.glucose - glucose) < abs($1.glucose - glucose) }
        }

        /// The glucose range, in mg/dL, over which Dynamic ISF changes the ISF as written in `units`: from the last
        /// point showing the curve's first ISF to the first showing its last. These are usually the Sensitivity
        /// Limits, which a sigmoid curve only nears, so its range ends where the limit shows. `nil` for a flat curve.
        func adjustingRange(units: GlucoseUnits) -> ClosedRange<Decimal>? {
            let shown = points.map { Format.glucose($0.sensitivity, units: units) }
            // The first point past the curve's first ISF, and the last short of its last
            guard let first = shown.first, let last = shown.last,
                  let leaving = shown.firstIndex(where: { $0 != first }),
                  let reaching = shown.lastIndex(where: { $0 != last })
            else { return nil }
            return points[leaving - 1].glucose ... points[reaching + 1].glucose
        }
    }
}

extension DynamicISFExplorer.Inputs {
    /// The user's current settings and the last loop's TDD.
    init(preferences: Preferences, sensitivity: Decimal?, target: Decimal?, orefVariables: TrioCustomOrefVariables?) {
        let defaults = Self()
        self.init(
            sigmoid: preferences.sigmoid,
            adjustmentFactor: preferences.adjustmentFactor,
            adjustmentFactorSigmoid: preferences.adjustmentFactorSigmoid,
            autosensMin: preferences.autosensMin,
            autosensMax: preferences.autosensMax,
            insulinPeakTime: Self.insulinPeakTime(for: preferences),
            sensitivity: sensitivity ?? defaults.sensitivity,
            target: target ?? defaults.target,
            tddLast24Hours: orefVariables?.past2hoursAverage ?? 0,
            currentTDD: orefVariables?.currentTDD ?? 0,
            tddTenDayAverage: orefVariables?.average_total_data ?? 0,
            weightPercentage: preferences.weightPercentage
        )
    }

    /// A custom peak time as the profile clamps it for the insulin curve.
    static func customPeak(_ peak: Decimal, for curve: InsulinCurve) -> Decimal {
        IobCalculation.lookupPeak(curve: curve, useCustomPeakTime: true, insulinPeakTime: peak).map { Decimal($0) } ?? peak
    }

    /// The peak time Dynamic ISF uses: fixed per curve without a custom peak (see `DynamicISF.calculate`),
    /// otherwise the custom peak as the profile clamps it.
    private static func insulinPeakTime(for preferences: Preferences) -> Decimal {
        guard preferences.useCustomPeakTime else { return preferences.curve == .ultraRapid ? 50 : 65 }
        return customPeak(preferences.insulinPeakTime, for: preferences.curve)
    }
}

private extension TrioCustomOrefVariables {
    /// Only the TDD values Dynamic ISF reads; everything else is left neutral.
    init(inputs: DynamicISFExplorer.Inputs) {
        self.init(
            average_total_data: inputs.tddTenDayAverage,
            weightedAverage: inputs.weightedTDD,
            currentTDD: inputs.currentTDD,
            past2hoursAverage: inputs.tddLast24Hours,
            date: Date(),
            overridePercentage: 100,
            useOverride: false,
            duration: 0,
            unlimited: true,
            overrideTarget: 0,
            smbIsOff: false,
            advancedSettings: false,
            isfAndCr: false,
            isf: false,
            cr: false,
            smbIsScheduledOff: false,
            start: 0,
            end: 0,
            smbMinutes: 0,
            uamMinutes: 0
        )
    }
}
