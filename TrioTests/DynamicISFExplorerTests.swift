import Foundation
import Testing

@testable import Trio

@Suite("Dynamic ISF Explorer Tests") struct DynamicISFExplorerTests {
    typealias Inputs = DynamicISFExplorer.Inputs
    typealias Curve = DynamicISFExplorer.Curve

    /// None of these are defaults or the fixed peak times, so a value that never reaches the algorithm fails a test.
    static let inputs = Inputs(
        sigmoid: false,
        adjustmentFactor: 0.7,
        adjustmentFactorSigmoid: 0.6,
        autosensMin: 0.75,
        autosensMax: 1.5,
        insulinPeakTime: 60,
        sensitivity: 45,
        target: 110,
        tddLast24Hours: 42,
        currentTDD: 40,
        tddTenDayAverage: 50,
        weightPercentage: 0.45
    )

    let inputs = Self.inputs

    @Test("Weighted TDD blends the last 24 hours with the 10-day average") func weightedTDD() {
        #expect(inputs.weightedTDD == 46.4)
    }

    @Test("Logarithmic curve matches the Dynamic ISF formula") func logarithmicFormula() throws {
        let curve = try #require(Curve(inputs: inputs))
        let point = try #require(curve.points.first { $0.glucose == 120 })

        // ratio = ISF × AF × weighted TDD × ln(glucose / (120 - peak) + 1) / 1800
        let expected = 45 * 0.7 * 46.4 * Foundation.log(120.0 / 60 + 1) / 1800
        #expect(abs(Double(truncating: point.ratio as NSNumber) - expected) < 0.0001)
        #expect(point.sensitivity == 50.4)
    }

    @Test("At 100% weighting the curve uses the newest 24-hour total, as the loop does") func fullWeightUsesCurrentTDD() throws {
        var inputs = inputs
        inputs.weightPercentage = 1

        let curve = try #require(Curve(inputs: inputs))
        let point = try #require(curve.points.first { $0.glucose == 120 })

        let expected = 45 * 0.7 * 40 * Foundation.log(120.0 / 60 + 1) / 1800
        #expect(abs(Double(truncating: point.ratio as NSNumber) - expected) < 0.0001)
        #expect(point.sensitivity == 58.5)
    }

    @Test("Curve is clamped to the Autosens limits") func clampedToAutosensLimits() throws {
        let curve = try #require(Curve(inputs: inputs))

        #expect(curve.points.first?.glucose == 40)
        #expect(curve.points.first?.ratio == 0.75)
        #expect(curve.points.first?.sensitivity == 60)
        #expect(curve.points.last?.glucose == 400)
        #expect(curve.points.last?.ratio == 1.5)
        #expect(curve.points.last?.sensitivity == 30)
        #expect(curve.profileSensitivity == 45)
        #expect(curve.sensitivityLimits == 30 ... 60)
    }

    @Test("Sigmoid curve crosses the profile ISF at the target") func sigmoidCrossesProfileAtTarget() throws {
        var inputs = inputs
        inputs.sigmoid = true

        let curve = try #require(Curve(inputs: inputs))
        let atTarget = try #require(curve.points.first { $0.glucose == 110 })

        #expect(abs(atTarget.ratio - 1) < 0.001)
        #expect(atTarget.sensitivity == 45)
    }

    @Test("Sigmoid curve matches the Dynamic ISF formula away from the target") func sigmoidFormula() throws {
        var inputs = inputs
        inputs.sigmoid = true
        let curve = try #require(Curve(inputs: inputs))

        // ratio = (max - min) / (1 + e^-(deviation × AF × TDD ratio + ln((1 - min) / (max - 1)))) + min, with the
        // deviation in mmol/L and the TDD ratio = weighted TDD / 10-day average = 46.4 / 50, rounded to 0.93
        func expected(_ glucose: Double) -> Double {
            let exponent = (glucose - 110) * 0.0555 * 0.6 * 0.93 + Foundation.log(0.25 / 0.5)
            return 0.75 / (1 + Foundation.exp(-exponent)) + 0.75
        }
        let low = try #require(curve.points.first { $0.glucose == 70 })
        let high = try #require(curve.points.first { $0.glucose == 180 })

        #expect(abs(Double(truncating: low.ratio as NSNumber) - expected(70)) < 0.0001)
        #expect(low.sensitivity == 53.3)
        #expect(abs(Double(truncating: high.ratio as NSNumber) - expected(180)) < 0.0001)
        #expect(high.sensitivity == 33.1)
    }

