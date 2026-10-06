import AppKit
import SwiftUI

enum Theme {
  static let blue = Color(red: 0.20, green: 0.45, blue: 0.82),
    teal = Color(red: 0.16, green: 0.63, blue: 0.53),
    orange = Color(red: 0.92, green: 0.53, blue: 0.20),
    purple = Color(red: 0.48, green: 0.36, blue: 0.78)
  static func color(_ name: String) -> Color {
    switch name {
    case "teal": teal
    case "orange": orange
    case "purple": purple
    case "green": .green
    default: blue
    }
  }
  static func background(_ dark: Bool, _ hex: String) -> Color {
    let base =
      dark
      ? NSColor(srgbRed: 0.075, green: 0.082, blue: 0.095, alpha: 1)
      : NSColor(srgbRed: 0.975, green: 0.98, blue: 0.985, alpha: 1)
    guard let v = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16), hex.count == 7
    else { return Color(nsColor: base) }
    return Color(
      nsColor: base.blended(
        withFraction: 0.2,
        of: NSColor(
          srgbRed: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255,
          blue: Double(v & 255) / 255, alpha: 1)) ?? base)
  }
}
extension View {
  func card(_ padding: CGFloat = 20) -> some View {
    self.padding(padding).frame(maxWidth: .infinity, alignment: .leading).background(
      Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)
    ).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
  }
}
struct Heading: View {
  var title: String
  var subtitle: String
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 25, weight: .semibold))
      Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
  }
}
struct Tile: View {
  var symbol: String
  var color: Color = Theme.teal
  var body: some View {
    Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
      .frame(width: 42, height: 42).background(
        color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
  }
}
/// 账单相对时间标签：今天/明天/×天后/逾期×天。逾期返回时 overdue 为 true。
func relativeDay(_ date: Date, _ state: State, _ en: Bool) -> (text: String, overdue: Bool) {
  let c = Engine.calendar(state)
  let days =
    c.dateComponents([.day], from: c.startOfDay(for: Date()), to: c.startOfDay(for: date)).day ?? 0
  switch days {
  case 0: return (en ? "today" : "今天", false)
  case 1: return (en ? "tomorrow" : "明天", false)
  case ...(-1): return (en ? "\(-days)d overdue" : "逾期 \(-days) 天", true)
  default: return (en ? "in \(days)d" : "\(days) 天后", false)
  }
}
struct EmptyState: View {  var symbol: String
  var title: String
  var subtitle: String
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Theme.teal)
      Text(title).font(.headline)
      Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity, minHeight: 170).padding(24)
  }
}
struct Metric: View {
  var label: String
  var value: String
  var footnote: String
  var symbol: String
  var color: Color = Theme.teal
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(label).font(.callout).foregroundStyle(.secondary)
        Spacer()
        Image(systemName: symbol).foregroundStyle(color)
      }
      Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(2)
        .minimumScaleFactor(0.7)
      Text(footnote).font(.caption).foregroundStyle(.secondary)
    }.card()
  }
}
