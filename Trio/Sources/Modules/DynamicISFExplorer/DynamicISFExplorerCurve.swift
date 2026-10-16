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

        /// Profile ISF, before the dynamic ratio is applied.
        let profileSensitivity: Decimal
        /// The ISF range Autosens Max and Min allow, strongest to weakest.
        let sensitivityLimits: ClosedRange<Decimal>
        let points: [Point]

        /// Returns `nil` when Dynamic ISF would be off for these inputs, e.g. without any TDD
        /// or when Autosens Max and Min leave no room to adjust.
        init?(inputs: Inputs) {
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

            let variables = TrioCustomOrefVariables(inputs: inputs)

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

            // the algorithm accepts the limits either way round
            let strongest = max(inputs.autosensMin, inputs.autosensMax)
            let weakest = min(inputs.autosensMin, inputs.autosensMax)
            profileSensitivity = inputs.sensitivity
            sensitivityLimits = profileSensitivity / strongest ... profileSensitivity / weakest
            self.points = points
        }

        func point(nearest glucose: Decimal) -> Point? {
            points.min { abs($0.glucose - glucose) < abs($1.glucose - glucose) }
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
