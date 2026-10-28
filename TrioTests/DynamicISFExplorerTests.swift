import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

@Suite("Dynamic ISF Explorer Tests") struct DynamicISFExplorerTests {
    typealias Inputs = DynamicISFExplorer.Inputs
    typealias Curve = DynamicISFExplorer.Curve
    typealias Format = DynamicISFExplorer.Format
    typealias ChartAxes = DynamicISFExplorer.ChartAxes

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

        // Ratio = ISF × AF × weighted TDD × ln(glucose / (120 - peak) + 1) / 1800
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

    @Test("Dynamic ISF adjusts between where the curve leaves its first ISF and shows its last") func adjustingRange() throws {
        let curve = try #require(Curve(inputs: inputs))
        // 60 mg/dL/U up to 90 mg/dL, and 30 from 315 mg/dL, where 30.2 shows as 30 though the limit comes at 325
        #expect(curve.adjustingRange(units: .mgdL) == 90 ... 315)
        // To 0.1 mmol/L/U, 31.4 mg/dL/U at 290 mg/dL already shows as 1.7, as 30 does
        #expect(curve.adjustingRange(units: .mmolL) == 90 ... 290)

        // A stronger factor moves it, while the curve's ends stay on the limits
        var stronger = inputs
        stronger.adjustmentFactor = 1
        let strongerCurve = try #require(Curve(inputs: stronger))
        #expect(strongerCurve.points.first?.sensitivity == 60)
        #expect(strongerCurve.points.last?.sensitivity == 30)
        #expect(strongerCurve.adjustingRange(units: .mgdL) == 55 ... 155)

        // A sigmoid curve only nears its limits, so its range ends where 30.4 shows as 30
        var sigmoid = inputs
        sigmoid.sigmoid = true
        let sigmoidCurve = try #require(Curve(inputs: sigmoid))
        #expect(sigmoidCurve.adjustingRange(units: .mgdL) == 45 ... 250)

        // None for a curve a small TDD pins to one limit throughout
        var flat = inputs
        flat.tddLast24Hours = 2
        flat.tddTenDayAverage = 2
        let flatCurve = try #require(Curve(inputs: flat))
        #expect(flatCurve.points.allSatisfy { $0.sensitivity == 60 })
        #expect(flatCurve.adjustingRange(units: .mgdL) == nil)
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

        // Ratio = (max - min) / (1 + e^-(deviation × AF × TDD ratio + ln((1 - min) / (max - 1)))) + min, with the
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

    @Test("No curve when Dynamic ISF would be off, and why") func offWithoutRoomOrTDD() {
        #expect(Curve.unavailable(for: inputs).isEmpty)

        var noRoom = inputs
        noRoom.autosensMin = 1
        noRoom.autosensMax = 1
        #expect(Curve(inputs: noRoom) == nil)
        #expect(Curve.unavailable(for: noRoom) == [.noAutosensRoom])

        var noTDD = inputs
        noTDD.tddLast24Hours = 0
        noTDD.currentTDD = 0
        noTDD.tddTenDayAverage = 0
        #expect(Curve(inputs: noTDD) == nil)
        #expect(Curve.unavailable(for: noTDD) == [.noTDD])

        noTDD.autosensMin = 1
        noTDD.autosensMax = 1
        #expect(Curve.unavailable(for: noTDD) == [.noTDD, .noAutosensRoom])

        // The TDD checked is the one the algorithm uses: the newest total at a 100% weighting, or when the weighted
        // TDD is 1 U or less
        var fullWeight = inputs
        fullWeight.weightPercentage = 1
        fullWeight.currentTDD = 0
        #expect(Curve(inputs: fullWeight) == nil)
        #expect(Curve.unavailable(for: fullWeight) == [.noTDD])

        var smallWeighted = inputs
        smallWeighted.tddLast24Hours = 0.5
        smallWeighted.tddTenDayAverage = 0.5
        smallWeighted.currentTDD = 0
        #expect(Curve(inputs: smallWeighted) == nil)
        #expect(Curve.unavailable(for: smallWeighted) == [.noTDD])

        smallWeighted.tddLast24Hours = 0
        smallWeighted.tddTenDayAverage = 0
        smallWeighted.currentTDD = 40
        #expect(Curve(inputs: smallWeighted) != nil)
        #expect(Curve.unavailable(for: smallWeighted).isEmpty)

        // Nor before your settings load
        #expect(Curve(inputs: Inputs()) == nil)
        #expect(Curve.unavailable(for: Inputs()) == [.noTDD])
    }

    @Test(
        "There's a reason exactly when there's no curve, however the TDD and Autosens limits are set",
        arguments: [false, true]
    ) func unavailableMatchesCurve(sigmoid: Bool) {
        let limits: [Decimal] = [-0.5, 0, 0.5, 0.8, 1, 1.2, 2]
        for autosensMin in limits {
            for autosensMax in limits {
                for tdd: Decimal in [0, 0.5, 40] {
                    var changed = inputs
                    changed.sigmoid = sigmoid
                    changed.autosensMin = autosensMin
                    changed.autosensMax = autosensMax
                    changed.tddLast24Hours = tdd
                    changed.currentTDD = tdd
                    changed.tddTenDayAverage = tdd
                    #expect(
                        (Curve(inputs: changed) == nil) == !Curve.unavailable(for: changed).isEmpty,
                        "min \(autosensMin), max \(autosensMax), TDD \(tdd)"
                    )
                }
            }
        }
    }