    @Test("No curve when Dynamic ISF would be off") func offWithoutRoomOrTDD() {
        var noRoom = inputs
        noRoom.autosensMin = 1
        noRoom.autosensMax = 1
        #expect(Curve(inputs: noRoom) == nil)

        var noTDD = inputs
        noTDD.tddLast24Hours = 0
        noTDD.currentTDD = 0
        noTDD.tddTenDayAverage = 0
        #expect(Curve(inputs: noTDD) == nil)

        // nor before your settings load
        #expect(Curve(inputs: Inputs()) == nil)
    }

    @Test("Autosens limits work either way round, as in the algorithm") func swappedAutosensLimits() throws {
        var swapped = inputs
        swapped.autosensMin = 1
        swapped.autosensMax = 0.9

        let curve = try #require(Curve(inputs: swapped))

        #expect(curve.sensitivityLimits == 45 ... 50)
        #expect(curve.points.allSatisfy { (0.9 ... 1).contains($0.ratio) })
    }

    @Test("Stepping glucose in mmol/L lands back on the saved mg/dL value") func glucoseStepRoundTrip() {
        let range: ClosedRange<Decimal> = 9 ... 540
        let up = Inputs.glucose(46.asMmolL + 0.1, in: .mmolL, saved: 46, range: range)
        #expect(up == 49)
        #expect(Inputs.glucose(up.asMmolL - 0.1, in: .mmolL, saved: 46, range: range) == 46)

        #expect(Inputs.glucose(101, in: .mgdL, saved: 100, range: range) == 101)
        #expect(Inputs.glucose(100, in: .mgdL, saved: 100, range: range) == 100)
    }

    @Test("Stepped glucose stays within range after converting from mmol/L") func glucoseStepStaysInRange() {
        // 4.4 mmol/L converts to 79 mg/dL, below the loop's 80 mg/dL target floor
        #expect(Inputs.glucose(80.asMmolL, in: .mmolL, saved: 99, range: 80 ... 180) == 80)
    }

    @Test("Saved inputs come from your settings, schedule and the last loop") func savedInputs() {
        var preferences = Preferences()
        preferences.sigmoid = true
        preferences.adjustmentFactor = 0.7
        preferences.adjustmentFactorSigmoid = 0.6
        preferences.autosensMin = 0.75
        preferences.autosensMax = 1.5
        preferences.weightPercentage = 0.45
        preferences.useCustomPeakTime = true
        preferences.insulinPeakTime = 60

        var expected = inputs
        expected.sigmoid = true
        #expect(Inputs(preferences: preferences, sensitivity: 45, target: 110, orefVariables: variables()) == expected)

        // without a schedule or a loop, the defaults and no TDD
        expected.sensitivity = Inputs().sensitivity
        expected.target = Inputs().target
        expected.tddLast24Hours = 0
        expected.currentTDD = 0
        expected.tddTenDayAverage = 0
        #expect(Inputs(preferences: preferences, sensitivity: nil, target: nil, orefVariables: nil) == expected)
    }

    @Test("Custom peak times are clamped as the profile clamps them") func customPeak() {
        #expect(Inputs.customPeak(35, for: .rapidActing) == 50)
        #expect(Inputs.customPeak(90, for: .rapidActing) == 90)
        #expect(Inputs.customPeak(120, for: .rapidActing) == 120)
        #expect(Inputs.customPeak(35, for: .ultraRapid) == 35)
        #expect(Inputs.customPeak(120, for: .ultraRapid) == 100)
        #expect(Inputs.customPeak(35, for: .bilinear) == 35)
        #expect(Inputs.customPeak(120, for: .bilinear) == 120)
    }

