#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Maaso.World;
using Maaso.World.Editor;
using Newtonsoft.Json.Linq;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Real room/model geometry audit, not device FPS or a user-action admission test.</summary>
    public static class FurniturePresentationDiagnostic
    {
        [Serializable] private sealed class Identity { public string key, modelUrl, assetName, sha256; public int version; }
        [Serializable] private sealed class Envelope { public string method, json; }
        [Serializable] private sealed class Load { public string requestId, modelUrl; public Config config; }
        [Serializable] private sealed class Config { public string modelKey, assetName, approvedAssetSha256; public int assetVersion; }
        private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";

        public static void CaptureV4Review()
        {
            Capture();
            LoginDoorwayAssetBuilder.Capture();
        }

        public static void Capture()
        {
            string repo = Path.GetFullPath(Path.Combine(Application.dataPath, "../../.."));
            string output = Path.Combine(repo, "docs/verification/2026-09-22-product-resume/furniture-v4");
            Directory.CreateDirectory(output);
            foreach (string model in new[] { "Joy" })
            foreach (string gesture in new[] { "sit_sofa", "sit_chair", "work_desk", "lie_bed" })
            {
                var scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
                Camera camera = scene.GetRootGameObjects().SelectMany(r => r.GetComponentsInChildren<Camera>(true))
                    .Single(c => c.CompareTag("MainCamera"));
                GameObject mapRoot = (GameObject)PrefabUtility.InstantiatePrefab(Resources.Load<GameObject>(PersistentWorldMapController.ResourceName), scene);
                var map = mapRoot.GetComponent<PersistentWorldMapController>();
                PersonalSpaceSceneBuilder.PrepareRuntimePortrait(camera, map);
                var receiver = camera.GetComponent<UnityAvatarCommandReceiver>();
                Transform actor = receiver.ActiveAvatarRoot;
                if (actor == null)
                    throw new InvalidOperationException("Actual runtime did not activate " + model);
                receiver.OnFlutterCommand("{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}");
                File.WriteAllText(Path.Combine(output, model + "-capabilities.json"), JsonUtility.ToJson(AvatarCapabilityProbe.ProbeCandidate(actor.gameObject), true));
                var animator = actor.GetComponentInChildren<Animator>();
                var vrm = actor.GetComponentInChildren<Vrm10Instance>();
                var jaw = new AvatarVrmJawOwnership(); jaw.Bind(vrm);
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.Rebind(); animator.Play("idle_shrug", 0, .25f); animator.Update(.02f);
                var rig = AvatarFurnitureRig.Ensure(map);
                if (rig == null || rig.SceneKey != "coastal_v4" || rig.Navigation == null)
                    throw new InvalidOperationException("The published V4 room must provide its own furniture rig.");
                var controller = new AvatarFurniturePoseController();
                var framing = camera.GetComponent<FrontFullBodyCamera>();
                framing.TargetRoot = actor;
                if (!controller.Begin(gesture, actor, animator, rig, 0,
                    phase => framing.SetFurniturePoseActive(phase != "standing"),
                    moving => animator.Play(moving ? "standard_walk" : "idle_shrug")))
                    throw new InvalidOperationException("Furniture diagnostic admission failed: " + model + "/" + gesture);
                for (int frame = 0; frame <= 1800; frame++)
                {
                    animator.Update(1f / 60);
                    rig.Navigation.BedroomDoor.Advance(1f / 60);
                    controller.Advance(frame / 60f, 1f / 60);
                    actor.GetComponentInChildren<AvatarHumanoidFaceRestPose>()?.Apply(0);
                    jaw.Apply(); vrm?.Runtime.Process();
                }
                string expectedPhase = gesture == "lie_bed" ? "lying" : gesture == "work_desk" ? "working" : "seated";
                if (controller.Phase != expectedPhase)
                    throw new InvalidOperationException("Furniture did not reach " + expectedPhase + ": " + model + "/" + gesture);
                var skins = actor.GetComponentsInChildren<SkinnedMeshRenderer>();
                var snapshots = new List<GameObject>();
                var baked = new List<Mesh>();
                foreach (var skin in skins)
                {
                    var mesh = new Mesh(); skin.BakeMesh(mesh); baked.Add(mesh);
                    var item = new GameObject(skin.name + "_GeometryAudit"); snapshots.Add(item);
                    item.transform.SetParent(skin.transform, false); item.layer = skin.gameObject.layer;
                    item.AddComponent<MeshFilter>().sharedMesh = mesh;
                    item.AddComponent<MeshRenderer>().sharedMaterials = skin.sharedMaterials;
                    skin.forceRenderingOff = true;
                }
                Renderer[] renderers = snapshots.Select(s => s.GetComponent<Renderer>()).ToArray();
                Bounds bounds = renderers[0].bounds; foreach (var r in renderers.Skip(1)) bounds.Encapsulate(r.bounds);
                WriteContactReport(output,model,gesture,actor,animator,rig,snapshots,mapRoot);
                camera.cullingMask = ~0; camera.fieldOfView = 48; camera.nearClipPlane = .03f;
                framing.enabled = false;
                Vector3 towardCenter = -bounds.center; towardCenter.y = 0; towardCenter.Normalize();
                var target = new RenderTexture(960, 960, 24) { antiAliasing = 4 }; target.Create();
                camera.targetTexture = target; camera.aspect = 1;
                foreach (string view in new[] { "room", "top" })
                {
                    camera.fieldOfView = view == "top" ? 82 : 58;
                    // Both diagnostic cameras remain below the real ceiling.
                    // The bedroom uses its own aisle, rather than looking
                    // through the west wall toward the main room's origin.
                    camera.transform.position = view == "top"
                        ? new Vector3(bounds.center.x + .01f, 2.92f, bounds.center.z + .01f)
                        : gesture == "lie_bed"
                            ? new Vector3(5.0f, 1.85f, 3.55f)
                            : bounds.center + towardCenter * 2.0f + Vector3.up * .65f;
                    camera.transform.LookAt(bounds.center);
                    camera.Render(); RenderTexture.active = target;
                    var image = new Texture2D(960, 960, TextureFormat.RGB24, false);
                    image.ReadPixels(new Rect(0, 0, 960, 960), 0, 0); image.Apply();
                    File.WriteAllBytes(Path.Combine(output, model + "-" + gesture + "-" + view + ".png"), image.EncodeToPNG());
                    Object.DestroyImmediate(image);
                }
                camera.targetTexture = null; RenderTexture.active = null; target.Release(); Object.DestroyImmediate(target);
                foreach (var snapshot in snapshots) Object.DestroyImmediate(snapshot);
                foreach (var mesh in baked) Object.DestroyImmediate(mesh);
                foreach(var skin in skins)skin.forceRenderingOff=false;
                if(gesture=="lie_bed")CaptureBedroomPaths(camera,map,actor,animator,controller,rig,vrm,jaw,model,repo);
                Debug.Log("[FurnitureAudit] " + model + "/" + gesture + " phase=" + controller.Phase);
                controller.Reset();
            }
            EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        }

        private static void WriteContactReport(string output,string model,string gesture,Transform actor,Animator animator,AvatarFurnitureRig rig,List<GameObject> snapshots,GameObject room)
        {
            string id=gesture=="sit_sofa"?"sofa":gesture=="sit_chair"?"chair":gesture=="work_desk"?"desk":"bed";
            var anchor=rig.Find(id);var vertices=snapshots.SelectMany(s=>s.GetComponent<MeshFilter>().sharedMesh.vertices.Select(v=>s.transform.TransformPoint(v))).ToArray();
            string surface=id=="sofa"?"V4_Sofa_Baked":id=="chair"?"V4_Lounge_Baked":id=="desk"?"V4_WorkChair_Baked":"V4_Bed";
            var supports=room.GetComponentsInChildren<MeshRenderer>().Where(r=>id=="bed"?
                r.name is "V4_BedMattress_Baked" or "V4_BedBedding_Baked" or "V4_BedPillows_Baked":r.name==surface).ToArray();
            var floors=room.GetComponentsInChildren<MeshRenderer>().Where(r=>r.name is "V4_Floor_Baked" or "V4_Rug_Baked" or "V4_BedroomFloor_Baked").ToArray();
            List<(Vector3 a,Vector3 b,Vector3 c)> Triangles(MeshRenderer[] renderers)
            {
                var result=new List<(Vector3,Vector3,Vector3)>();
                foreach(var renderer in renderers)
                {
                    var mesh=renderer.GetComponent<MeshFilter>().sharedMesh;
                    var points=mesh.vertices.Select(renderer.transform.TransformPoint).ToArray();var indices=mesh.triangles;
                    for(int i=0;i<indices.Length;i+=3)result.Add((points[indices[i]],points[indices[i+1]],points[indices[i+2]]));
                }
                return result;
            }
            var supportTriangles=Triangles(supports);var floorTriangles=Triangles(floors);
            float Height(Vector3 at,List<(Vector3 a,Vector3 b,Vector3 c)> triangles,float maximum)
            {
                float best=float.NegativeInfinity;
                foreach(var (a,b,c) in triangles)
                {
                    if(at.x<Mathf.Min(a.x,Mathf.Min(b.x,c.x))||at.x>Mathf.Max(a.x,Mathf.Max(b.x,c.x))||
                        at.z<Mathf.Min(a.z,Mathf.Min(b.z,c.z))||at.z>Mathf.Max(a.z,Mathf.Max(b.z,c.z)))continue;
                    float denominator=(b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z);if(Mathf.Abs(denominator)<1e-8f)continue;
                    float u=((b.z-c.z)*(at.x-c.x)+(c.x-b.x)*(at.z-c.z))/denominator;
                    float v=((c.z-a.z)*(at.x-c.x)+(a.x-c.x)*(at.z-c.z))/denominator;
                    if(u<0||v<0||u+v>1)continue;float y=u*a.y+v*b.y+(1-u-v)*c.y;
                    if(y<=maximum&&y>best)best=y;
                }
                return best;
            }
            float Surface(Vector3 at,bool floor=false)=>Height(at,floor?floorTriangles:supportTriangles,floor?.2f:anchor.Seat.position.y+.3f);
            JObject Contact(HumanBodyBones bone,float radius)
            {
                var center=animator.GetBoneTransform(bone).position;
                bool pelvis=bone==HumanBodyBones.Hips;
                var other=animator.GetBoneTransform(bone==HumanBodyBones.LeftFoot?HumanBodyBones.RightFoot:HumanBodyBones.LeftFoot).position;
                var near=vertices.Where(v=>new Vector2(v.x-center.x,v.z-center.z).sqrMagnitude<=radius*radius&&v.y<center.y+.2f&&
                    (pelvis?(gesture=="lie_bed"||Vector3.Dot(v-center,anchor.Seat.forward)<=.025f):
                    new Vector2(v.x-center.x,v.z-center.z).sqrMagnitude<=new Vector2(v.x-other.x,v.z-other.z).sqrMagnitude)).OrderBy(v=>v.y).ToArray();
                if(near.Length==0)return new JObject{["error"]="no_contact_vertices"};
                Vector3 low=near[0];float support=gesture=="lie_bed"||bone==HumanBodyBones.Hips?Surface(low):Surface(low,true);
                bool useFloor=gesture!="lie_bed"&&!pelvis;
                var patch=(useFloor?floorTriangles:supportTriangles).Where(t=>
                    Mathf.Min(t.a.x,Mathf.Min(t.b.x,t.c.x))<=center.x+radius&&Mathf.Max(t.a.x,Mathf.Max(t.b.x,t.c.x))>=center.x-radius&&
                    Mathf.Min(t.a.z,Mathf.Min(t.b.z,t.c.z))<=center.z+radius&&Mathf.Max(t.a.z,Mathf.Max(t.b.z,t.c.z))>=center.z-radius).ToList();
                float clearance=float.PositiveInfinity;Vector3 contact=Vector3.zero;int samples=0;
                foreach(var vertex in near)
                {
                    float height=Height(vertex,patch,useFloor?.2f:anchor.Seat.position.y+.3f);
                    if(float.IsInfinity(height))continue;samples++;
                    if(vertex.y-height<clearance){clearance=vertex.y-height;contact=vertex;}
                }
                return new JObject{["bone"]=center.ToString("F5"),["skinMin"]=low.ToString("F5"),["skinMinY"]=low.y,["supportY"]=float.IsInfinity(support)?(JToken)"no_surface":support,["gapMetres"]=float.IsInfinity(support)?(JToken)"no_surface":low.y-support,
                    ["patchMinClearanceMetres"]=float.IsInfinity(clearance)?(JToken)"no_surface":clearance,["patchContactPoint"]=contact.ToString("F5"),["patchSamples"]=samples};
            }
            var report=new JObject{["model"]=model,["gesture"]=gesture,["root"]=actor.position.ToString("F5"),["seatMarker"]=anchor.Seat.position.ToString("F5"),["markerSurfaceY"]=Surface(anchor.Lying!=null?anchor.Lying.position:anchor.Seat.position),["lyingMarker"]=anchor.Lying!=null?anchor.Lying.position.ToString("F5"):null,["pelvis"]=Contact(HumanBodyBones.Hips,.16f),["leftFoot"]=Contact(HumanBodyBones.LeftFoot,.3f),["rightFoot"]=Contact(HumanBodyBones.RightFoot,.3f)};
            File.WriteAllText(Path.Combine(output,model+"-"+gesture+"-contact.json"),report.ToString());
        }

        private static void CaptureBedroomPaths(Camera camera,PersistentWorldMapController map,Transform actor,Animator animator,AvatarFurniturePoseController posture,AvatarFurnitureRig rig,Vrm10Instance vrm,AvatarVrmJawOwnership jaw,string model,string repo)
        {
            string output=Path.Combine(repo,"docs/verification/2026-09-22-product-resume/bedroom-camera-v4");Directory.CreateDirectory(output);
            var target=new RenderTexture(900,1950,24){antiAliasing=4};target.Create();camera.targetTexture=target;camera.aspect=900f/1950;
            try
            {
                foreach(bool seated in new[]{false,true})
                {
                    if(seated)
                    {
                        if(!posture.Begin("sit_bed",actor,animator,rig,33,_=>{},_=>{}))throw new InvalidOperationException("Bed wake preview was not admitted.");
                        for(int frame=0;frame<=180;frame++){animator.Update(1f/60);posture.Advance(33+frame/60f,1f/60);jaw.Apply();vrm?.Runtime.Process();}
                    }
                    string state=seated?"seated":"lying";
                    var framing=camera.GetComponent<FrontFullBodyCamera>();framing.TargetRoot=actor;framing.SetFurniturePoseActive(true);framing.SetFramingMode(seated?"upper_body":"sleeping_top");framing.enabled=true;
                    var entry=LoginDoorwayRig.Ensure(map);var pocket=rig.Navigation.BedroomDoor;
                    // A scene-only starting condition. Readiness is still earned
                    // by the real RequestOpen/Advance code, not an injected ack.
                    var flags=System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic;
                    typeof(PersonalSpacePocketDoor).GetField("progress",flags).SetValue(pocket,0f);
                    typeof(PersonalSpacePocketDoor).GetField("requested",flags).SetValue(pocket,false);pocket.SlidingRoot.localPosition=pocket.ClosedLocalPosition;
                    var receipts=new JArray();var samples=new JArray();
                    var transition=new LoginDoorwayTransitionController(result=>{receipts.Add(JObject.Parse(JsonUtility.ToJson(result)));if(!result.ok)throw new InvalidOperationException("Bedroom camera "+model+"/"+state+": "+result.code);});
                    long utc=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();int sequence=0;
                    Vector3 original=actor.position;Quaternion rotation=actor.rotation;
                    void Phase(string phase,int ms,float now)=>transition.Execute(new LoginDoorwayCommand{requestId=model+state+phase,transitionId=model+state,phase=phase,durationMs=ms,sequence=++sequence,expiresAtMs=utc+60000},framing,entry,true,now,utc);
                    Phase("prepare",0,0);Phase("open",650,0);transition.Advance(.65f,utc);Phase("enter",1200,.65f);transition.Advance(1.86f,utc);Phase("frame",300,1.86f);
                    bool portalCaptured=false;
                    for(int frame=1;frame<=900&&transition.OwnsCamera;frame++)
                    {
                        pocket.Advance(1f/60);transition.Advance(1.86f+frame/60f,utc+frame*1000/60);
                        Vector3 local=rig.Navigation.transform.InverseTransformPoint(camera.transform.position);
                        if(frame%30==0)samples.Add(new JObject{["seconds"]=frame/60f,["x"]=local.x,["y"]=local.y,["z"]=local.z,["doorOpen"]=pocket.IsOpen});
                        if(!portalCaptured&&local.x>=4.3f&&local.x<=4.6f){LoginDoorwayAssetBuilder.SaveFrame(camera,target,Path.Combine(output,model+"-"+state+"-portal.png"));portalCaptured=true;}
                    }
                    if(transition.OwnsCamera||!portalCaptured||Vector3.Distance(original,actor.position)>.0001f||Quaternion.Angle(rotation,actor.rotation)>.001f)throw new InvalidOperationException("Bedroom route failed to preserve the actual actor or cross its portal.");
                    LoginDoorwayAssetBuilder.SaveFrame(camera,target,Path.Combine(output,model+"-"+state+"-arrival.png"));
                    File.WriteAllText(Path.Combine(output,model+"-"+state+"-route.json"),new JObject{["receipts"]=receipts,["samples"]=samples,["actorPosition"]=original.ToString("F5"),["finalFraming"]=framing.FramingMode,["finalFov"]=camera.fieldOfView}.ToString());
                }
            }
            finally{camera.targetTexture=null;RenderTexture.active=null;target.Release();Object.DestroyImmediate(target);}
        }
    }
}
#endif