    @Test(
        "No curve, rather than a crash, with an Autosens limit of 0% or below",
        arguments: [Decimal(0), -0.5]
    ) func autosensLimitAtOrBelowZero(limit: Decimal) {
        // Only a hand-edited settings file can set one. The loop would still run Dynamic ISF, but there's no range to chart.
        var lowMin = inputs
        lowMin.autosensMin = limit
        #expect(Curve(inputs: lowMin) == nil)
        #expect(Curve.unavailable(for: lowMin) == [.noWeakestLimit])

        // Either way round, as in the algorithm
        var lowMax = inputs
        lowMax.autosensMin = 1.5
        lowMax.autosensMax = limit
        #expect(Curve(inputs: lowMax) == nil)
        #expect(Curve.unavailable(for: lowMax) == [.noWeakestLimit])

        // Listed after what turns Dynamic ISF off
        lowMax.autosensMin = limit
        #expect(Curve.unavailable(for: lowMax) == [.noAutosensRoom, .noWeakestLimit])
    }

    @Test("Each formula shows the inputs its curve uses, and only those", arguments: [
        false,
        true
    ]) func formulaInputs(sigmoid: Bool) throws {
        var base = inputs
        base.sigmoid = sigmoid
        let curve = try #require(Curve(inputs: base))

        for input in Inputs.logarithmicOnly + Inputs.sigmoidOnly {
            var changed = base
            changed[keyPath: input] *= 1.1
            let changedCurve = try #require(Curve(inputs: changed))
            let moves = changedCurve.points.map(\.sensitivity) != curve.points.map(\.sensitivity)
            #expect(moves == base.uses(input), "\(input)")
        }
        #expect(base.uses(\.sensitivity))
        #expect(base.uses(\.autosensMax))
        #expect(base.uses(\.weightPercentage))
    }