    @Test(
        "The saved curve is the loop's Dynamic ISF at every glucose",
        arguments: loopScenarios
    ) func savedCurveMatchesLoop(_ scenario: LoopScenario) throws {
        let preferences = loopPreferences(scenario)
        let profile = try loopProfile(scenario, preferences: preferences)
        let variables = try loopVariables(scenario)
        let sensitivity = try #require(profile.sens)
        let glucoseSteps = Array(stride(from: Curve.glucoseRange.lowerBound, through: Curve.glucoseRange.upperBound, by: 5))

        // what determineBasal calculates at each glucose, see `DeterminationGenerator.determineBasal`
        let loopRatios = glucoseSteps.map { glucose in
            DynamicISF.calculate(
                profile: profile,
                preferences: preferences,
                currentGlucose: glucose,
                trioCustomOrefVariables: variables
            ).map(\.ratio)
        }
        let loopSensitivities = loopRatios.map { ratio in
            ratio.map {
                DeterminationGenerator.computeAdjustedSensitivity(
                    sensitivity: sensitivity,
                    sensitivityRatio: $0,
                    trioCustomOrefVariables: variables
                )
            }
        }

        let saved = Inputs(preferences: preferences, sensitivity: sensitivity, target: Self.loopTarget, orefVariables: variables)
        let curve = Curve(inputs: saved)
        let points = glucoseSteps.map { glucose in curve?.points.first { $0.glucose == glucose } }

        #expect(loopRatios.allSatisfy { ($0 == nil) == scenario.isOff })
        #expect(points.map { $0?.sensitivity } == loopSensitivities)
        // the explorer works out the weighted TDD itself, so its ratios can differ in the last few digits
        for case let (point?, loopRatio?) in zip(points, loopRatios) {
            #expect(abs(point.ratio - loopRatio) < 0.000000001, "at \(point.glucose) mg/dL")
        }
    }

