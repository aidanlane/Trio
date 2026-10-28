import Foundation

extension DynamicISFExplorer {
    /// Where the chart plots glucose and ISF, in the user's units, and the gridlines on its ISF axis.
    enum ChartAxes {
        /// An axis's gridlines, a whole number of steps apart, from its bottom edge to its top.
        struct Scale: Equatable {
            let step: Decimal
            let values: [Double]

            var domain: ClosedRange<Double> {
                values[0] ... values[values.count - 1]
            }

            /// The whole steps that cover `range`, at least one of them.
            init(covering range: ClosedRange<Double>, step: Decimal) {
                let size = Double(truncating: step as NSNumber)
                // The epsilons keep Double noise from adding a whole step
                let lowest = Int(((range.lowerBound / size) + 1E-9).rounded(.down))
                let highest = max(Int(((range.upperBound / size) - 1E-9).rounded(.up)), lowest + 1)
                self.step = step
                // Counted in exact steps, so the edges are gridlines without any noise to drop them
                values = (lowest ... highest).map { Double(truncating: (Decimal($0) * step) as NSNumber) }
            }
        }

        /// The ISF axis, fitted to the Sensitivity Limits of both curves, which hold the curves and the profile ISF. Its
        /// gridlines are spaced for the user's settings, so they hold while exploring.
        static func sensitivityScale(for curve: Curve, saved: Curve?, units: GlucoseUnits) -> Scale {
            let settings = (saved ?? curve).sensitivityLimits
            let limits = min(curve.sensitivityLimits.lowerBound, settings.lowerBound) ...
                max(curve.sensitivityLimits.upperBound, settings.upperBound)
            return scale(
                fitting: plotted(limits.lowerBound, units: units) ... plotted(limits.upperBound, units: units),
                spacedFor: plotted(settings.lowerBound, units: units) ... plotted(settings.upperBound, units: units),
                decimals: units == .mgdL ? 0 : 1
            )
        }

        /// An axis fitting `data` with a tenth of its span spare at each end, in whole steps so its edges and gridlines
        /// land on round values. The step suits `reference` with about `intervals` of them, and is only coarsened once
        /// `data` would need more than `maxIntervals`, so the gridlines hold while `data` grows and stepping back restores
        /// them. Steps are 1, 2, 2.5 or 5 times a power of ten, written in no more than `decimals` places. It never goes
        /// below zero.
        static func scale(
            fitting data: ClosedRange<Double>,
            spacedFor reference: ClosedRange<Double>,
            decimals: Int,
            intervals: Double = 5,
            maxIntervals: Int = 8
        ) -> Scale {
            let covered = withMargins(data)
            let suited = withMargins(reference)
            let rough = (suited.upperBound - suited.lowerBound) / intervals

            let steps = Self.steps(decimals: decimals)
            var index = steps.firstIndex { Double(truncating: $0 as NSNumber) >= rough } ?? steps.count - 1
            var scale = Scale(covering: covered, step: steps[index])
            while scale.values.count - 1 > maxIntervals, index < steps.count - 1 {
                index += 1
                scale = Scale(covering: covered, step: steps[index])
            }
            return scale
        }

        /// `range` with a tenth of its span spare at each end, or a tenth of its value for a single value, above zero.
        private static func withMargins(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
            let span = range.upperBound - range.lowerBound
            let margin = (span > 0 ? span : max(abs(range.upperBound), 1)) / 10
            return max(0, range.lowerBound - margin) ... range.upperBound + margin
        }

        /// Steps of 1, 2, 2.5 and 5 times a power of ten, smallest first, written in no more than `decimals` places.
        private static func steps(decimals: Int) -> [Decimal] {
            (-decimals ... 6).flatMap { exponent in
                [10, 20, 25, 50]
                    // 2.5 needs a place more than the others
                    .filter { $0 != 25 || exponent > -decimals }
                    .map { Decimal(sign: .plus, exponent: exponent - 1, significand: Decimal($0)) }
            }
        }

        /// Glucose and ISF share a unit conversion, unrounded here so the curve stays smooth in mmol/L.
        static func plotted(_ value: Decimal, units: GlucoseUnits) -> Double {
            Double(truncating: (units == .mgdL ? value : value * GlucoseUnits.exchangeRate) as NSNumber)
        }

        /// The mg/dL glucose at a position on the chart's glucose axis.
        static func glucose(fromPlotted value: Double, units: GlucoseUnits) -> Decimal {
            units == .mgdL ? Decimal(value) : value.asMgdL
        }

        /// The curve's point nearest a position on the chart's glucose axis, such as where it's scrubbed to.
        static func point(atPlotted value: Double, in curve: Curve, units: GlucoseUnits) -> Curve.Point? {
            curve.point(nearest: glucose(fromPlotted: value, units: units))
        }
    }
}
