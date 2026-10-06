import Foundation

enum AppInfo {
  /// 版本号统一从包内 Info.plist 读取；测试进程无 bundle 时回落。
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
  }
}

struct AppError: LocalizedError {
  var message: String
  /// 是否为 SQLite 忙碌类错误（用于有限重试，在回滚清除错误码前捕获）。
  var busy = false
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
enum Cycle: String, Codable, CaseIterable, Identifiable {
  case weekly, monthly, quarterly, yearly, days
  var id: String { rawValue }
  func title(_ en: Bool) -> String {
    let a =
      en
      ? ["Weekly", "Monthly", "Quarterly", "Yearly", "Custom days"]
      : ["每周", "每月", "每季", "每年", "自定义天数"]
    return a[Self.allCases.firstIndex(of: self)!]
  }
}
enum Benefit: String, Codable, CaseIterable {
  case none, daily, weekly
  func title(_ en: Bool) -> String {
    en
      ? ["none": "None", "daily": "Daily", "weekly": "Weekly"][rawValue]!
      : ["none": "无权益打卡", "daily": "每日权益", "weekly": "每周权益"][rawValue]!
  }
}
/// 独立权益（V0.5）：与订阅平级的打卡对象，可关联订阅也可独立存在（如游戏每日登录奖励）。
/// 迁移时复用所属订阅的 UUID，使历史打卡键 "id|kind|period" 与奖励键保持兼容。
struct BenefitItem: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var kind: Benefit = .daily
  var subscriptionID: UUID?
  var createdAt = Date()
  var archived = false
  var note = ""
}
struct Plan: Codable, Identifiable, Equatable {
  var id = UUID()
  var start = Date()
  var end: Date?
  var billingStop: Date?
  var anchor = Date()
  var price: Decimal = 30
  var currency = "CNY"
  var cycle: Cycle = .monthly
  var interval = 30
  var monthEnd = false
  var benefit: Benefit = .none
}
struct Subscription: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var category = "影音"
  var symbol = "play.rectangle"
  var color = "blue"
  var createdAt = Date()
  var updatedAt = Date()
  var plans: [Plan] = [Plan()]
  var autoRenew = true
  var cancelIntent = false
  var cancelledAt: Date?
  var serviceEnd: Date?
  var archived = false
  var trialEnd: Date?
  var trialResolved = false
  var cancelDeadline: Date?
  var reminderDays: Int?
  var link = ""
  var note = ""
  /// 月卡模式（V0.6）：剩余天数叠加。可选字段保证旧存档解码兼容；nil 视为关闭。
  var stacking: Bool?
  var isStacking: Bool { stacking == true }
  var current: Plan { plans.last! }
  var renewing: Bool { cancelledAt == nil }
}
struct Bill: Identifiable {
  var id: String
  var subscriptionID: UUID
  var planID: UUID
  var date: Date
  var price: Decimal
  var currency: String
  var sequence: Int
}
struct Payment: Codable, Identifiable {
  var id: String
  var subscriptionID: UUID
  var due: Date
  var paidAt: Date
  var recordedAt = Date()
  var amount: Decimal
  var currency: String
  var skipped = false
  var note = ""
  /// 一次支付覆盖的期数（V0.6 月卡模式提前续费）。可选字段保证旧存档解码兼容；nil 视为 1。
  var periods: Int?
  var coveredPeriods: Int { periods ?? 1 }
}
struct Claim: Codable, Identifiable {
  var id: String
  var subscriptionID: UUID
  var date: Date
  var recordedAt = Date()
  var backfill = false
}
struct Review: Codable, Identifiable {
  var id: String
  var subscriptionID: UUID
  var month: String
  var rating: Int
}
struct Reward: Codable, Identifiable {
  var id: String
  var date: Date
  var kind: String
  var amount: Int
  var subscriptionID: UUID?
}
struct Event: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var deadline = Date()
  var note = ""
  var subscriptionID: UUID?
  var createdAt = Date()
  var doneAt: Date?
}
enum PetFacility: String, CaseIterable, Identifiable {
  case pantry, playroom, greenhouse, observatory
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .pantry: "fork.knife"
    case .playroom: "gamecontroller.fill"
    case .greenhouse: "leaf.fill"
    case .observatory: "binoculars.fill"
    }
  }
  var unlockLevel: Int {
    switch self {
    case .pantry: 1
    case .playroom: 2
    case .greenhouse: 3
    case .observatory: 4
    }
  }
  func title(_ en: Bool) -> String {
    switch self {
    case .pantry: en ? "Pantry" : "小饭堂"
    case .playroom: en ? "Playroom" : "玩耍角"
    case .greenhouse: en ? "Greenhouse" : "暖房"
    case .observatory: en ? "Observatory" : "观察台"
    }
  }
  func cost(to level: Int) -> Int {
    let base: Int
    switch self {
    case .pantry: base = 35
    case .playroom: base = 45
    case .greenhouse: base = 55
    case .observatory: base = 65
    }
    return base * level
  }
  static func starsNeeded(to level: Int) -> Int { [0, 0, 1, 3, 6][min(4, max(0, level))] }
}
enum MonthlyQuest: String, CaseIterable, Identifiable {
  case claims, payment, review, care
  var id: String { rawValue }
  var target: Int { switch self { case .claims: 3; case .payment: 1; case .review: 1; case .care: 5 } }
  var symbol: String { switch self { case .claims: "gift.fill"; case .payment: "checkmark.shield.fill"; case .review: "chart.bar.fill"; case .care: "pawprint.fill" } }
  func title(_ en: Bool) -> String {
    switch self {
    case .claims: en ? "Use your benefits" : "领好已有权益"
    case .payment: en ? "Check a payment" : "核对真实扣款"
    case .review: en ? "Review value" : "回顾订阅价值"
    case .care: en ? "Care for your cat" : "陪猫吃五顿饭"
    }
  }
  func detail(_ en: Bool) -> String {
    switch self {
    case .claims: en ? "Record 3 benefit claims this month" : "本月记录 3 次权益领取"
    case .payment: en ? "Confirm 1 actual payment this month" : "本月核实 1 笔实际扣款"
    case .review: en ? "Write 1 subscription review this month" : "本月给 1 项订阅做价值回顾"
    case .care: en ? "Use free feeding on 5 different days" : "在 5 个不同的日子免费喂猫"
    }
  }
}
struct PetPoint: Codable, Equatable {
  var x: Double
  var z: Double
}
struct Pet: Codable {
  var name = "贝塔"
  var coat = 0
  var fish = 50
  var growth = 50
  var hunger: Double = 80
  var settledAt = Date()
  var items: [Int] = []
  var furniture: [Int] = []
  var displayed: Set<Int> = []
  var parcels: [String] = []
  var titles: Set<String> = []
  var facilityLevels: [String: Int] = [:]
  var placements: [String: PetPoint] = [:]
  var seasonStars = 0
  private static let milestones = [0, 100, 300, 700, 1500, 2500, 3800, 5400, 7300, 9500]
  var level: Int { Self.milestones.filter { growth >= $0 }.count + max(0, (growth - 9500) / 2500) }
  var nextGrowth: Int { level < Self.milestones.count ? Self.milestones[level] : 9500 + (level - 9) * 2500 }
  var stage: Int { growth >= 3800 ? 3 : growth >= 1500 ? 2 : growth >= 500 ? 1 : 0 }
  func facilityLevel(_ facility: PetFacility) -> Int { facilityLevels[facility.rawValue] ?? 0 }
  init() {}
  private enum CodingKeys: String, CodingKey {
    case name, coat, fish, growth, hunger, settledAt, items, furniture, displayed, parcels, titles, facilityLevels, placements, seasonStars
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    coat = try c.decode(Int.self, forKey: .coat)
    fish = try c.decode(Int.self, forKey: .fish)
    growth = try c.decode(Int.self, forKey: .growth)
    hunger = try c.decode(Double.self, forKey: .hunger)
    settledAt = try c.decode(Date.self, forKey: .settledAt)
    items = try c.decode([Int].self, forKey: .items)
    furniture = try c.decode([Int].self, forKey: .furniture)
    displayed = try c.decode(Set<Int>.self, forKey: .displayed)
    parcels = try c.decode([String].self, forKey: .parcels)
    titles = try c.decode(Set<String>.self, forKey: .titles)
    facilityLevels = try c.decodeIfPresent([String:Int].self, forKey: .facilityLevels) ?? [:]
    placements = try c.decodeIfPresent([String:PetPoint].self, forKey: .placements) ?? [:]
    seasonStars = try c.decodeIfPresent(Int.self, forKey: .seasonStars) ?? 0
  }
}
struct Preferences: Codable {
  var timezone = TimeZone.current.identifier
  var language = "zh"
  var appearance = "system"
  var backgroundHex = ""
  var game = true
  var notifications = false
  var reminderDays = 3
  var reminderHour = 9
  var privacy = false
  var onboarded = false
}
struct State: Codable {
  var schemaVersion = 1
  var rulesVersion = 1
  var updatedAt = Date()
  var subscriptions: [Subscription] = []
  var payments: [Payment] = []
  var claims: [Claim] = []
  var reviews: [Review] = []
  var rewards: [Reward] = []
  var events: [Event] = []
  var benefits: [BenefitItem] = []
  var tombstones: Set<String> = []
  var pet = Pet()
  var preferences = Preferences()
  init() {}
  init(from decoder: Decoder) throws {
    // events 是 V0.4 新增字段；旧存档没有该键，解码时回落为空数组，保证 V0.1 存档兼容。
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    rulesVersion = try c.decode(Int.self, forKey: .rulesVersion)
    updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    subscriptions = try c.decode([Subscription].self, forKey: .subscriptions)
    payments = try c.decode([Payment].self, forKey: .payments)
    claims = try c.decode([Claim].self, forKey: .claims)
    reviews = try c.decode([Review].self, forKey: .reviews)
    rewards = try c.decode([Reward].self, forKey: .rewards)
    events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
    // benefits 是 V0.5 新增字段；旧存档没有该键，解码时回落为空数组。
    benefits = try c.decodeIfPresent([BenefitItem].self, forKey: .benefits) ?? []
    tombstones = try c.decode(Set<String>.self, forKey: .tombstones)
    pet = try c.decode(Pet.self, forKey: .pet)
    preferences = try c.decode(Preferences.self, forKey: .preferences)
  }
}
struct Rating {
  var label: String
  var score: Int?
  var claimed = 0
  var expected = 0
}
let itemNames = ["毛线球", "逗猫棒", "纸箱", "小床", "饭碗", "玩具鱼", "猫隧道", "软垫", "小铃铛", "猫爬架", "玩具鼠", "猫吊床"]
let itemEnglish = [
  "Yarn ball", "Cat wand", "Cardboard box", "Bed", "Bowl", "Toy fish", "Tunnel", "Cushion", "Bell",
  "Cat tree", "Toy mouse", "Hammock",
]
let itemSymbols = [
  "circle.dotted", "wand.and.stars", "shippingbox", "bed.double", "cup.and.saucer", "fish",
  "circle.hexagongrid", "rectangle.fill", "bell", "tree", "hare", "moon.zzz",
]
let furnitureNames = ["地毯", "窗帘", "抓板", "金鱼池", "挂画", "落地灯"]
let furnitureEnglish = ["Rug", "Curtains", "Scratch board", "Fish pond", "Painting", "Floor lamp"]
let furnitureCosts = [50, 80, 120, 160, 220, 300]
private let moneyLock = NSLock()
private var moneyFormatters: [String: NumberFormatter] = [:]
func money(_ amount: Decimal, _ currency: String) -> String {
  moneyLock.lock()
  defer { moneyLock.unlock() }
  let f: NumberFormatter
  if let cached = moneyFormatters[currency] {
    f = cached
  } else {
    let created = NumberFormatter()
    created.numberStyle = .currency
    created.currencyCode = currency
    created.locale = Locale(identifier: "zh_CN")
    moneyFormatters[currency] = created
    f = created
  }
  return f.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
}