    @Test("The ISF axis rounds up to a step that grows with it") func sensitivityAxisTop() {
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 71.43, units: .mgdL) == 90)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 142.86, units: .mgdL) == 175)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 270, units: .mgdL) == 350)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 360, units: .mgdL) == 500)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 428.6, units: .mgdL) == 500)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 100 / 1.15, units: .mgdL) == 100)
        // Decimal-to-Double noise just above a step doesn't add another
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: (100 / 1.15).nextUp, units: .mgdL) == 100)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 3.5, units: .mmolL) == 4.5)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 3.964, units: .mmolL) == 5)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 7.86, units: .mmolL) == 10)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 12, units: .mmolL) == 14)
        #expect(DynamicISFExplorerChart.sensitivityAxisTop(fitting: 20, units: .mmolL) == 25)
    }

    @Test("Nearest point snaps to the closest glucose step") func nearestPoint() throws {
        let curve = try #require(Curve(inputs: inputs))

        #expect(curve.point(nearest: 102)?.glucose == 100)
        #expect(curve.point(nearest: 103)?.glucose == 105)
        #expect(curve.point(nearest: 999)?.glucose == 400)
    }

    private func variables() -> TrioCustomOrefVariables {
        TrioCustomOrefVariables(
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
            smbMinutes: 30,
            uamMinutes: 30
        )
    }

    struct LoopScenario: CustomTestStringConvertible, Sendable {
        var name: String
        var sensitivity: Decimal = 46
        var adjustmentFactor: Decimal = 0.65
        var curve: InsulinCurve = .rapidActing
        var customPeak: Decimal?
        var sigmoid = false
        var weightPercentage: Decimal = 0.45
        var autosensMin: Decimal = 0.7
        var autosensMax: Decimal = 1.3
        /// 24-hour totals stored before the last two hours, oldest first
        var olderTDD: [Decimal] = [52.4, 49.8, 51.3]
        /// 24-hour totals stored in the last two hours, oldest first, so the last is the loop's newest total
        var recentTDD: [Decimal] = [44.1, 45.6, 47.3]
        /// Whether the loop skips Dynamic ISF in this scenario
        var isOff = false

        var testDescription: String { name }
    }

    static let loopScenarios = [
        LoopScenario(name: "Rapid-acting without a custom peak"),
        LoopScenario(name: "Ultra-rapid without a custom peak", curve: .ultraRapid),
        LoopScenario(name: "Bilinear without a custom peak", curve: .bilinear),
        LoopScenario(name: "Custom peak", customPeak: 70),
        LoopScenario(name: "Custom peak below the rapid-acting range", customPeak: 40),
        LoopScenario(name: "Custom peak above the ultra-rapid range", curve: .ultraRapid, customPeak: 110),
        LoopScenario(name: "Bilinear custom peak, which the profile doesn't clamp", curve: .bilinear, customPeak: 40),
        LoopScenario(name: "100% weight uses the newest 24-hour total", weightPercentage: 1),
        // a large ISF and AF keep so small a TDD off the Autosens limits
        LoopScenario(
            name: "A weighted TDD of 1 U or less uses the newest 24-hour total",
            sensitivity: 540,
            adjustmentFactor: 3,
            olderTDD: [1.2, 0.6],
            recentTDD: [0.5, 0.9]
        ),
        LoopScenario(name: "No TDD stored in the last two hours", recentTDD: []),
        LoopScenario(name: "No TDD stored in the last two hours, at 100% weight", weightPercentage: 1, recentTDD: []),
        LoopScenario(name: "No TDD stored", olderTDD: [], recentTDD: [], isOff: true),
        LoopScenario(name: "Sigmoid", sigmoid: true),
        LoopScenario(name: "Sigmoid at 100% weight", sigmoid: true, weightPercentage: 1),
        LoopScenario(name: "Autosens limits either way round", autosensMin: 1.3, autosensMax: 0.7),
        LoopScenario(name: "Autosens Max and Min both 100%", autosensMin: 1, autosensMax: 1, isOff: true),
        LoopScenario(name: "Autosens Max equal to Min", autosensMin: 1.2, autosensMax: 1.2, isOff: true),
        LoopScenario(name: "Autosens Min above 100%", autosensMin: 1.1, isOff: true),
        LoopScenario(name: "Autosens Max below 100%", autosensMax: 0.9, isOff: true)
    ]

    /// The target in the loop's schedule, which the explorer reads as the saved target.
    private static let loopTarget: Decimal = 110

    private func loopPreferences(_ scenario: LoopScenario) -> Preferences {
        var preferences = Preferences()
        preferences.useNewFormula = true
        preferences.sigmoid = scenario.sigmoid
        preferences.adjustmentFactor = scenario.adjustmentFactor
        preferences.adjustmentFactorSigmoid = 0.35
        preferences.autosensMin = scenario.autosensMin
        preferences.autosensMax = scenario.autosensMax
        preferences.curve = scenario.curve
        preferences.useCustomPeakTime = scenario.customPeak != nil
        preferences.insulinPeakTime = scenario.customPeak ?? preferences.insulinPeakTime
        preferences.weightPercentage = scenario.weightPercentage
        return preferences
    }

    /// The profile `OpenAPS.createProfiles` makes from one-entry schedules, targeting `loopTarget`.
    private func loopProfile(_ scenario: LoopScenario, preferences: Preferences) throws -> Profile {
        try ProfileGenerator.generate(
            pumpSettings: PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2),
            bgTargets: BGTargets(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                targets: [BGTargetEntry(low: Self.loopTarget, high: Self.loopTarget, start: "00:00", offset: 0)]
            ),
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            isf: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: scenario.sensitivity, offset: 0, start: "00:00")]
            ),
            preferences: preferences,
            carbRatios: CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00", offset: 0, ratio: 10)]),
            tempTargets: [],
            clock: Date()
        )
    }

    /// The variables `OpenAPS.prepareTrioCustomOrefVariables` stores for these totals, read back from JSON as both the
    /// loop and the explorer read them.
    private func loopVariables(_ scenario: LoopScenario) throws -> TrioCustomOrefVariables {
        let totals = scenario.olderTDD + scenario.recentTDD
        let currentTDD = totals.last ?? 0
        let averageTDDLastTwoHours = scenario.recentTDD.reduce(0, +) / Decimal(max(scenario.recentTDD.count, 1))
        let averageTDDLastTenDays = totals.reduce(0, +) / Decimal(max(totals.count, 1))
        let weightedTDD = scenario.weightPercentage * averageTDDLastTwoHours +
            (1 - scenario.weightPercentage) * averageTDDLastTenDays

        let variables = TrioCustomOrefVariables(
            average_total_data: currentTDD > 0 ? averageTDDLastTenDays : 0,
            weightedAverage: currentTDD > 0 ? weightedTDD : 1,
            currentTDD: currentTDD,
            past2hoursAverage: currentTDD > 0 ? averageTDDLastTwoHours : 0,
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
            smbMinutes: 30,
            uamMinutes: 30
        )
        return try #require(TrioCustomOrefVariables(from: variables.rawJSON))
    }
}

