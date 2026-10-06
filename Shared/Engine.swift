import Foundation

enum Engine {
  static func migrateBeta(_ s: inout State) {
    guard s.tombstones.insert("migration|beta-v359").inserted else { return }
    s.pet.name = "贝塔"
  }
  static let homeSites: [String:PetPoint] = [
    "pantry":PetPoint(x:-4.2,z:-1.8), "playroom":PetPoint(x:3.5,z:1.6),
    "greenhouse":PetPoint(x:-3.5,z:2.1), "observatory":PetPoint(x:3.6,z:-2.0),
    "furniture0":PetPoint(x:-1.4,z:2.3), "furniture1":PetPoint(x:0.2,z:-2.1),
    "furniture2":PetPoint(x:-1.7,z:-1.5), "furniture3":PetPoint(x:1.6,z:1.7),
    "furniture4":PetPoint(x:0.9,z:2.6), "furniture5":PetPoint(x:-3.2,z:0.3)
  ]
  static func homeLayout(_ pet:Pet) -> [String:PetPoint] {
    let ids = PetFacility.allCases.filter { pet.facilityLevel($0)>0 }.map(\.rawValue) + pet.displayed.sorted().map { "furniture\($0)" }
    return Dictionary(uniqueKeysWithValues:ids.map { ($0,pet.placements[$0] ?? homeSites[$0] ?? PetPoint(x:0,z:0)) })
  }
  static func applyHomeLayout(_ s:inout State, placements:[String:PetPoint]) throws {
    let original=homeLayout(s.pet)
    guard Set(placements.keys)==Set(original.keys), placements.values.allSatisfy({ placementAllowed(x:$0.x,z:$0.z,level:s.pet.level) }) else { throw AppError("请将家具放在房间内 / Keep furniture inside the room") }
    // Legacy overlapping furniture may stay untouched; newly moved items cannot overlap.
    for (id,p) in placements where p != original[id] {
      guard placements.allSatisfy({ $0.key==id || hypot($0.value.x-p.x,$0.value.z-p.z)>1.4 }) else { throw AppError("家具之间需要留出空间 / Leave space between furniture") }
    }
    s.pet.placements.merge(placements) { _,new in new }
  }

