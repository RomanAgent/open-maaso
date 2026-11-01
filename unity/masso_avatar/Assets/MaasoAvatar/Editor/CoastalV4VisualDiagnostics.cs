#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using Maaso.World;
using Maaso.World.Editor;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object=UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    public static class CoastalV4VisualDiagnostics
    {
        public static void Capture()
        {
            const string scenePath="Assets/MaasoAvatar/Scenes/Companion.unity";
            var scene=EditorSceneManager.OpenScene(scenePath,OpenSceneMode.Single);
            var camera=scene.GetRootGameObjects().SelectMany(r=>r.GetComponentsInChildren<Camera>(true)).Single(c=>c.CompareTag("MainCamera"));
            var room=(GameObject)PrefabUtility.InstantiatePrefab(Resources.Load<GameObject>("PersonalSpaceMap"),scene);
            var map=room.GetComponent<PersistentWorldMapController>();PersonalSpaceSceneBuilder.PrepareRuntimePortrait(camera,map);
            camera.GetComponent<FrontFullBodyCamera>().enabled=false;camera.rect=new Rect(0,0,1,1);camera.cullingMask=~0;camera.nearClipPlane=.02f;camera.farClipPlane=100;camera.fieldOfView=62;camera.aspect=1;
            var renderers=room.GetComponentsInChildren<MeshRenderer>(true);var originalVisibility=renderers.ToDictionary(r=>r,r=>r.enabled);var report=new JArray();
            string output=Path.GetFullPath(Path.Combine(Application.dataPath,"../../../docs/verification/2026-09-22-product-resume/v4-visual-diagnostics"));Directory.CreateDirectory(output);
            foreach(var renderer in renderers.Where(r=>r.name.Contains("Entry")||r.name.Contains("Door")||r.name.Contains("Glass")||r.name.Contains("Glazing")||r.name.Contains("Ocean")))
            {
                var mesh=renderer.GetComponent<MeshFilter>().sharedMesh;var material=renderer.sharedMaterial;
                var vertices=mesh.vertices;var normals=mesh.normals;var indices=mesh.triangles;double signedVolume=0;int disagree=0;
                for(int i=0;i<indices.Length;i+=3){var a=vertices[indices[i]];var b=vertices[indices[i+1]];var c=vertices[indices[i+2]];signedVolume+=Vector3.Dot(a,Vector3.Cross(b,c))/6d;if(normals.Length==vertices.Length&&Vector3.Dot(Vector3.Cross(b-a,c-a),normals[indices[i]])<0)disagree++;}
                report.Add(new JObject{["name"]=renderer.name,["enabled"]=renderer.enabled,["active"]=renderer.gameObject.activeInHierarchy,["forceRenderingOff"]=renderer.forceRenderingOff,["layer"]=renderer.gameObject.layer,["position"]=renderer.transform.position.ToString("F5"),["scale"]=renderer.transform.lossyScale.ToString("F5"),["localPosition"]=renderer.transform.localPosition.ToString("F5"),["localRotation"]=renderer.transform.localRotation.ToString("F5"),["bounds"]=renderer.bounds.ToString("F5"),["matrix"]=renderer.localToWorldMatrix.ToString("F5"),["determinant"]=renderer.localToWorldMatrix.determinant,["shader"]=material.shader.name,["color"]=material.HasProperty("_Color")?material.color.ToString():"",["queue"]=material.renderQueue,["mode"]=material.HasProperty("_Mode")?material.GetFloat("_Mode"):-1,["signedVolume"]=signedVolume,["normalWindingDisagreements"]=disagree,["triangles"]=indices.Length/3});
            }
            File.WriteAllText(Path.Combine(output,"renderer-report.json"),report.ToString());
            var target=new RenderTexture(960,960,24){antiAliasing=4};target.Create();camera.targetTexture=target;
            void Save(string name,Vector3 at,Vector3 look)
            {
                camera.transform.position=at;camera.transform.LookAt(look);camera.Render();RenderTexture.active=target;
                var image=new Texture2D(960,960,TextureFormat.RGB24,false);image.ReadPixels(new Rect(0,0,960,960),0,0);image.Apply();File.WriteAllBytes(Path.Combine(output,name+".png"),image.EncodeToPNG());Object.DestroyImmediate(image);
            }
            try
            {
                var receiver=camera.GetComponent<UnityAvatarCommandReceiver>();
                LoginDoorwayAssetBuilder.ResetPreviewMouth(receiver);
                var actor=receiver.ActiveAvatarRoot;var head=actor.GetComponentInChildren<Animator>().GetBoneTransform(HumanBodyBones.Head);
                camera.transform.position=head.position+actor.forward*1.15f+Vector3.up*.04f;camera.transform.LookAt(head.position);
                LoginDoorwayAssetBuilder.SaveFrame(camera,target,Path.Combine(output,"joy-neutral-runtime-initialized.png"));
                Save("entry-exterior",new Vector3(2.5f,1.1f,6),new Vector3(2.5f,1.1f,4));
                Save("entry-interior",new Vector3(2.5f,1.1f,2),new Vector3(2.5f,1.1f,4));
                room.GetComponentInChildren<LoginDoorwayRig>(true)?.TrySetSceneDoorOpen(1f);
                room.GetComponentInChildren<PersonalSpacePocketDoor>(true)?.PresentOpenByDefault();
                Save("entry-open-seam",new Vector3(2.5f,1.55f,6),new Vector3(2.5f,2.1f,4));
                Save("bedroom-open-seam",new Vector3(2.4f,1.55f,2.1f),new Vector3(4.1f,2.1f,2.1f));
                var entry=renderers.Where(r=>r.transform.GetComponentsInParent<Transform>().Any(t=>t.name=="V4_EntryHinge")).ToArray();
                foreach(var r in renderers)if(!entry.Contains(r))r.enabled=false;
                Save("entry-isolated-front",new Vector3(2.5f,1.1f,6),new Vector3(2.5f,1.1f,4));
                Save("entry-isolated-back",new Vector3(2.5f,1.1f,2),new Vector3(2.5f,1.1f,4));
                foreach(var r in renderers)r.enabled=originalVisibility[r];
                Vector3 windowCamera=new(2.2f,1.6f,-2.4f),windowLook=new(0,1.6f,-4);
                Save("window-baseline",windowCamera,windowLook);
                foreach(var r in renderers.Where(r=>r.name.Contains("Glass")||r.name.Contains("Ocean")||r.name.Contains("Glazing")))
                {r.enabled=false;Save("window-without-"+r.name,windowCamera,windowLook);r.enabled=true;}
                camera.farClipPlane=50;
                Save("window-chair-far50",new Vector3(1.05f,1.55f,-1.18f),new Vector3(2.42f,1.05f,-2.62f));
                camera.farClipPlane=1000;
                Save("window-chair-far1000",new Vector3(1.05f,1.55f,-1.18f),new Vector3(2.42f,1.05f,-2.62f));
            }
            finally{camera.targetTexture=null;RenderTexture.active=null;target.Release();Object.DestroyImmediate(target);Object.DestroyImmediate(room);EditorSceneManager.OpenScene(scenePath,OpenSceneMode.Single);}
        }
    }
}
#endif