    @Test("Numbers are written as the explorer shows them") func formats() {
        let english = Locale(identifier: "en_US")
        let danish = Locale(identifier: "da_DK")

        // Glucose and ISF: whole mg/dL rounding half up, or mmol/L to 0.1
        #expect(Format.glucose(100, units: .mgdL, locale: english) == "100")
        #expect(Format.glucose(50.4, units: .mgdL, locale: english) == "50")
        #expect(Format.glucose(50.5, units: .mgdL, locale: english) == "51")
        #expect(Format.glucose(46, units: .mmolL, locale: english) == "2.6")
        #expect(Format.glucose(46, units: .mmolL, locale: danish) == "2,6")
        #expect(Format.glucose(90, units: .mmolL, locale: english) == "5.0")
        #expect(Format.glucose(inUnits: 17, units: .mmolL, locale: english) == "17.0")
        #expect(Format.glucose(inUnits: 16.9, units: .mmolL, locale: danish) == "16,9")
        #expect(Format.glucose(inUnits: 540, units: .mgdL, locale: english) == "540")

        // Insulin to 0.1 U, half to even, which the weighted TDD's change marking compares
        #expect(Format.insulin(50.25, locale: english) == "50.2")
        #expect(Format.insulin(50.75, locale: english) == "50.8")
        #expect(Format.insulin(42, locale: english) == "42")
        #expect(Format.insulin(46.4, locale: danish) == "46,4")

        // Factors as percentages, keeping a decimal off the 5% steps
        #expect(Format.percent(0.35, locale: english) == "35")
        #expect(Format.percent(1.2, locale: english) == "120")
        #expect(Format.percent(0.825, locale: danish) == "82,5")
        #expect(Format.percent(0.9234, decimals: 0, locale: english) == "92")

        #expect(Format.minutes(65, locale: english) == "65")
    }

    @Test("A row keeps room for the widest value it can show, which can have a decimal neither end has") func widest() {
        let english = Locale(identifier: "en_US")
        let danish = Locale(identifier: "da_DK")

        // A TDD of 46.4 U is wider than 300 U, and an Autosens Min off the 5% steps, such as 99.9%, wider than 100%
        #expect(Format.widest(in: Inputs.tddRange) { Format.insulin($0, locale: english) } == ["0", "300", "299.9"])
        #expect(Format.widest(in: 0.5 ... 1) { Format.percent($0, locale: danish) } == ["50", "100", "90", "99", "99,9"])
        // Glucose and minutes always show the same decimals, so their ends are widest
        #expect(Format.widest(in: 9 ... 540) { Format.glucose(inUnits: $0, units: .mgdL, locale: english) } == ["9", "540"])
        #expect(Format.widest(in: 35 ... 120) { Format.minutes($0, locale: english) } == ["35", "120"])

        // Every value a TDD or factor row can show, on its steps or off them, fits the room one of them takes. The row's
        // digits are all as wide, so a value fits where one with at least as many digits and other characters does.
        func fits(_ value: String, in widest: [String]) -> Bool {
            func digits(_ written: String) -> Int { written.filter(\.isNumber).count }
            return widest.contains { digits($0) >= digits(value) && $0.count - digits($0) >= value.count - digits(value) }
        }
        func overflowing(_ range: ClosedRange<Decimal>, by finest: Decimal, _ format: (Decimal) -> String) -> [String] {
            let widest = Format.widest(in: range, format: format)
            return stride(from: range.lowerBound, through: range.upperBound, by: finest).map(format)
                .filter { !fits($0, in: widest) }
        }
        #expect(overflowing(Inputs.tddRange, by: 0.1) { Format.insulin($0, locale: english) } == [])
        let settings = PickerSettingsProvider.shared.settings
        for setting in [
            settings.adjustmentFactor,
            settings.adjustmentFactorSigmoid,
            settings.autosensMax,
            settings.autosensMin,
            settings.weightPercentage
        ] {
            #expect(overflowing(setting.min ... setting.max, by: 0.001) { Format.percent($0, locale: english) } == [])
        }
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
        let range = Inputs.sensitivityRange
        let up = Inputs.glucose(46.asMmolL + 0.1, in: .mmolL, saved: 46, range: range)
        #expect(up == 49)
        #expect(Inputs.glucose(up.asMmolL - 0.1, in: .mmolL, saved: 46, range: range) == 46)

        #expect(Inputs.glucose(101, in: .mgdL, saved: 100, range: range) == 101)
        #expect(Inputs.glucose(100, in: .mgdL, saved: 100, range: range) == 100)
    }

