import Charts
import SwiftUI

struct DynamicISFExplorerChart: View {
    let curve: DynamicISFExplorer.Curve
    let savedCurve: DynamicISFExplorer.Curve?
    let units: GlucoseUnits
    /// The plot's height with its axes, below the legend.
    var plotHeight: CGFloat = 240

    @State private var selection: Double?
    /// The last glucose scrubbed to, kept once the finger lifts so the readout has values to fade out with.
    @State private var readoutSelection: Double?

    // Shared by the marks and their legend keys
    private static let curveColor = Color.cyan
    private static let curveStroke = StrokeStyle(lineWidth: 2)
    private static let savedColor = curveColor.opacity(0.6)
    // The phase centres the dashes in the legend key
    private static let savedStroke = StrokeStyle(lineWidth: 2, dash: [5, 4], dashPhase: 2.5)
    private static let limitsColor = curveColor.opacity(0.15)
    private static let profileColor = Color.primary
    private static let profileStroke = StrokeStyle(lineWidth: 1.5, dash: [7, 4])
    private static let keySize = CGSize(width: 18, height: 10)

    private var selectedPoint: DynamicISFExplorer.Curve.Point? {
        selection.flatMap { DynamicISFExplorer.ChartAxes.point(atPlotted: $0, in: curve, units: units) }
    }

    private var sensitivityScale: DynamicISFExplorer.ChartAxes.Scale {
        DynamicISFExplorer.ChartAxes.sensitivityScale(for: curve, saved: savedCurve, units: units)
    }

    /// Room at either end of the glucose axis, so the curves don't run into the chart's edges.
    private static let glucoseAxisPadding: CGFloat = 8

    private var isReadoutVisible: Bool {
        selection != nil
    }

