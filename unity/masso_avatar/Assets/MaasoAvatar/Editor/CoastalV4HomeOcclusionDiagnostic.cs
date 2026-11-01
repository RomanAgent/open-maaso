#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Maaso.World;
using Maaso.World.Editor;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Read-only phone-camera A/B of the published V4 room and Joy.</summary>
    public static class CoastalV4HomeOcclusionDiagnostic
    {
        [Serializable] private sealed class Identity { public string key,modelUrl,assetName,sha256;public int version; }
        [Serializable] private sealed class Envelope { public string method,json; }
        [Serializable] private sealed class Load { public string requestId,modelUrl;public Config config; }
        [Serializable] private sealed class Config { public string modelKey,assetName,approvedAssetSha256;public int assetVersion; }
        private const string ScenePath="Assets/MaasoAvatar/Scenes/Companion.unity";
        private static readonly string Output=Path.Combine(Path.GetTempPath(),"maaso-v4-home-occlusion");

        [MenuItem("Maaso/Diagnostics/Capture V4 Joy Doorway Occlusion",false,220)]
        public static void Capture()
        {
            Directory.CreateDirectory(Output);
            // A preview scene protects an artist's open, unsaved scene.
            Scene preview=EditorSceneManager.OpenPreviewScene(ScenePath);
            RenderTexture target=null;
            try
            {
                Camera camera=preview.GetRootGameObjects().SelectMany(root=>root.GetComponentsInChildren<Camera>(true))
                    .Single(value=>value.CompareTag("MainCamera"));
                camera.scene=preview;
                GameObject room=(GameObject)PrefabUtility.InstantiatePrefab(Resources.Load<GameObject>("PersonalSpaceMap"),preview);
                var map=room.GetComponent<PersistentWorldMapController>();
                PersonalSpaceSceneBuilder.PrepareRuntimePortrait(camera,map);
                var receiver=camera.GetComponent<UnityAvatarCommandReceiver>();
                var load=new Load{requestId="v4-home-occlusion",modelUrl="unity://masso/avatar_agent"};
                receiver.OnFlutterCommand(JsonUtility.ToJson(new Envelope{method="loadAvatar",json=JsonUtility.ToJson(load)}));
                receiver.OnFlutterCommand("{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}");
                Transform matt=receiver.ActiveAvatarRoot;
                if(matt==null)
                    throw new InvalidOperationException("The actual receiver did not activate Joy.");
                var animator=matt.GetComponentInChildren<Animator>(true);
                animator.cullingMode=AnimatorCullingMode.AlwaysAnimate;
                animator.Rebind();animator.Update(1f/60f);
                var framing=camera.GetComponent<FrontFullBodyCamera>();
                framing.TargetRoot=matt;
                map.SetWorldActive(false);
                if(!map.AlignHomeAvatar(matt))throw new InvalidOperationException("Joy could not reach the Home anchor.");
                framing.SetHomeViewReference(map.HomeCameraReference);
                camera.rect=new Rect(0,0,1,1);camera.cullingMask=~0;camera.nearClipPlane=.02f;camera.farClipPlane=100;
                camera.aspect=900f/1950f;
                // 393x852 iPhone logical viewport: shared Flutter policy
                // clamps Home/login chrome to top=.16 and bottom≈.133.
                receiver.OnFlutterCommand("{\"method\":\"setViewportSafeArea\",\"json\":\"{\\\"top\\\":0.16,\\\"bottom\\\":0.133}\"}");
                receiver.OnFlutterCommand("{\"method\":\"setFraming\",\"json\":\"{\\\"mode\\\":\\\"hero_full_body\\\"}\"}");
                // Receiver's global Camera.main lookup can resolve the open
                // artist scene instead of this isolated Preview camera.
                framing.SetViewportSafeArea(.16f,.133f);
                framing.SetFramingMode("hero_full_body");
                var shelf=room.GetComponentsInChildren<MeshRenderer>(true).Single(r=>r.name=="V4_Bookshelf_Baked");
                var rig=LoginDoorwayRig.Ensure(map);
                if(rig==null)throw new InvalidOperationException("The V4 entry rig is unavailable.");

                target=new RenderTexture(900,1950,24,RenderTextureFormat.ARGB32){antiAliasing=4};
                target.Create();camera.targetTexture=target;
                var report=new JObject{
                    ["scene"]=ScenePath,["room"]="PersonalSpaceMap",["avatar"]=matt.name,
                    ["aspect"]=camera.aspect,["safeTop"]=.16f,["safeBottom"]=.133f,
                    ["framingSafeTop"]=new SerializedObject(framing).FindProperty("topSafeViewport").floatValue,
                    ["framingSafeBottom"]=new SerializedObject(framing).FindProperty("bottomSafeViewport").floatValue,
                    ["shelfBounds"]=shelf.bounds.ToString("F4"),
                    ["roomRoots"]=new JArray(preview.GetRootGameObjects().Select(root=>root.name)),
                    ["roomModelCount"]=room.GetComponentsInChildren<Transform>(true).Count(node=>node.name=="PersonalSpaceModel"),
                    ["poses"]=new JArray()
                };
                var poses=(JArray)report["poses"];
                void Record(string name)
                {
                    Save(camera,target,matt,Path.Combine(Output,name+".png"));
                    poses.Add(new JObject{
                        ["name"]=name,["cameraPosition"]=camera.transform.position.ToString("F5"),
                        ["cameraRotation"]=camera.transform.rotation.eulerAngles.ToString("F5"),
                        ["fieldOfView"]=camera.fieldOfView,
                        ["nearClipPlane"]=camera.nearClipPlane,
                        ["headViewport"]=camera.WorldToViewportPoint(animator.GetBoneTransform(HumanBodyBones.Head).position).ToString("F5"),
                        ["shelfInFront"]=shelf.bounds.min.z<camera.transform.position.z,
                    });
                }
                framing.FrameNow();
                Record("01-home-frame-now");
                if(!framing.TryGetHomeFramingPose(out CameraPose homePose,out float homeFov))
                    throw new InvalidOperationException("Home pose could not be calculated.");
                camera.transform.SetPositionAndRotation(homePose.Position,homePose.Rotation);camera.fieldOfView=homeFov;
                Record("02-home-calculated");
                if(!framing.TryGetDoorwayFramingPose(rig,out CameraPose doorwayPose,out float doorwayFov))
                    throw new InvalidOperationException("Doorway final pose could not be calculated.");
                camera.transform.SetPositionAndRotation(doorwayPose.Position,doorwayPose.Rotation);camera.fieldOfView=doorwayFov;
                Record("03-doorway-final");
                shelf.enabled=false;
                Record("04-doorway-final-without-bookshelf");
                shelf.enabled=true;
                foreach(float near in new[]{.02f,.1f,.3f})
                {
                    camera.nearClipPlane=near;
                    Record("near-"+Mathf.RoundToInt(near*100));
                }
                camera.nearClipPlane=.02f;
                foreach(float height in new[]{.9f,1.35f,1.6f})
                foreach(float depth in new[]{3.75f,3.82f,3.9f,4.2f})
                {
                    camera.transform.SetPositionAndRotation(
                        new Vector3(doorwayPose.Position.x,height,depth),doorwayPose.Rotation);
                    string label="sweep-h"+Mathf.RoundToInt(height*100)+"-z"+Mathf.RoundToInt(depth*100);
                    Record(label);
                    shelf.enabled=false;Record(label+"-without-bookshelf");shelf.enabled=true;
                }
                // Exercise the same one-camera login choreography after the
                // isolated endpoint checks. These frames make a discontinuous
                // doorway-to-Home handoff visible without changing the scene.
                var transition=new LoginDoorwayTransitionController(result=>
                {
                    if(!result.ok)throw new InvalidOperationException(result.code);
                });
                long utc=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();int sequence=0;
                void Phase(string phase,int duration,float now)=>transition.Execute(
                    new LoginDoorwayCommand{requestId="v4-occlusion-"+phase,
                        transitionId="v4-occlusion",phase=phase,durationMs=duration,
                        sequence=++sequence,expiresAtMs=utc+60000},
                    framing,rig,true,now,utc);
                Phase("prepare",0,0);Record("sequence-01-closed");
                Phase("open",650,0);transition.Advance(.325f,utc);Record("sequence-02-opening");
                transition.Advance(.65f,utc);Record("sequence-03-open");
                Phase("enter",1200,.65f);transition.Advance(1.25f,utc);Record("sequence-04-entering");
                transition.Advance(1.86f,utc);Record("sequence-05-inside");
                Phase("frame",300,1.86f);
                for(int frame=1;frame<=900&&transition.OwnsCamera;frame++)
                {
                    rig.Navigation?.BedroomDoor?.Advance(1f/60f);
                    transition.Advance(1.86f+frame/60f,utc+frame*1000/60);
                }
                if(transition.OwnsCamera)throw new InvalidOperationException("Doorway did not reach the full-body Home shot.");
                Record("sequence-06-avatar");
                matt.gameObject.SetActive(false);
                Save(camera,target,matt,Path.Combine(Output,"home-empty-room-final.png"));
                string floorCandidate="/private/tmp/maaso-v4-floor-denoised/Baked_Floor.png";
                if(File.Exists(floorCandidate))
                {
                    var floor=room.GetComponentsInChildren<MeshRenderer>(true)
                        .Single(renderer=>renderer.name=="V4_Floor_Baked");
                    var original=floor.sharedMaterial;
                    var candidateMaterial=new Material(original);
                    var candidateTexture=new Texture2D(2,2,TextureFormat.RGBA32,true);
                    try
                    {
                        if(!candidateTexture.LoadImage(File.ReadAllBytes(floorCandidate)))
                            throw new InvalidDataException("The checked Floor candidate PNG is unreadable.");
                        candidateMaterial.SetTexture("_MainTex",candidateTexture);
                        candidateMaterial.SetTexture("_EmissionMap",candidateTexture);
                        floor.sharedMaterial=candidateMaterial;
                        Save(camera,target,matt,Path.Combine(Output,"home-empty-floor-candidate.png"));
                    }
                    finally
                    {
                        floor.sharedMaterial=original;
                        Object.DestroyImmediate(candidateMaterial);
                        Object.DestroyImmediate(candidateTexture);
                    }
                }
                File.WriteAllText(Path.Combine(Output,"report.json"),report.ToString());
                Debug.Log("[CoastalV4HomeOcclusion] Captured published room and Joy to "+Output);
            }
            finally
            {
                foreach(var root in preview.GetRootGameObjects())
                    foreach(var camera in root.GetComponentsInChildren<Camera>(true))camera.targetTexture=null;
                RenderTexture.active=null;
                if(target!=null){target.Release();Object.DestroyImmediate(target);}
                EditorSceneManager.ClosePreviewScene(preview);
            }
        }

        private static void Save(Camera camera,RenderTexture target,Transform matt,string path)
        {
            var snapshots=new List<GameObject>();var meshes=new List<Mesh>();
            var originals=new Dictionary<SkinnedMeshRenderer,bool>();
            try
            {
                foreach(var source in matt.GetComponentsInChildren<SkinnedMeshRenderer>(false))
                {
                    if(source.sharedMesh==null)continue;
                    var mesh=new Mesh{name=source.name+"_PhonePreviewSkin"};source.BakeMesh(mesh);meshes.Add(mesh);
                    var snapshot=new GameObject(source.name+"_PhonePreviewSkin")
                        {hideFlags=HideFlags.HideAndDontSave,layer=source.gameObject.layer};
                    snapshots.Add(snapshot);snapshot.transform.SetParent(source.transform,false);
                    snapshot.AddComponent<MeshFilter>().sharedMesh=mesh;
                    snapshot.AddComponent<MeshRenderer>().sharedMaterials=source.sharedMaterials;
                    originals[source]=source.forceRenderingOff;source.forceRenderingOff=true;
                }
                camera.Render();RenderTexture.active=target;
                var image=new Texture2D(target.width,target.height,TextureFormat.RGB24,false);
                try{image.ReadPixels(new Rect(0,0,target.width,target.height),0,0);image.Apply();File.WriteAllBytes(path,image.EncodeToPNG());}
                finally{Object.DestroyImmediate(image);}
            }
            finally
            {
                foreach(var item in originals)item.Key.forceRenderingOff=item.Value;
                foreach(var item in snapshots)Object.DestroyImmediate(item);
                foreach(var item in meshes)Object.DestroyImmediate(item);
            }
        }
    }
}
#endif