    @Test("Stepped glucose stays within range after converting from mmol/L") func glucoseStepStaysInRange() {
        // 4.4 mmol/L converts to 79 mg/dL, below the loop's 80 mg/dL target floor
        #expect(Inputs.glucose(80.asMmolL, in: .mmolL, saved: 99, range: Inputs.targetRange) == 80)
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

        // Without a schedule or a loop, the defaults and no TDD
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
    ) func savedCurveMatchesLoop(_ scenario: LoopScenario) async throws {
        let preferences = loopPreferences(scenario)
        let profile = try loopProfile(scenario, preferences: preferences)
        let variables = try await loopVariables(scenario, preferences: preferences)
        let sensitivity = try #require(profile.sens)
        let glucoseSteps = Array(stride(from: Curve.glucoseRange.lowerBound, through: Curve.glucoseRange.upperBound, by: 5))

        // What determineBasal calculates at each glucose, see `DeterminationGenerator.determineBasal`
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
        // The explorer works out the weighted TDD itself, so its ratios can differ in the last few digits
        for case let (point?, loopRatio?) in zip(points, loopRatios) {
            #expect(abs(point.ratio - loopRatio) < 0.000000001, "at \(point.glucose) mg/dL")
        }
    }

    @Test("An axis fits its data with room either end, on round steps") func scale() {
        func scale(_ data: ClosedRange<Double>, spacedFor reference: ClosedRange<Double>? = nil, decimals: Int = 0)
            -> ChartAxes.Scale
        {
            ChartAxes.scale(fitting: data, spacedFor: reference ?? data, decimals: decimals)
        }

        // 27 to 63 with the margins, widened to steps of 10
        #expect(scale(30 ... 60).values == [20, 30, 40, 50, 60, 70])
        // 90 to 210, in steps of 25 rather than 50
        #expect(scale(100 ... 200).values == [75, 100, 125, 150, 175, 200, 225])
        // Never below zero
        #expect(scale(1 ... 100).values == [0, 25, 50, 75, 100, 125])
        #expect(scale(1.665 ... 3.33, decimals: 1).values == [1, 1.5, 2, 2.5, 3, 3.5])

        // Steps are written in the places the units are, so 5 rather than 2.5 for mg/dL, and 0.5 rather than 0.25
        // for mmol/L, though 2.5 is fine in mmol/L
        #expect(scale(41 ... 50).values == [40, 45, 50, 55])
        #expect(scale(2 ... 3, decimals: 1).step == 0.5)
        #expect(scale(10 ... 20, decimals: 1).step == 2.5)

        // The top edge is a gridline even where counting up in steps of 0.2 picks up Double noise
        let fifths = scale(1.665 ... 2.4975, decimals: 1)
        #expect(fifths.step == 0.2)
        #expect(fifths.values.count == 7)
        #expect(abs(fifths.domain.upperBound - 2.6) < 0.000001)

        // Gridlines spaced for the reference hold as the data grows, until there'd be too many of them
        #expect(scale(30 ... 90, spacedFor: 30 ... 60).step == 10)
        #expect(scale(30 ... 90).step == 20)
        #expect(scale(10 ... 100, spacedFor: 50 ... 55).values == [0, 20, 40, 60, 80, 100, 120])

        // A single value still gets room around it
        let single = scale(5 ... 5)
        #expect(single.domain.lowerBound < 5)
        #expect(single.domain.upperBound > 5)
    }

