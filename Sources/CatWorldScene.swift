import SwiftUI
import SceneKit

struct CatWorldScene: View {
    @EnvironmentObject private var store: Store
    let pet: Pet
    @State private var selectedID: String? = "cat"
    @State private var feedPulse = 0
    @State private var layoutMode = false
    @State private var draft: [String:PetPoint] = [:]
    @State private var layoutNotice = ""
    private var placements:[String:PetPoint] { layoutMode ? draft : Engine.homeLayout(pet) }
    private var items: [GQWorldItem] {
        var result = [GQWorldItem(id:"__world",title:"",kind:"__world",level:pet.level,x:0,z:0,movable:false),
                      GQWorldItem(id:"cat",title:pet.name,kind:"cat",level:pet.coat,
                                  x:0,z:0,movable:false)]
        for facility in PetFacility.allCases where pet.facilityLevel(facility) > 0 {
            let p=placements[facility.rawValue] ?? PetPoint(x:0,z:0)
            result.append(GQWorldItem(id:facility.rawValue,title:facility.title(store.en),kind:facility.rawValue,
                                      level:pet.facilityLevel(facility),x:p.x,z:p.z,movable:layoutMode))
        }
        for index in pet.displayed.sorted() where (0..<6).contains(index) {
            let id="furniture\(index)", p=placements["furniture\(index)"] ?? PetPoint(x:0,z:0)
            result.append(GQWorldItem(id:id,title:store.en ? furnitureEnglish[index] : furnitureNames[index],
                                      kind:id,level:1,x:p.x,z:p.z,movable:layoutMode))
        }
        return result
    }
    private var selectedFacility: PetFacility? { selectedID.flatMap(PetFacility.init(rawValue:)) }
    private var selectedFurniture: Int? {
        guard let id=selectedID, id.hasPrefix("furniture"), let i=Int(id.dropFirst(9)), (0..<6).contains(i) else { return nil }
        return i
    }
    var overviewOnly = false
    @ViewBuilder var body: some View {
        if overviewOnly {
            GQWorldScene(mode:"cat",items:items,selectedID:nil,yaw:35,zoom:pet.level >= 3 ? 9.0 : 7.8,observationOnly:true,onSelect:{_ in},onMove:{_,_,_ in})
        } else { interactiveBody }
    }
    private var interactiveBody: some View {
        ZStack {
            GQWorldScene(mode:"cat",items:items,selectedID:selectedID,yaw:35,zoom:pet.level >= 3 ? 9.0 : 7.8,animationToken:feedPulse,catLayoutMode:layoutMode,
                         onSelect:{ selectedID=$0 },onMove:move)
            VStack {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(store.t("猫咪生活馆","CAT HOME")).font(.system(size:12,weight:.bold,design:.monospaced)).tracking(2)
                        Text(pet.name + " · Lv.\(pet.level)").font(.title2.weight(.bold))
                        Text(layoutMode ? (layoutNotice.isEmpty ? store.t("拖动家具 · 完成后保存或取消","Drag furniture · save or cancel") : layoutNotice) : store.t("点击贝塔互动 · 移动家具请进入布局模式","Click Beta · enter Layout to move furniture"))
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                    }.foregroundStyle(.white).shadow(color:.black,radius:7)
                    Spacer()
                    if layoutMode {
                        Button(store.t("取消","Cancel")) { layoutMode=false;draft=[:] }
                        Button(store.t("保存布局","Save layout")) {
                            store.update { try Engine.applyHomeLayout(&$0,placements:draft) }
                            if Engine.homeLayout(store.state.pet)==draft { layoutMode=false }
                        }.buttonStyle(.borderedProminent)
                    } else {
                        Button { draft=Engine.homeLayout(pet);layoutNotice="";layoutMode=true } label: {
                            Label(store.t("布局模式","Layout"),systemImage:"square.and.pencil")
                        }
                    }
                }.buttonStyle(.bordered).padding(17)
                Spacer()
                if !layoutMode, selectedID == "cat" {
                    HStack {
                        Label(store.t("饱食度 \(Int(pet.hunger))/100","Fullness \(Int(pet.hunger))/100"),systemImage:"pawprint.fill")
                        Spacer()
                        Button(store.t("给猫喂食","Feed the cat")) { let key = "feed|\(Engine.day(Date(),store.state))"
                            let alreadyFed = store.state.tombstones.contains(key)
                            store.update { _ = Engine.feed(&$0) }
                            if !alreadyFed && store.state.tombstones.contains(key) { feedPulse += 1 } }
                            .disabled(store.state.tombstones.contains("feed|\(Engine.day(Date(),store.state))"))
                    }.scenePanel()
                } else if !layoutMode, let facility=selectedFacility {
                    let level=pet.facilityLevel(facility)
                    let problem=Engine.facilityProblem(store.state,facility:facility)
                    HStack {
                        Label(facility.title(store.en) + " · Lv.\(level)",systemImage:facility.symbol)
                        Spacer()
                        Button(level>=4 ? store.t("已满级","Max level") : store.t("升级 · \(facility.cost(to:level+1)) 小鱼干","Upgrade · \(facility.cost(to:level+1)) fish")) { store.update { try Engine.upgradeFacility(&$0,facility:facility) } }
                            .disabled(problem != nil).help(problem ?? "")
                    }.scenePanel()
                } else if !layoutMode, let index=selectedFurniture {
                    HStack {
                        Text(store.en ? furnitureEnglish[index] : furnitureNames[index])
                        Spacer()
                        Button(store.t("收进背包","Put away")) { store.update { $0.pet.displayed.remove(index) }; selectedID=nil }
                    }.scenePanel()
                }
                HStack(spacing:8) {
                    Menu {
                        ForEach(PetFacility.allCases) { facility in
                            let problem=Engine.facilityProblem(store.state,facility:facility)
                            Button(facility.title(store.en) + (problem.map { " · \($0)" } ?? "")) {
                                store.update { try Engine.upgradeFacility(&$0,facility:facility) }
                                selectedID=facility.rawValue
                            }.disabled(problem != nil)
                        }
                    } label:{ Label(store.t("工坊","Workshop"),systemImage:"hammer.fill") }
                    Menu {
                        ForEach(0..<6,id:\.self) { i in
                            Button(store.en ? furnitureEnglish[i] : furnitureNames[i]) {
                                store.update { $0.pet.displayed.insert(i) }
                                selectedID="furniture\(i)"
                            }.disabled(!pet.furniture.contains(i) || pet.displayed.contains(i))
                        }
                    } label:{ Label(store.t("背包","Furniture"),systemImage:"shippingbox.fill") }
                    Spacer()
                    Label("\(pet.fish)",systemImage:"fish.fill")
                    Label("\(pet.seasonStars)",systemImage:"star.fill")
                }.disabled(layoutMode).font(.caption.weight(.semibold)).buttonStyle(.bordered)
                    .padding(12).background(Color(nsColor:.controlBackgroundColor).opacity(0.96),in:RoundedRectangle(cornerRadius:15))
                    .padding([.horizontal,.bottom],14)
            }
        }.frame(height:490).clipShape(RoundedRectangle(cornerRadius:22))
        .onDisappear { layoutMode=false;draft=[:] }
    }
    private func move(_ id:String,_ x:Double,_ z:Double) {
        guard layoutMode, draft[id] != nil else { return }
        guard Engine.placementAllowed(x:x,z:z,level:pet.level) else { layoutNotice=store.t("请放在房间地板内","Keep furniture on the floor");return }
        guard items.filter({ $0.id != id && $0.id != "cat" && $0.kind != "__world" }).allSatisfy({ hypot($0.x-x,$0.z-z)>1.4 }) else { layoutNotice=store.t("这里太挤了，请留出空间","Leave space between furniture");return }
        draft[id]=PetPoint(x:x,z:z);layoutNotice=""
    }
}

private extension View {
    func scenePanel() -> some View {
        self.font(.callout.weight(.semibold)).padding(13)
            .background(Color(nsColor:.controlBackgroundColor).opacity(0.96),in:RoundedRectangle(cornerRadius:14))
            .padding(.horizontal,15).padding(.bottom,8)
    }
}