  static func placementAllowed(x:Double,z:Double,level:Int) -> Bool {
    guard x.isFinite,z.isFinite else { return false }
    return (abs(x)<5.5 && abs(z)<3.8) ||
      (level>=3 && x>7.6 && x<9.35 && z>(-0.05) && z<3.2) ||
      (level>=5 && x>(-5.8) && x<(-4.0) && z>5.4 && z<6.6)
  }
  static func calendar(_ s: State) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: s.preferences.timezone) ?? .current
    c.firstWeekday = 2
    c.minimumDaysInFirstWeek = 4
    return c
  }
  static func day(_ date: Date, _ s: State) -> String {
    let c = calendar(s)
    let v = c.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", v.year!, v.month!, v.day!)
  }
  static func month(_ date: Date, _ s: State) -> String { String(day(date, s).prefix(7)) }
  static func date(_ text: String, _ s: State) -> Date {
    let f = DateFormatter()
    f.calendar = calendar(s)
    f.timeZone = calendar(s).timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: text)!
  }
  static func dateFor(_ p: Plan, index: Int, state s: State) -> Date {
    let c = calendar(s)
    let anchor = c.startOfDay(for: p.anchor)
    switch p.cycle {
    case .weekly, .days:
      return c.date(
        byAdding: .day, value: index * (p.cycle == .weekly ? 7 : p.interval), to: anchor)!
    default:
      let months = index * (p.cycle == .yearly ? 12 : p.cycle == .quarterly ? 3 : 1)
      let first = c.date(from: c.dateComponents([.year, .month], from: anchor))!
      let target = c.date(byAdding: .month, value: months, to: first)!
      let count = c.range(of: .day, in: .month, for: target)!.count
      let d = p.monthEnd ? count : min(c.component(.day, from: anchor), count)
      return c.date(byAdding: .day, value: d - 1, to: target)!
    }
  }
  static func monthly(_ p: Plan) -> Decimal {
    switch p.cycle {
    case .weekly: return p.price * 52 / 12
    case .monthly: return p.price
    case .quarterly: return p.price / 3
    case .yearly: return p.price / 12
    case .days: return p.price * 365 / Decimal(p.interval) / 12
    }
  }
  /// 月卡模式每期天数：月=30、周=7、季=90、年=365，自定义天数按间隔。
  static func cycleDays(_ p: Plan) -> Int {
    switch p.cycle {
    case .weekly: return 7
    case .monthly: return 30
    case .quarterly: return 90
    case .yearly: return 365
    case .days: return p.interval
    }
  }
  static func bills(_ sub: Subscription, state s: State, from: Date, through: Date) -> [Bill] {
    let c = calendar(s)
    var result: [Bill] = []
    // 月卡模式：账期序列跨计划连续编号（sequence 全局递增），覆盖判定依赖该序号。
    var seq = 0
    for p in sub.plans {
      let lower = max(c.startOfDay(for: from), c.startOfDay(for: p.start))
      let upper = c.startOfDay(for: through)
      guard lower <= upper else { continue }
      let days = max(
        0, c.dateComponents([.day], from: c.startOfDay(for: p.anchor), to: lower).day ?? 0)
      let months = max(0, c.dateComponents([.month], from: p.anchor, to: lower).month ?? 0)
      var i = max(
        0,
        p.cycle == .days
          ? days / p.interval - 1
          : p.cycle == .weekly
            ? days / 7 - 1 : months / (p.cycle == .yearly ? 12 : p.cycle == .quarterly ? 3 : 1) - 2)
      // 月卡模式从头逐期生成（跨计划 sequence 连续，性能由 10000 上限兜底）。
      if sub.isStacking { i = 0 }
      for _ in 0..<10000 {
        let d =
          sub.isStacking
          ? c.date(
            byAdding: .day, value: i * cycleDays(p), to: c.startOfDay(for: p.anchor))!
          : dateFor(p, index: i, state: s)
        if d > upper { break }
        if let end = p.end, d >= c.startOfDay(for: end) { break }
        if let stop = p.billingStop, d >= c.startOfDay(for: stop) { break }
        if let cancelled = sub.cancelledAt, d >= c.startOfDay(for: cancelled) { break }
        if d >= lower {
          result.append(
            Bill(
              id: "\(sub.id)|\(day(d,s))", subscriptionID: sub.id, planID: p.id, date: d,
              price: p.price, currency: p.currency, sequence: sub.isStacking ? seq : i))
        }
        i += 1
        if sub.isStacking { seq += 1 }
      }
    }
    return result.sorted { $0.date < $1.date }
  }
  /// 月卡模式已覆盖期数：所有非"本期未扣"支付按期数累加。
  static func coveredPeriods(_ sub: Subscription, _ s: State) -> Int {
    s.payments.filter { $0.subscriptionID == sub.id && !$0.skipped }.reduce(0) {
      $0 + $1.coveredPeriods
    }
  }
  /// 账期是否已结清：月卡模式按覆盖期数判定（提前续费会覆盖未来账期），其余按支付记录匹配。
  static func covered(_ bill: Bill, _ s: State) -> Bool {
    if let sub = s.subscriptions.first(where: { $0.id == bill.subscriptionID }), sub.isStacking {
      return bill.sequence < coveredPeriods(sub, s)
    }
    return s.payments.contains { $0.id == bill.id }
  }
  /// 月卡模式剩余天数：服务付费到的日期（下一个未覆盖账期日）距今天的天数；负数表示已到期。
  static func remainingDays(_ sub: Subscription, _ s: State, now: Date = Date()) -> Int? {
    guard sub.isStacking, !sub.plans.isEmpty else { return nil }
    let c = calendar(s)
    let first = sub.plans.map(\.start).min()!
    let far = c.date(byAdding: .year, value: 50, to: now)!
    guard let next = bills(sub, state: s, from: first, through: far).first(where: {
      !covered($0, s)
    })
    else { return nil }
    return c.dateComponents(
      [.day], from: c.startOfDay(for: now), to: c.startOfDay(for: next.date)
    ).day
  }
  /// 月卡模式提前续费：在剩余天数上叠加 N 期，记一笔真实支付（金额 = 单价 × N，可自行修改）。
  static func renew(
    _ s: inout State, subID: UUID, periods: Int, amount: Decimal, paidAt: Date,
    now: Date = Date()
  ) throws {
    guard periods >= 1, periods <= 120, let sub = s.subscriptions.first(where: { $0.id == subID }),
      sub.isStacking
    else { throw AppError("该订阅未开启月卡模式 / Not a stacking subscription") }
    let c = calendar(s)
    let far = c.date(byAdding: .year, value: 50, to: now)!
    let first = sub.plans.map(\.start).min()!
    guard let bill = bills(sub, state: s, from: first, through: far).first(where: {
      !covered($0, s)
    })
    else { throw AppError("没有可续费的账期 / No period to renew") }
    try confirm(&s, bill: bill, amount: amount, paidAt: paidAt, skipped: false, now: now)
    if let i = s.payments.firstIndex(where: { $0.id == bill.id }) {
      s.payments[i].periods = periods
    }
    // 提前续费（账期日还在未来）同样视为当月真实扣款：补发月供包裹与 5 小鱼干（月上限 3 不变）。
    let key = "parcel|\(subID)|\(month(now,s))"
    if !s.tombstones.contains(key),
      s.rewards.filter({ $0.kind == "parcel" && month($0.date, s) == month(now, s) }).count < 3
    {
      grant(&s, key: key, kind: "parcel", amount: 5, sub: subID, now: now)
      if s.preferences.game { s.pet.parcels.append(key) }
    }
  }
  static func upcoming(_ s: State, now: Date = Date(), days: Int = 30) -> [Bill] {
    let c = calendar(s)
    let end = c.date(byAdding: .day, value: days, to: now)!
    return s.subscriptions.filter { !$0.archived }.flatMap {
      bills($0, state: s, from: now, through: end)
    }.filter { !covered($0, s) }.sorted { $0.date < $1.date }
  }
  static func pending(_ s: State, now: Date = Date()) -> [Bill] {
    let c = calendar(s)
    let from = c.date(byAdding: .month, value: -12, to: now)!
    return s.subscriptions.filter { !$0.archived }.flatMap {
      bills($0, state: s, from: from, through: now)
    }.filter { !covered($0, s) }.sorted { $0.date < $1.date }
  }
  static func next(_ sub: Subscription, _ s: State, now: Date = Date()) -> Bill? {
    bills(sub, state: s, from: now, through: calendar(s).date(byAdding: .year, value: 5, to: now)!)
      .first { b in !covered(b, s) }
  }
  static func activePlan(_ sub: Subscription, _ s: State, on date: Date) -> Plan? {
    let c = calendar(s)
    let d = c.startOfDay(for: date)
    if sub.cancelledAt != nil {
      guard let end = sub.serviceEnd, d <= c.startOfDay(for: end) else { return nil }
    }
    return sub.plans.last {
      c.startOfDay(for: $0.start) <= d && ($0.end == nil || d < c.startOfDay(for: $0.end!))
    }
  }
  /// 权益打卡键："<权益ID>|<daily/weekly>|<周期起始日>"。
  /// 关联订阅的权益在订阅归档或服务期结束后不再可打卡（与 V0.4 行为一致）；
  /// 独立权益（无关联订阅）只要未归档就可打卡。
  static func claimKey(_ benefit: BenefitItem, _ s: State, on date: Date) -> String? {
    guard !benefit.archived, benefit.kind != .none else { return nil }
    if let subID = benefit.subscriptionID {
      guard let sub = s.subscriptions.first(where: { $0.id == subID }), !sub.archived,
        activePlan(sub, s, on: date) != nil
      else { return nil }
    }
    let c = calendar(s)
    let start =
      benefit.kind == .weekly
      ? c.dateInterval(of: .weekOfYear, for: date)!.start : c.startOfDay(for: date)
    return "\(benefit.id)|\(benefit.kind.rawValue)|\(day(start,s))"
  }
  static func dueBenefits(_ s: State, now: Date = Date()) -> [BenefitItem] {
    s.benefits.filter { benefit in
      claimKey(benefit, s, on: now).map { key in !s.claims.contains { $0.id == key } } == true
    }
  }
  static func rating(
    _ sub: Subscription, _ s: State, now: Date = Date(), interval: DateInterval? = nil
  ) -> Rating {
    let c = calendar(s)
    let en = s.preferences.language == "en"
    let end = interval?.end ?? c.startOfDay(for: now)
    let start = interval?.start ?? c.date(byAdding: .day, value: -30, to: end)!
    // 订阅的领取率由关联权益的打卡记录计算；没有关联权益则按月度自评。
    let linked = s.benefits.filter { $0.subscriptionID == sub.id && !$0.archived }
    if linked.isEmpty {
      let target = interval.map { month($0.start, s) } ?? month(now, s)
      let v = s.reviews.first { $0.subscriptionID == sub.id && $0.month == target }?.rating
      return Rating(
        label: v.map { (en ? ["Unused", "Sometimes", "Often"] : ["吃灰", "偶尔", "常用"])[$0] }
          ?? (en ? "Not reviewed" : "未评估"), score: v)
    }
    var opportunities = Set<String>()
    var d = start
    var daily = false
    while d < end {
      for benefit in linked {
        if let key = claimKey(benefit, s, on: d) {
          if benefit.kind == .weekly {
            let w = c.dateInterval(of: .weekOfYear, for: d)!
            if w.end <= end && w.end > start { opportunities.insert(key) }
          } else {
            daily = true
            opportunities.insert(key)
          }
        }
      }
      d = c.date(byAdding: .day, value: 1, to: d)!
    }
    let count = opportunities.count
    let done = s.claims.filter { opportunities.contains($0.id) }.count
    guard count >= (daily ? 7 : 4) else {
      return Rating(
        label: en ? "Not enough data" : "数据不足", score: nil, claimed: done, expected: count)
    }
    let r = Double(done) / Double(count)
    let value = r >= 0.7 ? 2 : r >= 0.3 ? 1 : 0
    return Rating(
      label: (en ? ["Unused", "Sometimes", "Often"] : ["吃灰", "偶尔", "常用"])[value], score: value,
      claimed: done, expected: count)
  }
  static func dusty(_ sub: Subscription, _ s: State, now: Date = Date()) -> Bool {
    let c = calendar(s)
    let first = c.dateInterval(of: .month, for: now)!.start
    return (1...2).allSatisfy { i in
      let start = c.date(byAdding: .month, value: -i, to: first)!
      return rating(
        sub, s, now: now,
        interval: DateInterval(start: start, end: c.date(byAdding: .month, value: 1, to: start)!)
      ).score == 0
    }
  }
  static func settle(_ s: inout State, now: Date) {
    guard s.preferences.game, now > s.pet.settledAt else { return }
    let greenhouse = s.pet.facilityLevel(.greenhouse)
    s.pet.hunger = max(
      0, s.pet.hunger - min(86400, now.timeIntervalSince(s.pet.settledAt)) / 86400 * Double(20 - 2 * greenhouse))
    s.pet.settledAt = now
  }
  static func grant(
    _ s: inout State, key: String, kind: String, amount: Int, sub: UUID? = nil, now: Date
  ) {
    guard !s.tombstones.contains(key), !s.rewards.contains(where: { $0.id == key }) else { return }
    s.tombstones.insert(key)
    guard s.preferences.game else { return }
    s.rewards.append(Reward(id: key, date: now, kind: kind, amount: amount, subscriptionID: sub))
    s.pet.fish += amount
    s.pet.growth += amount
    if s.pet.level >= 2 { s.pet.titles.insert("home") }
  }
  static func claim(_ s: inout State, benefitID: UUID, date: Date, now: Date = Date()) throws {
    guard calendar(s).startOfDay(for: date) <= calendar(s).startOfDay(for: now),
      let benefit = s.benefits.first(where: { $0.id == benefitID }),
      let key = claimKey(benefit, s, on: date)
    else { throw AppError("该日期没有可领取权益 / No benefit for this date") }
    guard !s.claims.contains(where: { $0.id == key }) else { return }
    let backfill = day(date, s) != day(now, s)
    // Claim.subscriptionID 记录归属：关联权益记订阅 ID，独立权益记权益自身 ID。
    s.claims.append(
      Claim(
        id: key, subscriptionID: benefit.subscriptionID ?? benefit.id, date: date,
        backfill: backfill))
    let rewardKey = "claim|" + key
    guard !backfill, !s.tombstones.contains(rewardKey) else {
      s.tombstones.insert(rewardKey)
      return
    }
    settle(&s, now: now)
    let count = s.rewards.filter { $0.kind == "claim" && day($0.date, s) == day(now, s) }.count
    if count < 3 {
      // 打卡即喂饭（+15 饱食），同时 +1 小鱼干；喂饱了（100）的一次 +2。
      let amount = (s.pet.hunger >= 100 ? 2 : 1) + s.pet.facilityLevel(.playroom)
      grant(&s, key: rewardKey, kind: "claim", amount: amount, sub: benefit.subscriptionID, now: now)
      if s.preferences.game { s.pet.hunger = min(100, s.pet.hunger + Double(15 + 2 * s.pet.facilityLevel(.pantry))) }
    } else {
      s.tombstones.insert(rewardKey)
    }
    if s.preferences.game && benefit.kind == .daily {
      let consecutive = (0..<30).allSatisfy { offset in
        let d = calendar(s).date(byAdding: .day, value: -offset, to: now)!
        return claimKey(benefit, s, on: d).map { k in s.claims.contains { $0.id == k } } ?? false
      }
      if consecutive { s.pet.titles.insert("thirty") }
    }
    streak(&s, now: now)
  }
  static func streak(_ s: inout State, now: Date) {
    let c = calendar(s)
    var days: [String] = []
    for offset in 0..<7 {
      let d = c.date(byAdding: .day, value: -offset, to: now)!
      let keys = s.benefits.compactMap { claimKey($0, s, on: d) }
      guard !keys.isEmpty,
        keys.allSatisfy({ k in
          s.claims.contains { $0.id == k && day($0.date, s) <= day(d, s) && !$0.backfill }
        })
      else { return }
      days.append(day(d, s))
    }
    guard !s.rewards.contains(where: { $0.kind == "streak" && days.contains(day($0.date, s)) })
    else { return }
    grant(&s, key: "streak|\(day(now,s))", kind: "streak", amount: 20, now: now)
  }
  /// V0.5 迁移：把订阅计划里的内嵌权益（Plan.benefit）升级为独立权益模块的记录。
  /// 迁移后的权益复用订阅 UUID，历史打卡键与奖励键因此保持逐字节兼容。只执行一次。
  static func migrateBenefits(_ s: inout State) {
    let key = "migration|benefits-v1"
    guard !s.tombstones.contains(key) else { return }
    s.tombstones.insert(key)
    for sub in s.subscriptions {
      let kind = sub.current.benefit
      guard kind != .none, !s.benefits.contains(where: { $0.id == sub.id }) else { continue }
      s.benefits.append(
        BenefitItem(
          id: sub.id, name: sub.name, kind: kind, subscriptionID: sub.id,
          createdAt: sub.createdAt, archived: sub.archived))
    }
  }
  @discardableResult static func feed(_ s: inout State, now: Date = Date()) -> Bool {
    let key = "feed|\(day(now,s))"
    guard s.preferences.game, !s.tombstones.contains(key) else { return false }
    settle(&s, now: now)
    s.pet.hunger = min(100, s.pet.hunger + Double(20 + 5 * s.pet.facilityLevel(.pantry)))
    s.tombstones.insert(key)
    return true
  }
  static func questKey(_ quest: MonthlyQuest, _ s: State, now: Date) -> String {
    "monthly-quest|\(month(now,s))|\(quest.rawValue)"
  }
  static func questProgress(_ quest: MonthlyQuest, _ s: State, now: Date = Date()) -> Int {
    let period = month(now, s)
    switch quest {
    case .claims:
      return s.claims.filter { !$0.backfill && month($0.date, s) == period }.count
    case .payment:
      return s.payments.filter { !$0.skipped && month($0.recordedAt, s) == period }.count
    case .review:
      return s.reviews.filter { $0.month == period }.count
    case .care:
      return s.tombstones.filter { $0.hasPrefix("feed|\(period)-") }.count
    }
  }
  static func claimedQuestCount(_ s: State, now: Date = Date()) -> Int {
    MonthlyQuest.allCases.filter { s.tombstones.contains(questKey($0, s, now: now)) }.count
  }
  static func claimQuest(_ s: inout State, quest: MonthlyQuest, now: Date = Date()) throws {
    guard s.preferences.game else { throw AppError("请先开启宠物陪伴 / Enable pet companion") }
    let key = questKey(quest, s, now: now)
    guard !s.tombstones.contains(key), questProgress(quest, s, now: now) >= quest.target else {
      throw AppError("本月目标尚未完成或已领取 / Quest unavailable")
    }
    let amount = 12 + 2 * s.pet.facilityLevel(.observatory)
    grant(&s, key: key, kind: "quest", amount: amount, now: now)
    s.pet.seasonStars += 1
    if claimedQuestCount(s, now: now) == MonthlyQuest.allCases.count {
      let chapter = "monthly-chapter|\(month(now,s))"
      if !s.tombstones.contains(chapter) {
        grant(&s, key: chapter, kind: "chapter", amount: 30, now: now)
        s.pet.seasonStars += 2
      }
    }
  }
  static func facilityProblem(_ s: State, facility: PetFacility) -> String? {
    let en = s.preferences.language == "en"
    if !s.preferences.game { return en ? "Enable pet companion" : "请先开启宠物陪伴" }
    let next = s.pet.facilityLevel(facility) + 1
    if next > 4 { return en ? "Fully upgraded" : "已升至最高级" }
    if s.pet.level < facility.unlockLevel { return en ? "Grow your home first" : "猫舍等级尚不足" }
    if s.pet.seasonStars < PetFacility.starsNeeded(to: next) { return en ? "More chapter stars needed" : "章节星星尚不足" }
    if s.pet.fish < facility.cost(to: next) { return en ? "More fish needed" : "小鱼干尚不足" }
    return nil
  }
  static func upgradeFacility(_ s: inout State, facility: PetFacility) throws {
    if let problem = facilityProblem(s, facility: facility) { throw AppError(problem) }
    let next = s.pet.facilityLevel(facility) + 1
    s.pet.fish -= facility.cost(to: next)
    s.pet.facilityLevels[facility.rawValue] = next
  }
  /// V0.4 经济调整的一次性补发：旧规则下核实扣款只给包裹（0 鱼干）、打卡在饥饿时为 0 鱼干，
  /// 新规则分别为 5 和 1。按差额把历史奖励记录补足，并同步小鱼干与成长值。
  /// 只补一次（tombstone 标记）；纯记录模式遵循"不追溯发奖"约定，不补发。
  static func backfillEconomy(_ s: inout State) {
    let key = "migration|fish-backfill-v1"
    guard !s.tombstones.contains(key) else { return }
    s.tombstones.insert(key)
    guard s.preferences.game else { return }
    var delta = 0
    for i in s.rewards.indices {
      switch (s.rewards[i].kind, s.rewards[i].amount) {
      case ("parcel", 0):
        s.rewards[i].amount = 5
        delta += 5
      case ("claim", 0):
        s.rewards[i].amount = 1
        delta += 1
      default: break
      }
    }
    if delta > 0 {
      s.pet.fish += delta
      s.pet.growth += delta
    }
  }
  static func confirm(
    _ s: inout State, bill: Bill, amount: Decimal, paidAt: Date, skipped: Bool, now: Date = Date()
  ) throws {
    guard amount >= 0, calendar(s).startOfDay(for: paidAt) <= calendar(s).startOfDay(for: now)
    else { throw AppError("请填写有效的实际支付日期与金额 / Invalid payment") }
    guard !s.payments.contains(where: { $0.id == bill.id }) else { return }
    s.payments.append(
      Payment(
        id: bill.id, subscriptionID: bill.subscriptionID, due: bill.date, paidAt: paidAt,
        amount: amount, currency: bill.currency, skipped: skipped))
    let key = "parcel|\(bill.subscriptionID)|\(month(now,s))"
    guard !skipped, month(bill.date, s) == month(now, s), bill.date <= now,
      !s.tombstones.contains(key)
    else { return }
    let n = s.rewards.filter { $0.kind == "parcel" && month($0.date, s) == month(now, s) }.count
    if n < 3 {
      // 核实当月扣款：月供包裹 + 5 小鱼干（每月上限 3 次）。
      grant(&s, key: key, kind: "parcel", amount: 5, sub: bill.subscriptionID, now: now)
      if s.preferences.game { s.pet.parcels.append(key) }
    }
  }
  static func toggleEvent(_ s: inout State, id: UUID, now: Date = Date()) {
    guard let i = s.events.firstIndex(where: { $0.id == id }) else { return }
    if s.events[i].doneAt != nil {
      s.events[i].doneAt = nil
      return
    }
    s.events[i].doneAt = now
    // 在截止日（含）前完成 +5 小鱼干，每月上限 3 次；逾期完成只记录不发奖。
    let onTime =
      calendar(s).startOfDay(for: now) <= calendar(s).startOfDay(for: s.events[i].deadline)
    let key = "event|\(id)"
    if onTime, !s.tombstones.contains(key),
      s.rewards.filter({ $0.kind == "event" && month($0.date, s) == month(now, s) }).count < 3
    {
      grant(&s, key: key, kind: "event", amount: 5, sub: s.events[i].subscriptionID, now: now)
    } else {
      s.tombstones.insert(key)
    }
  }
  static func openParcel(_ s: inout State, now: Date = Date()) {
    guard s.preferences.game, !s.pet.parcels.isEmpty else { return }
    let key = s.pet.parcels.removeFirst()
    if let item = (0..<12).first(where: { !s.pet.items.contains($0) }) {
      s.pet.items.append(item)
    } else {
      grant(&s, key: "duplicate|" + key, kind: "duplicate", amount: 10, now: now)
    }
  }
  static func review(_ s: inout State, subID: UUID, cancel: Bool, now: Date = Date()) throws {
    guard let i = s.subscriptions.firstIndex(where: { $0.id == subID }) else { return }
    if cancel { s.subscriptions[i].cancelIntent = true }
    let sub = s.subscriptions[i]
    guard let b = next(sub, s, now: now),
      let days = calendar(s).dateComponents(
        [.day], from: calendar(s).startOfDay(for: now), to: b.date
      ).day, days <= 7
    else { return }
    if s.rewards.filter({ $0.kind == "review" && month($0.date, s) == month(now, s) }).count < 5 {
      grant(&s, key: "review|" + b.id, kind: "review", amount: 10, sub: subID, now: now)
      if s.preferences.game { s.pet.titles.insert("review") }
    }
  }
  static func cancel(_ s: inout State, subID: UUID, end: Date?, now: Date = Date()) {
    guard let i = s.subscriptions.firstIndex(where: { $0.id == subID }) else { return }
    let sub = s.subscriptions[i]
    if sub.cancelledAt == nil && dusty(sub, s, now: now)
      && s.rewards.filter({ $0.kind == "cancel" && month($0.date, s) == month(now, s) }).count < 3
    {
      grant(&s, key: "cancel|\(subID)", kind: "cancel", amount: 30, sub: subID, now: now)
      if s.preferences.game { s.pet.titles.insert("stop") }
    }
    if let trial = sub.trialEnd, !sub.trialResolved, now <= trial {
      trialReward(&s, subID: subID, now: now)
      if s.preferences.game { s.pet.titles.insert("trial") }
    }
    s.subscriptions[i].plans[s.subscriptions[i].plans.count - 1].billingStop = now
    s.subscriptions[i].cancelledAt = now
    s.subscriptions[i].cancelIntent = false
    s.subscriptions[i].serviceEnd = end
    s.subscriptions[i].trialResolved = true
  }
  static func trialReward(_ s: inout State, subID: UUID, now: Date) {
    if s.rewards.filter({ $0.kind == "trial" && month($0.date, s) == month(now, s) }).count < 3 {
      grant(&s, key: "trial|\(subID)", kind: "trial", amount: 15, sub: subID, now: now)
    }
  }
  static func buy(_ s: inout State, item: Int) throws {
    guard s.preferences.game, (0..<6).contains(item), !s.pet.furniture.contains(item),
      s.pet.fish >= furnitureCosts[item]
    else { throw AppError("小鱼干不足或已拥有 / Not available") }
    s.pet.fish -= furnitureCosts[item]
    s.pet.furniture.append(item)
    s.pet.displayed.insert(item)
  }
  static func validate(_ s: State) throws {
    guard s.schemaVersion == 1, s.rulesVersion == 1,
      TimeZone(identifier: s.preferences.timezone) != nil, s.pet.fish >= 0,
      s.pet.growth >= s.pet.fish, s.pet.hunger.isFinite, (0...100).contains(s.pet.hunger),
      (0...2).contains(s.pet.coat)
    else { throw AppError("存档版本或数值不正确 / Invalid save") }
    guard Set(s.subscriptions.map(\.id)).count == s.subscriptions.count,
      Set(s.payments.map(\.id)).count == s.payments.count,
      Set(s.claims.map(\.id)).count == s.claims.count,
      Set(s.rewards.map(\.id)).count == s.rewards.count,
      Set(s.events.map(\.id)).count == s.events.count,
      Set(s.benefits.map(\.id)).count == s.benefits.count
    else { throw AppError("重复的业务记录 / Duplicate record") }
    for event in s.events {
      guard !event.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw AppError("请填写活动名称 / Event name required") }
    }
    for benefit in s.benefits {
      guard !benefit.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        benefit.kind != .none
      else { throw AppError("请填写权益名称 / Benefit name required") }
    }
    let ids = Set(s.subscriptions.map(\.id))
    // 打卡归属可以是订阅 ID（关联权益与历史数据）或独立权益自身的 ID。
    let claimOwners = ids.union(Set(s.benefits.map(\.id)))
    guard s.payments.allSatisfy({
      ids.contains($0.subscriptionID) && $0.amount >= 0 && (1...120).contains($0.coveredPeriods)
    }),
      s.claims.allSatisfy({ claimOwners.contains($0.subscriptionID) }),
      s.benefits.allSatisfy({ $0.subscriptionID.map { ids.contains($0) } ?? true }),
      s.pet.items.allSatisfy({ (0..<12).contains($0) }),
      s.pet.furniture.allSatisfy({ (0..<6).contains($0) }),
      s.pet.seasonStars >= 0,
      s.pet.facilityLevels.allSatisfy({ PetFacility(rawValue: $0.key) != nil && (1...4).contains($0.value) }),
      s.pet.placements.allSatisfy({ key, point in
        let owned = PetFacility(rawValue:key).map { s.pet.facilityLevel($0)>0 } ??
          (key.hasPrefix("furniture") && Int(key.dropFirst(9)).map { s.pet.furniture.contains($0) } == true)
        return owned && placementAllowed(x:point.x,z:point.z,level:s.pet.level)
      })
    else { throw AppError("存档关联不完整 / Invalid references") }
    for sub in s.subscriptions {
      guard !sub.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sub.plans.isEmpty
      else { throw AppError("请填写名称 / Name required") }
      for p in sub.plans {
        guard p.price > 0, p.price <= 999_999_999, (1...3650).contains(p.interval),
          ["CNY", "USD", "EUR", "HKD", "JPY", "GBP"].contains(p.currency)
        else { throw AppError("金额、币种或周期无效 / Invalid price or cycle") }
      }
    }
  }
  static func csv(_ rows: [[String]]) -> String {
    "\u{FEFF}"
      + rows.map {
        $0.map { value -> String in
          var v = value
          if let first = v.trimmingCharacters(in: .whitespacesAndNewlines).first,
            "=+-@".contains(first)
          {
            v = "'" + v
          }
          return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
      }.joined(separator: "\r\n")
  }
}
