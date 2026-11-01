using System;
using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

/// <summary>Measures the actual rendered wrist pose against the moved keys,
/// and optionally exports the same baked skin used by the contact audit.</summary>
public static class AvatarDeskContactEvidence
{
    [Serializable] private sealed class Facts
    {
        public string model;
        public Vector3 keyboardCenter,keyboardSize,seat,actorRoot,leftHand,rightHand;
        public float centerError,leftTargetError,rightTargetError;
    }

    public static void VerifyAndCapture(string model,GameObject actor,Component rig,
        Transform left,Transform right)
    {
        Assert.That(rig.GetType().GetProperty("HasDeskKeyboard").GetValue(rig),Is.EqualTo(true),
            "The reviewed room must bind its readable desk-only mesh before posing.");
        Bounds keyboard=(Bounds)rig.GetType().GetProperty("DeskKeyboardBounds").GetValue(rig);
        object desk=rig.GetType().GetMethod("Find").Invoke(rig,new object[]{"desk"});
        Transform seat=(Transform)desk.GetType().GetField("Seat").GetValue(desk);
        Transform surface=(Transform)desk.GetType().GetField("WorkSurface").GetValue(desk);
        Vector3 wristCenter=surface.position-seat.forward*.08f+Vector3.up*.025f;
        var facts=new Facts{
            model=model,keyboardCenter=keyboard.center,keyboardSize=keyboard.size,seat=seat.position,
            actorRoot=actor.transform.position,leftHand=left.position,rightHand=right.position,
            centerError=Mathf.Abs(Vector3.Dot(keyboard.center-seat.position,seat.right)),
            leftTargetError=Vector3.Distance(left.position,wristCenter-seat.right*.085f),
            rightTargetError=Vector3.Distance(right.position,wristCenter+seat.right*.085f),
        };
        string output=Environment.GetEnvironmentVariable("MAASO_DESK_ALIGNMENT_OUTPUT")
            ??Path.Combine(Path.GetTempPath(),"maaso-desk-alignment");
        Directory.CreateDirectory(output);
        File.WriteAllText(Path.Combine(output,model+"-contact.json"),JsonUtility.ToJson(facts,true));
        Type displayType=Type.GetType("Maaso.Avatar.AvatarDeskWorkDisplay, Assembly-CSharp",true);
        object display=displayType.GetMethod("Ensure").Invoke(null,new[]{desk});
        Assert.That(display,Is.Not.Null,"The actual laptop display must bind the aligned desk.");
        try
        {
            displayType.GetMethod("SetWorking").Invoke(display,new object[]{true});
            displayType.GetMethod("Advance").Invoke(display,new object[]{15.1f});
            Assert.That(displayType.GetProperty("IsLit").GetValue(display),Is.EqualTo(true));
            Capture(actor,seat,surface,Path.Combine(output,model+"-rear-above.png"));
        }
        finally { displayType.GetMethod("Dispose").Invoke(display,null); }
        Assert.That(facts.centerError,Is.LessThan(.01f),"Keyboard and seated body must share their horizontal centre.");
        Assert.That(Mathf.Abs(Vector3.Dot(actor.transform.position-seat.position,seat.right)),Is.LessThan(.01f));
        Assert.That(facts.leftTargetError,Is.LessThan(.045f),"Left wrist must reach its real keyboard target without hidden reach shortening.");
        Assert.That(facts.rightTargetError,Is.LessThan(.045f),"Right wrist must reach its real keyboard target without hidden reach shortening.");
        Assert.That(surface.position.y,Is.EqualTo(keyboard.max.y).Within(.002f));
    }

    private static void Capture(GameObject actor,Transform seat,Transform surface,string path)
    {
        if(SystemInfo.graphicsDeviceType==UnityEngine.Rendering.GraphicsDeviceType.Null)
        { TestContext.WriteLine("Desk screenshot skipped: Unity has no graphics device.");return; }
        var cameraObject=new GameObject("Desk contact evidence camera");
        Camera camera=cameraObject.AddComponent<Camera>();
        Transform head=actor.GetComponentInChildren<Animator>(true).GetBoneTransform(HumanBodyBones.Head);
        camera.transform.position=head.position-seat.forward*.72f+Vector3.up*.58f;
        camera.transform.LookAt(Vector3.Lerp(head.position,surface.position,.65f));
        camera.fieldOfView=58;camera.nearClipPlane=.03f;camera.aspect=1;camera.cullingMask=~0;
        try { CaptureFromCamera(actor,camera,path); }
        finally { Object.DestroyImmediate(cameraObject); }
    }

    public static void CaptureFromCamera(GameObject actor,Camera camera,string path)
    {
        if(SystemInfo.graphicsDeviceType==UnityEngine.Rendering.GraphicsDeviceType.Null)
        { TestContext.WriteLine("Desk screenshot skipped: Unity has no graphics device.");return; }
        int width=960,height=Mathf.RoundToInt(width/camera.aspect);
        RenderTexture oldTarget=camera.targetTexture;
        var target=new RenderTexture(width,height,24);target.Create();camera.targetTexture=target;
        RenderTexture previous=RenderTexture.active;
        var snapshots=new List<GameObject>();var meshes=new List<Mesh>();
        var skins=new List<(SkinnedMeshRenderer skin,bool wasOff)>();
        Texture2D image=null;
        try
        {
            foreach(var skin in actor.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if(!skin.enabled||!skin.gameObject.activeInHierarchy||skin.sharedMesh==null)continue;
                var mesh=new Mesh();skin.BakeMesh(mesh);meshes.Add(mesh);
                var snapshot=new GameObject(skin.name+"_DeskSnapshot");snapshots.Add(snapshot);
                snapshot.transform.SetParent(skin.transform,false);snapshot.layer=skin.gameObject.layer;
                snapshot.AddComponent<MeshFilter>().sharedMesh=mesh;
                snapshot.AddComponent<MeshRenderer>().sharedMaterials=skin.sharedMaterials;
                skins.Add((skin,skin.forceRenderingOff));skin.forceRenderingOff=true;
            }
            camera.Render();RenderTexture.active=target;
            image=new Texture2D(width,height,TextureFormat.RGB24,false);
            image.ReadPixels(new Rect(0,0,width,height),0,0);image.Apply();
            File.WriteAllBytes(path,image.EncodeToPNG());
            TestContext.WriteLine("Desk contact screenshot: "+path);
        }
        finally
        {
            foreach(var value in skins)if(value.skin!=null)value.skin.forceRenderingOff=value.wasOff;
            foreach(var snapshot in snapshots)Object.DestroyImmediate(snapshot);
            foreach(var mesh in meshes)Object.DestroyImmediate(mesh);
            if(image!=null)Object.DestroyImmediate(image);
            camera.targetTexture=oldTarget;RenderTexture.active=previous;target.Release();
            Object.DestroyImmediate(target);
        }
    }
}
