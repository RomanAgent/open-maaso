using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarBackgroundTaskWorkTests
{
    private const string SessionA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string SessionB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private GameObject actor,room,cameraObject;
    private Animator animator;
    private object controller;
    private Component rig;
    private static Type TypeOf(string name)=>Type.GetType("Maaso.Avatar."+name+", Assembly-CSharp",true);
    private object Call(string name,params object[] args)=>controller.GetType().GetMethod(name).Invoke(controller,args);
    private string Phase=>(string)controller.GetType().GetProperty("Phase").GetValue(controller);
    private string Session=>(string)controller.GetType().GetProperty("WorkSessionId").GetValue(controller);

    private void Create()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);
        GameObject prefab=AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm");
        Assert.That(prefab,Is.Not.Null);
        actor=Object.Instantiate(prefab);actor.transform.SetPositionAndRotation(Vector3.zero,Quaternion.identity);
        animator=actor.GetComponentInChildren<Animator>(true);
        animator.runtimeAnimatorController=AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
        Assert.That(animator.isHuman,Is.True);animator.Rebind();animator.Update(0);animator.enabled=false;
        room=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        rig=room.GetComponentInChildren(TypeOf("AvatarFurnitureRig"));Assert.That(rig,Is.Not.Null);
        controller=Activator.CreateInstance(TypeOf("AvatarFurniturePoseController"));
    }
    private bool Begin(string id)=> (bool)Call("BeginWorkSession",id,actor.transform,animator,rig,0f,
        (Action<string>)(_=>{}),(Action<bool>)(_=>{}));
    private void Advance(float start,float end)
    {
        for(float t=start;t<=end+.001f;t+=1f/60)Call("Advance",t,1f/60);
    }
    private object Desk=>rig.GetType().GetMethod("Find").Invoke(rig,new object[]{"desk"});
    private Transform Point(string name)=>(Transform)Desk.GetType().GetField(name).GetValue(Desk);
    private Transform Finger(bool left)
    {
        Transform finger=animator.GetBoneTransform(left?HumanBodyBones.LeftIndexProximal:HumanBodyBones.RightIndexProximal);
        if(finger!=null)return finger;
        var hand=animator.GetBoneTransform(left?HumanBodyBones.LeftHand:HumanBodyBones.RightHand);
        foreach(var bone in hand.GetComponentsInChildren<Transform>())
            if(bone.name=="CC_Base_"+(left?"L_":"R_")+"Index1")return bone;
        return null;
    }

    [TearDown] public void TearDown()
    {
        if(controller!=null)Call("Reset",true);
        if(actor!=null)Object.DestroyImmediate(actor);
        if(room!=null)Object.DestroyImmediate(room);
        if(cameraObject!=null)Object.DestroyImmediate(cameraObject);
    }

    [Test]
    public void ReviewedAvatarWalksSitsAndAlternatesHandsWithoutRootOrFingerDrift()
    {
        Create();Vector3 initial=actor.transform.position;Quaternion facing=actor.transform.rotation;
        Assert.That(Begin(SessionA),Is.True);Advance(0,15);
        Assert.That(Phase,Is.EqualTo("working"));Assert.That(Session,Is.EqualTo(SessionA));
        Vector3 root=actor.transform.position;
        Transform left=animator.GetBoneTransform(HumanBodyBones.LeftHand),right=animator.GetBoneTransform(HumanBodyBones.RightHand);
        Transform finger=Finger(true);Assert.That(finger,Is.Not.Null);
        Call("Advance",15f,0f);Vector3 firstLeft=left.position,firstRight=right.position;
        Quaternion firstFinger=finger.localRotation;
        Call("Advance",15.10f,.10f);
        Assert.That(Vector3.Distance(left.position,firstLeft),Is.GreaterThan(.001f));
        Assert.That(Vector3.Distance(right.position,firstRight),Is.GreaterThan(.001f));
        Assert.That(Quaternion.Angle(firstFinger,finger.localRotation),Is.GreaterThan(.1f));
        for(int i=0;i<100;i++)Call("Advance",15.10f,0f);
        Quaternion repeated=finger.localRotation;
        Call("Advance",15.10f,0f);
        Assert.That(Quaternion.Angle(repeated,finger.localRotation),Is.LessThan(.001f));
        Assert.That(Vector3.Distance(root,actor.transform.position),Is.LessThan(.001f));
        Transform surface=Point("WorkSurface");
        Assert.That(left.position.y,Is.InRange(surface.position.y+.015f,surface.position.y+.065f));
        Assert.That(right.position.y,Is.InRange(surface.position.y+.015f,surface.position.y+.065f));
        AvatarDeskContactEvidence.VerifyAndCapture("Joy-editor",actor,rig,left,right);
        Assert.That((bool)Call("EndWorkSession",SessionA,16f),Is.True);Advance(16,30);
        Assert.That(Phase,Is.EqualTo("standing"));Assert.That(Session,Is.Null);
        Assert.That(Vector3.Distance(actor.transform.position,initial),Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(actor.transform.rotation,facing),Is.LessThan(.01f));
    }

    [Test]
    public void StaleStopCannotMoveAUserReplacementPostureOrANewerTask()
    {
        Create();Assert.That(Begin(SessionA),Is.True);Advance(0,15);
        Assert.That((bool)Call("EndWorkSession",SessionB,15f),Is.False);
        Assert.That(Phase,Is.EqualTo("working"));
        Assert.That((bool)Call("Begin","sit_sofa",actor.transform,animator,rig,15f,
            (Action<string>)(_=>{}),(Action<bool>)(_=>{})),Is.True);
        Assert.That(Session,Is.Null);
        Assert.That((bool)Call("EndWorkSession",SessionA,15.1f),Is.False);
        Advance(15,35);Assert.That(Phase,Is.EqualTo("seated"));
        Assert.That((bool)Call("BeginWorkSession",SessionB,actor.transform,animator,rig,35f,
            (Action<string>)(_=>{}),(Action<bool>)(_=>{})),Is.False,
            "Automatic work never replaces an existing user furniture pose.");
    }

    [Test]
    public void ExplicitUpperBodyGestureOwnsFingersDuringTypingAndAfterTaskStop()
    {
        Create();Vector3 initial=actor.transform.position;Quaternion facing=actor.transform.rotation;
        Assert.That(Begin(SessionA),Is.True);Advance(0,15);
        Transform finger=Finger(true);Assert.That(finger,Is.Not.Null);
        Quaternion explicitPose=finger.localRotation*Quaternion.Euler(0,33f,0);
        finger.localRotation=explicitPose;
        controller.GetType().GetProperty("PreserveUpperBodyGesture").SetValue(controller,true);
        Advance(15,17);
        Assert.That(Quaternion.Angle(finger.localRotation,explicitPose),Is.LessThan(.001f),
            "Task typing cannot write over an explicit upper-body gesture.");
        Assert.That((bool)Call("EndWorkSession",SessionA,17f),Is.True);
        Assert.That(Quaternion.Angle(finger.localRotation,explicitPose),Is.LessThan(.001f),
            "Task release restores only finger transforms it still owns.");
        controller.GetType().GetProperty("PreserveUpperBodyGesture").SetValue(controller,false);
        Advance(17,31);
        Assert.That(Phase,Is.EqualTo("standing"));
        Assert.That(Vector3.Distance(actor.transform.position,initial),Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(actor.transform.rotation,facing),Is.LessThan(.01f));
        Assert.That(Quaternion.Angle(finger.localRotation,explicitPose),Is.LessThan(.001f),
            "Retired typing does not revive or reset a later gesture.");
    }

    [TestCase(390f/844f)]
    [TestCase(16f/9f)]
    public void RearDeskShotShowsHeadChairAndHandsInsideTheViewport(float aspect)
    {
        Create();Assert.That(Begin(SessionA),Is.True);Advance(0,15);
        cameraObject=new GameObject("Desk work camera");var camera=cameraObject.AddComponent<Camera>();
        camera.aspect=aspect;camera.fieldOfView=58f;
        var framing=cameraObject.AddComponent(TypeOf("FrontFullBodyCamera"));
        framing.GetType().GetProperty("TargetRoot").SetValue(framing,actor.transform);
        framing.GetType().GetMethod("SetFurniturePoseActive").Invoke(framing,new object[]{true});
        framing.GetType().GetMethod("SetDeskWorkAnchor").Invoke(framing,new[]{Desk});
        framing.GetType().GetMethod("SetFramingMode").Invoke(framing,new object[]{"desk_over_shoulder"});
        framing.GetType().GetMethod("FrameNow").Invoke(framing,null);
        var head=animator.GetBoneTransform(HumanBodyBones.Head);var seat=Point("Seat");
        Assert.That(camera.transform.position.y,Is.GreaterThan(head.position.y));
        Assert.That(Vector3.Dot(camera.transform.position-head.position,seat.forward),Is.LessThan(0));
        foreach(var point in new[]{head.position,seat.position+Vector3.up*.10f,Point("WorkSurface").position,
            animator.GetBoneTransform(HumanBodyBones.LeftHand).position,animator.GetBoneTransform(HumanBodyBones.RightHand).position})
        {
            Vector3 view=camera.WorldToViewportPoint(point);
            Assert.That(view.z,Is.GreaterThan(camera.nearClipPlane));
            Assert.That(view.x,Is.InRange(0f,1f));Assert.That(view.y,Is.InRange(.2f,.85f));
        }
        Assert.That(camera.transform.position.y,Is.LessThan(2.95f),"Indoor work shot must stay below the measured ceiling.");
    }
}