    @Test("The ISF axis fits both curves, with gridlines spaced for your settings") func sensitivityScale() throws {
        // Autosens Max 150% and Min 75% allow 30 to 60 mg/dL/U
        let curve = try #require(Curve(inputs: inputs))
        var weaker = inputs
        weaker.autosensMin = 0.5
        let saved = try #require(Curve(inputs: weaker))

        #expect(ChartAxes.sensitivityScale(for: curve, saved: nil, units: .mgdL).values == [
            20, 30, 40, 50, 60, 70
        ])
        // 30 to 90 between them, in steps for whichever is your settings
        #expect(ChartAxes.sensitivityScale(for: curve, saved: saved, units: .mgdL).values == [
            20, 40, 60, 80, 100
        ])
        #expect(ChartAxes.sensitivityScale(for: saved, saved: curve, units: .mgdL).values == [
            20, 30, 40, 50, 60, 70, 80, 90, 100
        ])
        #expect(ChartAxes.sensitivityScale(for: curve, saved: nil, units: .mmolL).values == [
            1, 1.5, 2, 2.5, 3, 3.5
        ])
    }

    @Test("Nearest point snaps to the closest glucose step") func nearestPoint() throws {
        let curve = try #require(Curve(inputs: inputs))

        #expect(curve.point(nearest: 102)?.glucose == 100)
        #expect(curve.point(nearest: 103)?.glucose == 105)
        #expect(curve.point(nearest: 999)?.glucose == 400)
    }

    @Test("Chart positions convert between mg/dL and the user's units") func chartPositions() throws {
        #expect(ChartAxes.plotted(100, units: .mgdL) == 100)
        #expect(abs(ChartAxes.plotted(100, units: .mmolL) - 5.55) < 0.000001)
        #expect(ChartAxes.glucose(fromPlotted: 102, units: .mgdL) == 102)
        #expect(ChartAxes.glucose(fromPlotted: 5.55, units: .mmolL) == 100)

        // A drag to 5.6 mmol/L is 101 mg/dL, nearest the 100 mg/dL point, and one to 103 mg/dL is nearest 105
        let curve = try #require(Curve(inputs: inputs))
        #expect(ChartAxes.point(atPlotted: 5.6, in: curve, units: .mmolL)?.glucose == 100)
        #expect(ChartAxes.point(atPlotted: 103, in: curve, units: .mgdL)?.glucose == 105)
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
        // A large ISF and AF keep so small a TDD off the Autosens limits
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

    /// The variables `OpenAPS.prepareTrioCustomOrefVariables` stores for these totals and preferences, read back from
    /// JSON as both the loop and the explorer read them.
    private func loopVariables(_ scenario: LoopScenario, preferences: Preferences) async throws -> TrioCustomOrefVariables {
        let coreDataStack = try await CoreDataStack.createForTests()
        let context = coreDataStack.newTaskContext()
        let now = Date()
        try await context.perform {
            func store(_ total: Decimal, minutesAgo: Int) {
                let tdd = TDDStored(context: context)
                tdd.date = now.addingTimeInterval(-Double(minutesAgo) * 60)
                tdd.total = NSDecimalNumber(decimal: total)
            }

            // Older totals an hour apart up to three hours ago, and recent ones five minutes apart up to five minutes
            // ago, well either side of the loop's two-hour cut-off
            for (index, total) in scenario.olderTDD.reversed().enumerated() {
                store(total, minutesAgo: (index + 3) * 60)
            }
            for (index, total) in scenario.recentTDD.reversed().enumerated() {
                store(total, minutesAgo: (index + 1) * 5)
            }
            try context.save()
        }

        // The loop reads the weighting from the preferences file, and nothing from the other storages
        let storage = MockFileStorage()
        storage.save(preferences, as: OpenAPS.Settings.preferences)
        let openAPS = OpenAPS(
            storage: storage,
            tddStorage: MockTDDStorage(),
            glucoseStorage: TrioApp.resolver.resolve(GlucoseStorage.self)!,
            carbsStorage: TrioApp.resolver.resolve(CarbsStorage.self)!
        )
        let rawVariables = try await openAPS.prepareTrioCustomOrefVariables(on: context)
        let variables = try JSONBridge.trioCustomOrefVariables(from: rawVariables)

        // Whether the loop found totals in the last two hours, as the scenario stored them
        #expect((variables.past2hoursAverage == 0) == scenario.recentTDD.isEmpty)
        return variables
    }
}

@Suite("Dynamic ISF Explorer State Tests") struct DynamicISFExplorerStateTests {
    let saved = DynamicISFExplorerTests.inputs

