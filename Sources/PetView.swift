import SwiftUI
import AppKit

struct PetView: View {
  @EnvironmentObject var store: Store
  @State var petName = ""
  let titleIDs = ["stop", "trial", "thirty", "annual", "home", "review"]
  let titles = ["及时止损", "火眼金睛", "天天开饭", "清算总账", "乔迁之喜", "明察秋毫"]
  let titlesEn = [
    "Wise exit", "Sharp eyes", "Daily meals", "Annual review", "New home", "Mindful renewal",
  ]
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Heading(
          title: store.state.pet.name + store.t("的家", "’s home"),
          subtitle: store.t("照看已买的权益，也把这间小屋慢慢养大。", "Care for what you already own, and grow this little home."))
        Spacer()
        Label("\(store.state.pet.seasonStars) " + store.t("星章","stars"), systemImage: "star.fill")
          .font(.title3.bold()).foregroundStyle(Theme.purple)
        Label("\(store.state.pet.fish) " + store.t("小鱼干","fish"), systemImage: "fish.fill").font(.title2.bold())
          .foregroundStyle(Theme.orange)
      }
      CatWorldScene(pet: store.state.pet)
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(store.t("成长旅程", "Growth journey")).font(.headline)
          Spacer()
          Text("Lv.\(store.state.pet.level)  ·  \(store.state.pet.growth) / \(store.state.pet.nextGrowth)")
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        ProgressView(value: Double(store.state.pet.growth), total: Double(store.state.pet.nextGrowth))
          .tint(Theme.teal)
        Text(store.t("每一次真实的权益领取、扣款核对与审视都会推动成长。成长等级不再封顶。", "Real benefit claims, payment checks and reviews grow your home. Levels keep going."))
          .font(.caption).foregroundStyle(.secondary)
      }.card()
      questBoard
      facilityBoard
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(store.t("饱食度", "Fullness")).font(.headline)
            Spacer()
            Text("\(Int(store.state.pet.hunger))/100").foregroundStyle(.secondary)
          }
          ProgressView(value: store.state.pet.hunger, total: 100).tint(Theme.teal)
          Button(store.t("免费喂一口", "Free daily meal")) { store.update { Engine.feed(&$0) } }
            .disabled(store.state.tombstones.contains("feed|\(Engine.day(Date(),store.state))"))
          Text(
            store.t("每天一次，不需要订阅。离开也不会失去它。", "Once a day. No subscription needed. Your cat stays.")
          ).font(.caption).foregroundStyle(.secondary)
        }.card()
        VStack(alignment: .leading, spacing: 12) {
          Text(store.t("宠物之家", "Pet home") + " · Lv.\(store.state.pet.level)").font(.headline)
          Text(
            (store.en
              ? ["Cardboard box", "Cozy nest", "Warm room", "Apartment", "Villa"]
              : ["纸箱小窝", "柔软小窝", "温馨小屋", "一室一厅", "花园别墅"])[min(4, store.state.pet.level - 1)]
          ).font(.title3)
          Text(store.t("累计成长：", "Growth: ") + "\(store.state.pet.growth)").font(.callout)
            .foregroundStyle(.secondary)
          Text(store.t("花掉小鱼干，成长也不会减少。", "Spending fish never reduces growth.")).font(.caption)
            .foregroundStyle(.secondary)
        }.card()
        VStack(alignment: .leading, spacing: 12) {
          Text(store.t("月供包裹", "Monthly parcels")).font(.headline)
          Text("\(store.state.pet.parcels.count)").font(
            .system(size: 30, weight: .bold, design: .rounded))
          Button(store.t("打开一个包裹", "Open a parcel")) { store.update { Engine.openParcel(&$0) } }
            .disabled(store.state.pet.parcels.isEmpty)
          Text(store.t("核实当月扣款后获得包裹与 5 小鱼干，有月度上限。", "Earned with a parcel and 5 fish on current bills, with monthly limits.")).font(
            .caption
          ).foregroundStyle(.secondary)
        }.card()
      }
      HStack {
        TextField(store.t("宠物名字", "Pet name"), text: $petName).textFieldStyle(.roundedBorder).frame(
          width: 180)
        Button(store.t("改名", "Rename")) {
          let value = petName.trimmingCharacters(in: .whitespacesAndNewlines)
          if !value.isEmpty { store.update { $0.pet.name = String(value.prefix(20)) } }
        }
        Spacer()
        Label(store.t("贝塔 · 三花长毛猫", "Beta · long-haired calico"), systemImage:"pawprint.fill").foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 18) {
        Text(store.t("添置一点家的样子", "Make it feel like home")).font(.headline)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
          ForEach(0..<6, id: \.self) { i in
            VStack(alignment: .leading, spacing: 12) {
              Text(store.en ? furnitureEnglish[i] : furnitureNames[i]).font(.headline)
              Text("\(furnitureCosts[i]) " + store.t("小鱼干", "fish")).font(.caption).foregroundStyle(
                .secondary)
              if store.state.pet.furniture.contains(i) {
                Button(
                  store.state.pet.displayed.contains(i)
                    ? store.t("收起来", "Put away") : store.t("摆出来", "Display")
                ) {
                  store.update { s in
                    if s.pet.displayed.contains(i) {
                      s.pet.displayed.remove(i)
                    } else {
                      s.pet.displayed.insert(i)
                    }
                  }
                }
              } else {
                Button(store.t("买下它", "Buy")) { store.update { try Engine.buy(&$0, item: i) } }
                  .disabled(store.state.pet.fish < furnitureCosts[i])
              }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
              Theme.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
          }
        }
      }.card()
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text(store.t("用品图鉴", "Collection")).font(.headline)
          Spacer()
          Text("\(store.state.pet.items.count)/12").foregroundStyle(.secondary)
        }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 18) {
          ForEach(0..<12, id: \.self) { i in
            VStack(spacing: 8) {
              Image(systemName: itemSymbols[i]).font(.system(size: 25)).frame(height: 35)
              Text(store.en ? itemEnglish[i] : itemNames[i]).font(.caption)
            }.foregroundStyle(
              store.state.pet.items.contains(i) ? Theme.orange : Color.secondary.opacity(0.3)
            ).accessibilityLabel(
              (store.en ? itemEnglish[i] : itemNames[i])
                + (store.state.pet.items.contains(i) ? " ✓" : " —"))
          }
        }
      }.card()
      VStack(alignment: .leading, spacing: 16) {
        Text(store.t("小小成就", "Small achievements")).font(.headline)
        HStack {
          ForEach(0..<6, id: \.self) { i in
            VStack(spacing: 8) {
              Image(systemName: store.state.pet.titles.contains(titleIDs[i]) ? "seal.fill" : "seal")
                .font(.title2)
              Text(store.en ? titlesEn[i] : titles[i]).font(.caption)
            }.foregroundStyle(
              store.state.pet.titles.contains(titleIDs[i])
                ? Theme.orange : Color.secondary.opacity(0.5)
            ).frame(maxWidth: .infinity)
          }
        }
      }.card()
    }.onAppear {
      petName = store.state.pet.name
      store.update { Engine.settle(&$0, now: Date()) }
    }
  }
  private var questBoard: some View {
    let completed = Engine.claimedQuestCount(store.state)
    return VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(store.t("本月章节", "This month’s chapter"), systemImage: "square.stack.3d.up.fill")
          .font(.title3.weight(.semibold))
        Spacer()
        Text("\(completed) / 4").font(.headline.monospacedDigit()).foregroundStyle(Theme.teal)
      }
      Text(store.t("完成已有订阅的日常管理来领取小鱼干与章节星星。集齐四颗任务星，再得 2 星和 30 小鱼干。", "Manage existing subscriptions to earn fish and chapter stars. Complete all four for 2 more stars and 30 fish."))
        .font(.callout).foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(MonthlyQuest.allCases) { quest in questCard(quest) }
      }
    }.card()
  }
  private func questCard(_ quest: MonthlyQuest) -> some View {
    let progress = Engine.questProgress(quest, store.state)
    let claimed = store.state.tombstones.contains(Engine.questKey(quest, store.state, now: Date()))
    let reward = 12 + 2 * store.state.pet.facilityLevel(.observatory)
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Tile(symbol: quest.symbol, color: claimed ? Theme.teal : Theme.purple)
        VStack(alignment: .leading, spacing: 3) {
          Text(quest.title(store.en)).font(.headline)
          Text(quest.detail(store.en)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      ProgressView(value: Double(min(progress, quest.target)), total: Double(quest.target))
        .tint(claimed ? Theme.teal : Theme.purple)
      HStack {
        Text("\(min(progress, quest.target)) / \(quest.target)")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
        Label("+\(reward)", systemImage: "fish.fill").font(.caption).foregroundStyle(Theme.orange)
        Label("+1", systemImage: "star.fill").font(.caption).foregroundStyle(Theme.purple)
      }
      Button(claimed ? store.t("本月已领取", "Claimed this month") : store.t("领取章节奖励", "Claim chapter reward")) {
        store.update { try Engine.claimQuest(&$0, quest: quest) }
      }.buttonStyle(.bordered).tint(Theme.purple).disabled(claimed || progress < quest.target)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background((claimed ? Theme.teal : Theme.purple).opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
  }
  private var facilityBoard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(store.t("猫舍工坊", "Home workshop"), systemImage: "hammer.fill")
          .font(.title3.weight(.semibold))
        Spacer()
        Text(store.t("4 座设施 · 每座 4 级", "4 facilities · 4 levels each"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Text(store.t("建造与升级会改变房间，还会增强喂食、领取、休息和任务奖励。章节星星用于解锁高等级。", "Build and upgrade to change the room and improve feeding, claims, rest and quest rewards. Chapter stars unlock higher tiers."))
        .font(.callout).foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(PetFacility.allCases) { facility in facilityCard(facility) }
      }
    }.card()
  }
  private func facilityCard(_ facility: PetFacility) -> some View {
    let level = store.state.pet.facilityLevel(facility)
    let next = level + 1
    let problem = Engine.facilityProblem(store.state, facility: facility)
    return VStack(alignment: .leading, spacing: 11) {
      HStack {
        Tile(symbol: facility.symbol, color: Theme.orange)
        Text(facility.title(store.en)).font(.headline)
        Spacer()
        Text("Lv.\(level) / 4").font(.caption.weight(.semibold)).foregroundStyle(Theme.teal)
      }
      HStack(spacing: 4) {
        ForEach(1...4, id: \.self) { tier in
          Capsule().fill(tier <= level ? Theme.orange : Theme.orange.opacity(0.12)).frame(height: 5)
        }
      }
      Text(facilityEffect(facility, level: level)).font(.caption).foregroundStyle(.secondary)
      if next <= 4 {
        HStack {
          Label("\(facility.cost(to: next))", systemImage: "fish.fill")
          Spacer()
          Label("\(PetFacility.starsNeeded(to: next))", systemImage: "star.fill")
        }.font(.caption).foregroundStyle(.secondary)
      }
      Button(problem ?? store.t(level == 0 ? "建造设施" : "升级设施", level == 0 ? "Build" : "Upgrade")) {
        store.update { try Engine.upgradeFacility(&$0, facility: facility) }
      }.buttonStyle(.bordered).tint(Theme.orange).disabled(problem != nil)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
  }
  private func facilityEffect(_ facility: PetFacility, level: Int) -> String {
    switch facility {
    case .pantry: return store.t("免费喂食 +\(20 + 5 * level) 饱食", "Free feeding +\(20 + 5 * level) fullness")
    case .playroom: return store.t("每次有效权益领取额外 +\(level) 小鱼干", "+\(level) fish per eligible benefit claim")
    case .greenhouse: return store.t("每日饱食衰减 \(20 - 2 * level) 点", "Daily fullness decay \(20 - 2 * level)")
    case .observatory: return store.t("每项章节奖励额外 +\(2 * level) 小鱼干", "+\(2 * level) fish per chapter quest")
    }
  }
}
