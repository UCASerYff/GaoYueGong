import AppKit
import SceneKit
@main struct BetaHomeRegression {
 static func main() throws {
  _ = NSApplication.shared
  let items=[GQWorldItem(id:"__world",title:"",kind:"__world",level:3,x:0,z:0,movable:false),GQWorldItem(id:"cat",title:"贝塔",kind:"cat",level:0,x:0,z:0,movable:false),GQWorldItem(id:"pantry",title:"储粮间",kind:"pantry",level:3,x:-4.2,z:-1.8,movable:false),GQWorldItem(id:"furniture2",title:"抓板",kind:"furniture2",level:1,x:-1.7,z:-1.5,movable:false)]
  let floor=BetaFloor(items:items)
  for from in floor.clear {
   let route=floor.path(from:from,to:floor.nearest(SCNVector3(4,0,2))!)
   assert(route.allSatisfy{floor.clear.contains($0)})
   for (a,b) in zip(route,route.dropFirst()) { assert(abs(a.x-b.x)+abs(a.z-b.z)==1) }
  }
  for row in [0,1,2,3] { assert(GQWorldBuilder.betaFrames(row:row).count == (row==0 ? 6 : row==3 ? 4 : 8)) }
  let scene=GQWorldBuilder.scene(mode:"cat",items:items,selectedID:nil)
  let cat=scene.rootNode.childNode(withName:"item:cat",recursively:true)!
  GQWorldBuilder.setBetaMotion(scene.rootNode,items:items,active:true)
  assert(cat.action(forKey:"beta-roam") != nil)
  let camera=scene.rootNode.childNode(withName:"camera",recursively:false)!
  let a=35.0 * Double.pi/180
  camera.position=SCNVector3(sin(a)*17,13,cos(a)*17);camera.look(at:SCNVector3(0,0,0));camera.camera?.orthographicScale=9.8
  let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
  renderer.update(atTime:0)
  var positions:[SCNVector3]=[]
  for time in [0.1,4.0,6.0,10.0] {
   renderer.update(atTime:time)
   positions.append(cat.presentation.position)
   let im=renderer.snapshot(atTime:time,with:CGSize(width:1400,height:800),antialiasingMode:.multisampling4X)
   let data=NSBitmapImageRep(data:im.tiffRepresentation!)!.representation(using:.png,properties:[:])!
   try data.write(to:URL(fileURLWithPath:"/tmp/gq359-cat-\(Int(time)).png"))
  }
  assert(positions.contains{hypot($0.x-positions[0].x,$0.z-positions[0].z)>0.1})
  GQWorldBuilder.setBetaMotion(scene.rootNode,items:items,active:false)
  assert(cat.action(forKey:"beta-roam")==nil)
  print("PASS Beta: frame atlas, clear-floor connected paths, movement over time, layout pauses movement; room rendered")
 }
}
