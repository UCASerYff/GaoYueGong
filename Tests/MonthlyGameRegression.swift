import Foundation
@main struct MonthlyGameRegression {
 static func main() throws {
  let now=Date();var s=State();s.pet.hunger=30;s.pet.settledAt=now
  assert(Engine.feed(&s,now:now));assert(s.pet.hunger==50)
  assert(!Engine.feed(&s,now:now));assert(s.pet.hunger==50)
  assert(Engine.questProgress(.care,s,now:now)==1)
  s.preferences.game=false;assert(!Engine.feed(&s,now:now.addingTimeInterval(86400)))
  s.preferences.game=true;s.pet.fish=0
  let before=s.pet.facilityLevels
  do { try Engine.upgradeFacility(&s,facility:.pantry);assertionFailure("Unaffordable upgrade accepted") } catch {}
  assert(s.pet.facilityLevels==before && s.pet.fish==0)
  assert(!Engine.placementAllowed(x:8.5,z:1,level:2))
  assert(Engine.placementAllowed(x:8.5,z:1,level:3))
  try Engine.validate(s)
  let restored=try JSONDecoder().decode(State.self,from:JSONEncoder().encode(s));try Engine.validate(restored)
  assert(restored.tombstones==s.tombstones)
  var layoutState=State();layoutState.pet.furniture=[0,2];layoutState.pet.displayed=[0,2]
  layoutState.pet.name="旧名字";let fish=layoutState.pet.fish
  Engine.migrateBeta(&layoutState);assert(layoutState.pet.name=="贝塔" && layoutState.pet.fish==fish)
  layoutState.pet.name="用户后改名";Engine.migrateBeta(&layoutState);assert(layoutState.pet.name=="用户后改名")
  let original=Engine.homeLayout(layoutState.pet)
  var bad=original;bad["furniture2"]=original["furniture0"]
  do { try Engine.applyHomeLayout(&layoutState,placements:bad);assertionFailure("Overlapping layout accepted") } catch {}
  assert(layoutState.pet.placements.isEmpty)
  bad["furniture2"]=PetPoint(x:100,z:0)
  do { try Engine.applyHomeLayout(&layoutState,placements:bad);assertionFailure("Out-of-room accepted") } catch {}
  var good=original;good["furniture2"]=PetPoint(x:3,z:0)
  try Engine.applyHomeLayout(&layoutState,placements:good)
  assert(Engine.homeLayout(layoutState.pet)==good)
  try Engine.validate(layoutState)
  let saved=try JSONDecoder().decode(State.self,from:JSONEncoder().encode(layoutState))
  assert(Engine.homeLayout(saved.pet)==good && saved.pet.name=="用户后改名")
  print("PASS Monthly: beta migration once, layout bounds/collision/atomicity/roundtrip; single feed per day, disabled mode, care quest, atomic failed upgrade, balcony boundary, save roundtrip")
 }
}
