import Charts
import SwiftUI

struct DynamicISFExplorerChart: View {
    let curve: DynamicISFExplorer.Curve
    let savedCurve: DynamicISFExplorer.Curve?
    let units: GlucoseUnits

    @State private var selection: Double?

    // shared by the marks and their legend keys
    private static let curveColor = Color.cyan
    private static let curveStroke = StrokeStyle(lineWidth: 2)
    private static let savedColor = curveColor.opacity(0.6)
    // the phase centres the dashes in the legend key
    private static let savedStroke = StrokeStyle(lineWidth: 2, dash: [5, 4], dashPhase: 2.5)
    private static let limitsColor = curveColor.opacity(0.15)
    private static let profileColor = Color.primary
    private static let profileStroke = StrokeStyle(lineWidth: 1.5, dash: [7, 4])
    private static let keySize = CGSize(width: 18, height: 10)

    private var selectedPoint: DynamicISFExplorer.Curve.Point? {
        guard let selection else { return nil }
        let glucose = Decimal(selection)
        return curve.point(nearest: units == .mgdL ? glucose : glucose / GlucoseUnits.exchangeRate)
    }

    private var sensitivityUnit: TherapySettingUnit {
        units == .mgdL ? .mgdLPerUnit : .mmolLPerUnit
    }

    private var maxSensitivity: Decimal {
        max(curve.sensitivityLimits.upperBound, savedCurve?.sensitivityLimits.upperBound ?? 0)
    }

    private var sensitivityAxisTop: Double {
        Self.sensitivityAxisTop(fitting: plotted(maxSensitivity), units: units)
    }

    var body: some View {
        VStack(alignment: .leading) {
            chart.frame(height: 240)
            legend
        }
    }