    var body: some View {
        VStack(alignment: .leading) {
            // The legend's slot, which the readout takes over while the chart is scrubbed, as Home's meal slot does.
            // The readout is an overlay, so it never resizes the slot or moves the chart, and it covers none of the curve
            legend
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isReadoutVisible ? 0 : 1)
                .overlay {
                    readout
                        .opacity(isReadoutVisible ? 1 : 0)
                }
                .animation(ChartSelectionLookup.readoutFade, value: isReadoutVisible)

            chart.frame(height: plotHeight)
        }
        .onChange(of: selection) { _, newValue in
            if let newValue { readoutSelection = newValue }
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
                plotted(DynamicISFExplorer.Curve.glucoseRange.upperBound),
            range: .plotDimension(padding: Self.glucoseAxisPadding)
        )
        .chartYScale(domain: sensitivityScale.domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(anchor: .top)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        .chartYAxis {
            AxisMarks(values: sensitivityScale.values) { value in
                // Written as the explorer writes ISF, so a gridline at 7.5 doesn't read as 8
                AxisValueLabel {
                    if let value = value.as(Double.self) {
                        Text(verbatim: DynamicISFExplorer.Format.glucose(inUnits: Decimal(value), units: units))
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        // Named and unit-labelled like the ISF axis, from the already translated "Glucose"
        .chartXAxisLabel("\(String(localized: "Glucose")) (\(units.rawValue))" as String, alignment: .trailing)
        // Beside the axis values, which Charts turns to run along the axis
        .chartYAxisLabel(String(localized: "ISF (\(units.sensitivityUnit.displayName))"), position: .trailing, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dynamic ISF chart", comment: "Accessibility: name of the Dynamic ISF Explorer's chart"))
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
                    legendItem(String(localized: "Your Settings", comment: "Legend for the curve of the user's settings")) {
                        lineKey(Self.savedColor, Self.savedStroke)
                    }
                }
            }
            GridRow {
                legendItem(String(localized: "Profile ISF", comment: "Legend for the line at the scheduled ISF")) {
                    lineKey(Self.profileColor, Self.profileStroke)
                }
                legendItem(String(localized: "Sensitivity Limits")) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.limitsColor)
                        .frame(width: Self.keySize.width, height: Self.keySize.height)
                }
            }
        }
        // Legend keys mean nothing to VoiceOver; the chart's accessibility value describes the curve
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

    /// The point being scrubbed, in one line styled like Home's chart readout (`ChartSelectionRow`). Its units are on
    /// the axes, as Home leaves the glucose unit to its axis.
    @ViewBuilder private var readout: some View {
        if let shown = selection ?? readoutSelection,
           let point = DynamicISFExplorer.ChartAxes.point(atPlotted: shown, in: curve, units: units)
        {
            // The row steps down a type size until it fits. Long translations of the labels and large text sizes can
            // outgrow even the smallest, so the ratio's name goes last, and what's left shrinks rather than spill out
            ViewThatFits(in: .horizontal) {
                readoutRow(for: point, font: .callout)
                readoutRow(for: point, font: .subheadline)
                readoutRow(for: point, font: .footnote)
                readoutRow(for: point, font: .footnote, namesRatio: false)
                    .minimumScaleFactor(0.5)
            }
            // Scrubbing changes the values several times a second; animating them smears the digits
            .animation(nil, value: point.glucose)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassPanel(tint: Self.curveColor, tintOpacity: 0.10, strokeOpacity: 0.25)
            // It only follows a finger on the chart; VoiceOver reads the chart's summary instead
            .accessibilityHidden(true)
        }
    }

    private func readoutRow(for point: DynamicISFExplorer.Curve.Point, font: Font, namesRatio: Bool = true) -> some View {
        HStack(spacing: 12) {
            readoutItem(icon: "drop.fill", value: formatted(point.glucose))
            readoutItem(label: Text("ISF"), value: formatted(point.sensitivity))
            readoutItem(
                label: namesRatio ? Text("Sensitivity Ratio") : nil,
                value: "\(DynamicISFExplorer.Format.percent(point.ratio, decimals: 0)) \(percentSign)"
            )
        }
        .font(font).fontWeight(.bold).fontDesign(.rounded)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// One value plus its glyph or name.
    private func readoutItem(icon: String? = nil, label: Text? = nil, value: String) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(Color.secondary)
            }
            if let label {
                label.fontWeight(.regular).foregroundStyle(Color.secondary)
            }
            Text(verbatim: value)
        }
    }

    /// Where Dynamic ISF changes the ISF, and from what to what. The ISF at the curve's ends alone would barely move
    /// with the settings, as they usually sit on the Sensitivity Limits.
    private var accessibilitySummary: String {
        guard let first = curve.points.first, let last = curve.points.last else { return "" }
        let low = formatted(first.sensitivity)
        let high = formatted(last.sensitivity)
        let isfUnit = units.sensitivityUnit.spokenName
        let glucoseUnit = units.spokenValue
        guard let adjusting = curve.adjustingRange(units: units) else {
            return String(
                localized: "ISF is \(low) \(isfUnit) at all glucose levels",
                comment: "Accessibility: Dynamic ISF Explorer chart summary for a flat curve: an ISF and its unit"
            )
        }
        let start = formatted(adjusting.lowerBound)
        let end = formatted(adjusting.upperBound)
        return String(
            localized: "Adjusts ISF from \(low) to \(high) \(isfUnit) as glucose rises from \(start) to \(end) \(glucoseUnit)",
            comment: "Accessibility: Dynamic ISF Explorer chart summary: ISFs and their unit, then glucose values and their unit"
        )
    }

    private func formatted(_ value: Decimal) -> String {
        DynamicISFExplorer.Format.glucose(value, units: units)
    }

    /// As the explorer's rows write it.
    private var percentSign: String {
        String(localized: "%", comment: "Percentage symbol")
    }

    private func plotted(_ value: Decimal) -> Double {
        DynamicISFExplorer.ChartAxes.plotted(value, units: units)
    }
}