@Suite("Dynamic ISF Explorer State Tests") struct DynamicISFExplorerStateTests {
    let saved = DynamicISFExplorerTests.inputs

    @Test("Loading starts from the saved inputs") func load() {
        let state = DynamicISFExplorer.StateModel()
        state.load(saved: saved)

        #expect(state.inputs == saved)
        #expect(state.savedInputs == saved)
        #expect(!state.hasChanges)
    }

    @Test("Stepping the last 24 hours moves both 24-hour totals, and stepping back restores them") func tddStepRoundTrip() {
        let state = loaded()
        #expect(state.tddLast24Hours == 42)

        state.tddLast24Hours = 43
        #expect(state.tddLast24Hours == 43)
        #expect(state.inputs.tddLast24Hours == 43)
        #expect(state.inputs.currentTDD == 43)
        #expect(state.hasChanges)

        state.tddLast24Hours = 42
        #expect(state.tddLast24Hours == 42)
        #expect(state.inputs.currentTDD == 40)
        #expect(!state.hasChanges)
    }

    @Test("The curve for your settings appears once something changes, until Reset") func savedCurveAndReset() throws {
        let state = loaded()
        #expect(state.savedCurve == nil)

        state.inputs.adjustmentFactor = 1
        #expect(state.hasChanges)
        let savedPoint = try #require(state.savedCurve?.points.first { $0.glucose == 120 })
        let exploredPoint = try #require(state.curve?.points.first { $0.glucose == 120 })
        #expect(savedPoint.sensitivity == 50.4)
        #expect(exploredPoint.sensitivity == 35.3)

        state.reset()
        #expect(state.inputs == saved)
        #expect(!state.hasChanges)
        #expect(state.savedCurve == nil)
    }

    @Test("Edits to the other formula's settings don't count while its steppers are hidden") func hiddenFormulaEdits() {
        let state = loaded()
        // the explored formula's own settings still count
        state.inputs.insulinPeakTime = 75
        #expect(state.hasChanges)
        #expect(state.savedCurve != nil)
        state.reset()

        state.inputs.sigmoid = true
        state.inputs.target = 120
        state.inputs.adjustmentFactorSigmoid = 0.7
        #expect(state.hasChanges)

        // back on the saved logarithmic formula, which uses neither
        state.inputs.sigmoid = false
        #expect(!state.hasChanges)
        #expect(state.savedCurve == nil)

        // they come back with the sigmoid, and Reset clears them
        state.inputs.sigmoid = true
        #expect(state.inputs.target == 120)
        #expect(state.inputs.adjustmentFactorSigmoid == 0.7)
        #expect(state.hasChanges)
        state.reset()
        #expect(state.inputs == saved)

        // and the other way round, from a saved sigmoid
        var sigmoid = saved
        sigmoid.sigmoid = true
        state.load(saved: sigmoid)
        state.inputs.target = 120
        #expect(state.hasChanges)
        state.reset()
        state.inputs.adjustmentFactorSigmoid = 0.7
        #expect(state.hasChanges)
        state.reset()

        state.inputs.sigmoid = false
        state.inputs.adjustmentFactor = 1
        state.inputs.insulinPeakTime = 75
        #expect(state.hasChanges)
        state.inputs.sigmoid = true
        #expect(!state.hasChanges)
        #expect(state.savedCurve == nil)
    }

    private func loaded() -> DynamicISFExplorer.StateModel {
        let state = DynamicISFExplorer.StateModel()
        state.load(saved: saved)
        return state
    }
}