    private var chart: some View {
        Chart {
            RectangleMark(
                xStart: .value("Glucose", plotted(DynamicISFExplorer.Curve.glucoseRange.lowerBound)),
                xEnd: .value("Glucose", plotted(DynamicISFExplorer.Curve.glucoseRange.upperBound)),
                yStart: .value("ISF", plotted(curve.sensitivityLimits.lowerBound)),
                yEnd: .value("ISF", plotted(curve.sensitivityLimits.upperBound))
            )
            .foregroundStyle(Self.limitsColor)

            RuleMark(y: .value("Profile ISF", plotted(curve.profileSensitivity)))
                .foregroundStyle(Self.profileColor)
                .lineStyle(Self.profileStroke)

            if let savedCurve {
                line(for: savedCurve, series: "saved")
                    .foregroundStyle(Self.savedColor)
                    .lineStyle(Self.savedStroke)
            }

            line(for: curve, series: "explored")
                .foregroundStyle(Self.curveColor)
                .lineStyle(Self.curveStroke)

            if let selectedPoint {
                RuleMark(x: .value("Glucose", plotted(selectedPoint.glucose)))
                    .foregroundStyle(Color.tabBar)
                    .lineStyle(.init(lineWidth: 2))
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        selectionPopover(for: selectedPoint)
                    }

                PointMark(
                    x: .value("Glucose", plotted(selectedPoint.glucose)),
                    y: .value("ISF", plotted(selectedPoint.sensitivity))
                )
                .symbolSize(CGSize(width: 15, height: 15))
                .foregroundStyle(Self.curveColor)

                PointMark(
                    x: .value("Glucose", plotted(selectedPoint.glucose)),
                    y: .value("ISF", plotted(selectedPoint.sensitivity))
                )
                .symbolSize(CGSize(width: 6, height: 6))
                .foregroundStyle(Color.primary)
            }
        }
        .chartXSelection(value: $selection)
        .chartXScale(
            domain: plotted(DynamicISFExplorer.Curve.glucoseRange.lowerBound) ...
                plotted(DynamicISFExplorer.Curve.glucoseRange.upperBound)
        )
        .chartYScale(domain: 0 ... sensitivityAxisTop)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(anchor: .top)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel()
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        .chartXAxisLabel(units.rawValue, alignment: .trailing)
        .chartYAxisLabel(sensitivityUnit.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dynamic ISF chart"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private func line(for curve: DynamicISFExplorer.Curve, series: String) -> some ChartContent {
        ForEach(curve.points) { point in
            LineMark(
                x: .value("Glucose", plotted(point.glucose)),
                y: .value("ISF", plotted(point.sensitivity)),
                series: .value("Series", series)
            )
        }
    }

    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                legendItem(String(localized: "Dynamic ISF")) { lineKey(Self.curveColor, Self.curveStroke) }
                if savedCurve != nil {
                    legendItem(String(localized: "Your Settings")) { lineKey(Self.savedColor, Self.savedStroke) }
                }
            }
            GridRow {
                legendItem(String(localized: "Profile ISF")) { lineKey(Self.profileColor, Self.profileStroke) }
                legendItem(String(localized: "Sensitivity Limits")) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.limitsColor)
                        .frame(width: Self.keySize.width, height: Self.keySize.height)
                }
            }
        }
        // legend keys mean nothing to VoiceOver; the chart's accessibility value describes the curve
        .accessibilityHidden(true)
    }

    private func legendItem(_ label: String, @ViewBuilder key: () -> some View) -> some View {
        HStack(spacing: 4) {
            key()
            Text(label).foregroundStyle(Color.secondary)
        }.font(.caption)
    }

    /// A short stretch of a line, drawn the way the chart draws it.
    private func lineKey(_ color: Color, _ stroke: StrokeStyle) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: Self.keySize.height / 2))
            path.addLine(to: CGPoint(x: Self.keySize.width, y: Self.keySize.height / 2))
        }
        .stroke(color, style: stroke)
        .frame(width: Self.keySize.width, height: Self.keySize.height)
    }

    private func selectionPopover(for point: DynamicISFExplorer.Curve.Point) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(formatted(point.glucose)) \(units.rawValue)").bold()
            Text(verbatim: "\(String(localized: "ISF")) \(formatted(point.sensitivity)) \(sensitivityUnit.displayName)")
            Text("Sensitivity Ratio") + Text(verbatim: " \(point.ratio.formatted(.percent.precision(.fractionLength(0))))")
        }
        .font(.footnote)
        .padding(7)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.chart.opacity(0.85))
                .shadow(color: Color.secondary, radius: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary, lineWidth: 2)
                )
        }
    }

    private var accessibilitySummary: String {
        guard let first = curve.points.first, let last = curve.points.last else { return "" }
        let low = formatted(first.sensitivity)
        let high = formatted(last.sensitivity)
        return String(
            localized: "ISF from \(low) at low glucose to \(high) at high glucose, in \(sensitivityUnit.spokenName)",
            comment: "Accessibility: chart summary"
        )
    }

    private func formatted(_ value: Decimal) -> String {
        NumberFormatter.glucoseFormatter(for: units).string(from: value.asUnit(units) as NSNumber) ?? "\(value)"
    }

    /// 15% above the weakest ISF, rounded up in the user's units to a step that grows with it, so stepping a value
    /// only rescales the axis once the curves outgrow it, and stepping back restores it.
    static func sensitivityAxisTop(fitting weakest: Double, units: GlucoseUnits) -> Double {
        let value = weakest * 1.15
        // the mmol/L steps are about 9, 18, 36 and 90 mg/dL, so both units rescale alike
        let steps: [(upTo: Double, step: Double)] = units == .mgdL ?
            [(100, 10), (200, 25), (400, 50)] :
            [(5, 0.5), (10, 1), (20, 2)]
        let step = steps.first { value <= $0.upTo }?.step ?? (units == .mgdL ? 100 : 5)
        // the epsilon keeps Decimal-to-Double noise from adding a whole step
        return ((value / step) - 1E-9).rounded(.up) * step
    }

    /// Glucose and ISF share a unit conversion, unrounded here so the curve stays smooth in mmol/L.
    private func plotted(_ value: Decimal) -> Double {
        Double(truncating: (units == .mgdL ? value : value * GlucoseUnits.exchangeRate) as NSNumber)
    }
}
