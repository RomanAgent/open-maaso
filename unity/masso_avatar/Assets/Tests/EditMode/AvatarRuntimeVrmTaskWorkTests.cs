using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using NUnit.Framework;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class AvatarRuntimeVrmTaskWorkTests
{
    private const string Session = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    private Vrm10Instance vrm;
    private GameObject room;
    private object furniture;
    private static Type TypeOf(string name)=>Type.GetType("Maaso.Avatar."+name+", Assembly-CSharp",true);
    private object Call(string name,params object[] args)=>furniture.GetType().GetMethod(name).Invoke(furniture,args);

    [UnityTest]
    public IEnumerator ActualRuntimeVrmLoadKeepsSeatedTypingAfterItsVrmProcessPass()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);
        Type loader=Type.GetType("Maaso.Avatar.MaasoVrmLoader, Maaso.VrmBridge",true);
        MethodInfo load=loader.GetMethod("LoadVrm10Async",new[]{typeof(string),typeof(CancellationToken)});
        var pending=(Task<Vrm10Instance>)load.Invoke(null,new object[]{
            Path.GetFullPath("Assets/MaasoAvatar/Models/Default/Joy.vrm"),CancellationToken.None});
        while(!pending.IsCompleted)yield return null;
        if(pending.IsFaulted)throw pending.Exception;
        vrm=pending.Result;Assert.That(vrm,Is.Not.Null);
        vrm.UpdateType=Vrm10Instance.UpdateTypes.None;
        Assert.That(vrm.Runtime.ControlRig,Is.Not.Null,
            "This must exercise the same default runtime ControlRig generation as approved remote VRM loads.");
        Animator animator=vrm.GetComponentInChildren<Animator>(true);
        Assert.That(animator.isHuman,Is.True);animator.Rebind();animator.Update(0);animator.enabled=false;
        vrm.transform.SetPositionAndRotation(Vector3.zero,Quaternion.identity);
        Vector3 initialRoot=vrm.transform.position;Quaternion initialFacing=vrm.transform.rotation;
        vrm.Runtime.Process();
        room=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        Component rig=room.GetComponentInChildren(TypeOf("AvatarFurnitureRig"));
        furniture=Activator.CreateInstance(TypeOf("AvatarFurniturePoseController"));
        Type sampler=Type.GetType("Maaso.Avatar.AvatarVrmContactPoseSampler, Maaso.VrmBridge",true);
        object synchronize=sampler.GetMethod("Capture").Invoke(null,new object[]{vrm.Runtime,vrm.transform});
        furniture.GetType().GetProperty("SynchronizeContactPose").SetValue(furniture,synchronize);
        vrm.Runtime.Expression.SetWeight(ExpressionKey.Aa,.6f);
        Assert.That(vrm.TryGetBoneTransform(HumanBodyBones.Jaw,out Transform jaw),Is.True);
        Quaternion jawBefore=jaw.localRotation;
        var beforeProbe=new System.Collections.Generic.List<(Transform bone,Vector3 position,Quaternion rotation)>();
        foreach(var bone in vrm.GetComponentsInChildren<Transform>(true))
            beforeProbe.Add((bone,bone.localPosition,bone.localRotation));
        bool began=(bool)Call("BeginWorkSession",Session,vrm.transform,animator,rig,0f,
            (Action<string>)(_=>{}),(Action<bool>)(_=>{}));
        if(!began)DiagnoseAdmission(animator,rig);
        Assert.That(began,Is.True,"The measured desk must admit the actual runtime VRM, not only an editor-imported prefab.");
        Assert.That(vrm.Runtime.Expression.GetWeight(ExpressionKey.Aa),Is.EqualTo(.6f).Within(.001f),
            "Contact sampling cannot advance or reset TTS expression ownership.");
        Assert.That(Quaternion.Angle(jaw.localRotation,jawBefore),Is.LessThan(.001f),
            "The bounded contact probe restores its poses and never writes the mouth.");
        foreach(var before in beforeProbe)
        {
            Assert.That(Vector3.Distance(before.bone.localPosition,before.position),Is.LessThan(.0001f),
                "Contact probing must not leak a visible positional frame: "+before.bone.name);
            Assert.That(Quaternion.Angle(before.bone.localRotation,before.rotation),Is.LessThan(.01f),
                "Contact probing must not leak a visible rotation frame: "+before.bone.name);
        }
        for(float t=0;t<=15;t+=1f/60){Call("Advance",t,1f/60);vrm.Runtime.Process();}
        Assert.That(furniture.GetType().GetProperty("Phase").GetValue(furniture),Is.EqualTo("working"));
        object desk=rig.GetType().GetMethod("Find").Invoke(rig,new object[]{"desk"});
        Transform surface=(Transform)desk.GetType().GetField("WorkSurface").GetValue(desk);
        Assert.That(vrm.TryGetBoneTransform(HumanBodyBones.LeftHand,out Transform left),Is.True);
        Assert.That(vrm.TryGetBoneTransform(HumanBodyBones.RightHand,out Transform right),Is.True);
        Call("Advance",15f,0f);vrm.Runtime.Process();
        Vector3 leftA=left.position,rightA=right.position;
        Call("Advance",15.1f,.1f);vrm.Runtime.Process();
        Assert.That(Vector3.Distance(left.position,leftA),Is.GreaterThan(.001f));
        Assert.That(Vector3.Distance(right.position,rightA),Is.GreaterThan(.001f));
        Assert.That(left.position.y,Is.InRange(surface.position.y+.015f,surface.position.y+.065f));
        Assert.That(right.position.y,Is.InRange(surface.position.y+.015f,surface.position.y+.065f));
        AvatarDeskContactEvidence.VerifyAndCapture("Joy-runtime",vrm.gameObject,rig,left,right);
        vrm.Runtime.Expression.SetWeight(ExpressionKey.Aa,.6f);vrm.Runtime.Process();
        Assert.That(vrm.Runtime.Expression.GetWeight(ExpressionKey.Aa),Is.EqualTo(.6f).Within(.001f),
            "The work presentation cannot take over TTS mouth expression ownership.");
        Assert.That(Call("EndWorkSession",Session,16f),Is.EqualTo(true));
        for(float t=16;t<=30;t+=1f/60){Call("Advance",t,1f/60);vrm.Runtime.Process();}
        Assert.That(furniture.GetType().GetProperty("Phase").GetValue(furniture),Is.EqualTo("standing"));
        Assert.That(Vector3.Distance(vrm.transform.position,initialRoot),Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(vrm.transform.rotation,initialFacing),Is.LessThan(.01f));
    }

    private void DiagnoseAdmission(Animator animator,Component rig)
    {
        object desk=rig.GetType().GetMethod("Find").Invoke(rig,new object[]{"desk"});
        Transform Point(string name)=>(Transform)desk.GetType().GetField(name).GetValue(desk);
        string sceneKey=(string)rig.GetType().GetField("SceneKey").GetValue(rig);
        TestContext.WriteLine($"runtime work facts scene={sceneKey} humanoid={animator.isHuman} rootScale={vrm.transform.lossyScale} skins={vrm.GetComponentsInChildren<SkinnedMeshRenderer>(true).Length}");
        foreach(var name in new[]{"Seat","Approach","WorkSurface"})TestContext.WriteLine($"anchor {name}={Point(name)?.position}");
        foreach(var bone in new[]{HumanBodyBones.Hips,HumanBodyBones.LeftHand,HumanBodyBones.RightHand,HumanBodyBones.LeftFoot,HumanBodyBones.RightFoot})
        {
            Transform mapped=animator.GetBoneTransform(bone);
            vrm.TryGetBoneTransform(bone,out Transform raw);
            Transform control=vrm.Runtime.ControlRig.GetBoneTransform(bone);
            TestContext.WriteLine($"bone {bone} mapped={mapped?.name}:{mapped?.position} raw={raw?.name}:{raw?.position} normalized={control?.name}:{control?.position} mappedIsControl={mapped==control}");
        }
        var measured=desk.GetType().GetField("HasMeasuredSupport");
        measured.SetValue(desk,false);
        bool diagnosticProbe=(bool)Call("BeginWorkSession",Session,vrm.transform,animator,rig,0f,
            (Action<string>)(_=>{}),(Action<bool>)(_=>{}));
        measured.SetValue(desk,true);
        TestContext.WriteLine($"diagnostic-only contact-check bypass admission={diagnosticProbe}; original required admission stays {false}");
        if(!diagnosticProbe)return;
        for(float t=0;t<=15;t+=1f/60)Call("Advance",t,1f/60);
        WriteContactFacts("before-control-sync",animator,desk);
        vrm.Runtime.Process();
        WriteContactFacts("after-control-sync",animator,desk);
    }

    private void WriteContactFacts(string phase,Animator animator,object desk)
    {
        var vertices=new System.Collections.Generic.List<Vector3>();
        foreach(var skin in vrm.GetComponentsInChildren<SkinnedMeshRenderer>(true))
        {
            if(!skin.enabled||skin.sharedMesh==null||!skin.gameObject.activeInHierarchy)continue;
            var mesh=new Mesh();
            try{skin.BakeMesh(mesh);foreach(var vertex in mesh.vertices)vertices.Add(skin.transform.TransformPoint(vertex));}
            finally{Object.DestroyImmediate(mesh);}
        }
        var minimum=furniture.GetType().GetMethod("ContactMinimum",BindingFlags.Instance|BindingFlags.NonPublic);
        Transform hips=animator.GetBoneTransform(HumanBodyBones.Hips),left=animator.GetBoneTransform(HumanBodyBones.LeftFoot),right=animator.GetBoneTransform(HumanBodyBones.RightFoot);
        float pelvis=(float)minimum.Invoke(furniture,new object[]{vertices,hips.position,.16f,true,Vector3.zero});
        float leftY=(float)minimum.Invoke(furniture,new object[]{vertices,left.position,.3f,false,right.position});
        float rightY=(float)minimum.Invoke(furniture,new object[]{vertices,right.position,.3f,false,left.position});
        TestContext.WriteLine($"{phase} vertices={vertices.Count} pelvisMin={pelvis:R} seatSupport={desk.GetType().GetField("SeatSupportY").GetValue(desk)} leftFootMin={leftY:R} rightFootMin={rightY:R} floor={desk.GetType().GetField("FootFloorY").GetValue(desk)}");
    }

    [TearDown] public void TearDown()
    {
        if(furniture!=null)Call("Reset",true);
        if(vrm!=null && vrm.Runtime.ControlRig!=null)
        {
            Object.DestroyImmediate(vrm.Runtime.ControlRig.ControlRigAnimator.avatar);
            Transform controls=vrm.transform.Find("Runtime Control Rig");
            if(controls!=null)Object.DestroyImmediate(controls.gameObject);
        }
        if(vrm!=null)Object.DestroyImmediate(vrm.gameObject);
        if(room!=null)Object.DestroyImmediate(room);
    }
}