    @Test("Opening the explorer starts from your settings") func subscribe() throws {
        let state = DynamicISFExplorer.StateModel()
        // As the screen does when it appears, with the app's services
        state.resolver = TrioApp().resolver
        let preferences = state.settingsManager.preferences
        let peak = PickerSettingsProvider.shared.settings.insulinPeakTime
        // Without a saved schedule, these come from the default one, so neither falls back to the explorer's own
        let sensitivity = try #require(state.provider.sensitivity(at: Date()))
        let target = try #require(state.provider.target(at: Date()))

        #expect(state.units == state.settingsManager.settings.units)
        #expect(
            state.savedInputs == DynamicISFExplorer.Inputs(
                preferences: preferences,
                sensitivity: sensitivity,
                target: target,
                orefVariables: state.provider.orefVariables
            )
        )
        #expect(state.inputs == state.savedInputs)
        #expect(
            state.insulinPeakTimeRange == DynamicISFExplorer.Inputs.customPeak(peak.min, for: preferences.curve) ...
                DynamicISFExplorer.Inputs.customPeak(peak.max, for: preferences.curve)
        )
    }

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

    @Test("Only values that differ from your settings are marked, until Reset") func changedValues() {
        let state = loaded()
        #expect(!state.isChanged(\.adjustmentFactor))

        state.inputs.adjustmentFactor = 1
        #expect(state.isChanged(\.adjustmentFactor))
        #expect(!state.isChanged(\.insulinPeakTime))

        state.reset()
        #expect(!state.isChanged(\.adjustmentFactor))
    }

    @Test("Glucose steps in mmol/L, and stepping back lands on your setting") func glucoseStepsInUnits() {
        // 46 mg/dL/U shows as 2.6 mmol/L/U, which converts back to 47 mg/dL/U
        var saved = saved
        saved.sensitivity = 46
        let state = DynamicISFExplorer.StateModel()
        state.load(saved: saved, units: .mmolL)
        #expect(state.sensitivityInUnits == 2.6)
        #expect(state.glucoseStep == 0.1)
        #expect(state.inUnits(DynamicISFExplorer.Inputs.sensitivityRange) == 0.5 ... 30)

        state.sensitivityInUnits += 0.1
        #expect(state.inputs.sensitivity == 49)
        #expect(state.isChanged(\.sensitivity))
        state.sensitivityInUnits -= 0.1
        #expect(state.inputs.sensitivity == 46)
        #expect(!state.isChanged(\.sensitivity))

        // 4.4 mmol/L converts to 79 mg/dL, below the loop's 80 mg/dL target floor
        #expect(state.targetInUnits == 6.1)
        state.targetInUnits = 4.4
        #expect(state.inputs.target == 80)
    }

    @Test("The weighted TDD is marked only once its shown value changes") func weightedTDDChange() {
        var steady = saved
        steady.tddLast24Hours = 50.6
        steady.tddTenDayAverage = 50
        let state = DynamicISFExplorer.StateModel()
        state.load(saved: steady)

        // 50.27 U, shown as 50.3 U, becomes 50.3 U
        state.inputs.weightPercentage = 0.5
        #expect(state.inputs.weightedTDD != state.savedInputs.weightedTDD)
        #expect(!state.isWeightedTDDChanged)

        // And then 50.39 U, shown as 50.4 U
        state.inputs.weightPercentage = 0.65
        #expect(state.isWeightedTDDChanged)
    }

    @Test("Why there's no curve follows the values being explored") func unavailable() {
        let state = loaded()
        #expect(state.unavailable.isEmpty)

        state.inputs.autosensMax = state.inputs.autosensMin
        #expect(state.curve == nil)
        #expect(state.unavailable == [.noAutosensRoom])
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
        // The explored formula's own settings still count
        state.inputs.insulinPeakTime = 75
        #expect(state.hasChanges)
        #expect(state.savedCurve != nil)
        state.reset()

        state.inputs.sigmoid = true
        state.inputs.target = 120
        state.inputs.adjustmentFactorSigmoid = 0.7
        #expect(state.hasChanges)

        // Back on the saved logarithmic formula, which uses neither
        state.inputs.sigmoid = false
        #expect(!state.hasChanges)
        #expect(state.savedCurve == nil)

        // They come back with the sigmoid, and Reset clears them
        state.inputs.sigmoid = true
        #expect(state.inputs.target == 120)
        #expect(state.inputs.adjustmentFactorSigmoid == 0.7)
        #expect(state.hasChanges)
        state.reset()
        #expect(state.inputs == saved)

        // And the other way round, from a saved sigmoid
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
