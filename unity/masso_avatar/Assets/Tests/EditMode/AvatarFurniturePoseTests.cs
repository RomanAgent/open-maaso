using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarFurniturePoseTests
{
    private GameObject actor, room;
    private Animator animator;
    private Component rig;
    private object controller;
    private readonly List<string> phases = new();
    private bool walking;
    private static Type TypeOf(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private object Call(string name, params object[] args) => controller.GetType().GetMethod(name).Invoke(controller,args);
    private string Phase => (string)controller.GetType().GetProperty("Phase").GetValue(controller);
    private bool Active => (bool)controller.GetType().GetProperty("Active").GetValue(controller);

    [SetUp] public void SetUp()
    {
        var prefab = AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm");
        Assert.That(prefab,Is.Not.Null,"The reviewed Joy model is the furniture baseline.");
        actor=Object.Instantiate(prefab); actor.transform.SetPositionAndRotation(Vector3.zero,Quaternion.identity);
        animator=actor.GetComponentInChildren<Animator>(true); Assert.That(animator.isHuman,Is.True);
        animator.runtimeAnimatorController=AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
        animator.Rebind(); animator.Update(0); animator.enabled=false;
        var rigPrefab=AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoWorld/Editor/Legacy/PersonalSpaceFurniture.prefab");
        Assert.That(rigPrefab,Is.Not.Null,"Run PersonalSpaceFurnitureBuilder.Build before asset tests.");
        room=Object.Instantiate(rigPrefab); rig=room.GetComponent(TypeOf("AvatarFurnitureRig"));
        // State-machine fixture only. No production bed is advertised until
        // the user's Blender bedroom layout is measured and published.
        if(rig.GetType().GetMethod("Find").Invoke(rig,new object[]{"bed"})==null)
        {
            Type anchorType=TypeOf("AvatarFurnitureAnchor"); object bed=Activator.CreateInstance(anchorType);
            anchorType.GetField("Id").SetValue(bed,"bed"); anchorType.GetField("CanLie").SetValue(bed,true);
            Transform Point(string name,Vector3 point,float yaw) {var node=new GameObject(name);node.transform.SetParent(room.transform,false);node.transform.localPosition=point;node.transform.localRotation=Quaternion.Euler(0,yaw,0);return node.transform;}
            anchorType.GetField("Seat").SetValue(bed,Point("FixtureBedSeat",new Vector3(1,.5f,0),-90));
            anchorType.GetField("Lying").SetValue(bed,Point("FixtureBedLie",new Vector3(1.5f,.5f,0),0));
            anchorType.GetField("Approach").SetValue(bed,Point("FixtureBedEntry",new Vector3(.4f,0,0),-90));
            var field=rig.GetType().GetField("Anchors");var original=(Array)field.GetValue(rig);var expanded=Array.CreateInstance(anchorType,original.Length+1);
            Array.Copy(original,expanded,original.Length);expanded.SetValue(bed,original.Length);field.SetValue(rig,expanded);
        }
        controller=Activator.CreateInstance(TypeOf("AvatarFurniturePoseController")); phases.Clear(); walking=false;
    }
    [TearDown] public void TearDown()
    {
        if(controller!=null) Call("Reset",true);
        if(actor!=null) Object.DestroyImmediate(actor);
        if(room!=null) Object.DestroyImmediate(room);
    }
    private bool Begin(string action,float now=0) => (bool)Call("Begin",action,actor.transform,animator,rig,now,
        (Action<string>)(phase=>phases.Add(phase)),(Action<bool>)(value=>walking=value));
    private void Advance(float start,float end)
    { for(float t=start;t<=end+.001f;t+=1f/60) Call("Advance",t,1f/60); }

    [TestCase("sit_sofa","seated")]
    [TestCase("sit_chair","seated")]
    [TestCase("work_desk","working")]
    public void ReviewedAnchorTransitionsToStableLowerBodyPose(string action,string expected)
    {
        Vector3 initial=actor.transform.position;Quaternion facing=actor.transform.rotation;
        Assert.That(Begin(action),Is.True); Assert.That(walking,Is.True);
        Advance(0,12); Assert.That(Phase,Is.EqualTo(expected)); Assert.That(walking,Is.False);
        Assert.That(phases,Does.Contain("aligning"));
        Vector3 position=actor.transform.position; Quaternion rotation=actor.transform.rotation;
        Advance(12,15); Assert.That(Vector3.Distance(position,actor.transform.position),Is.LessThan(.001));
        Assert.That(Quaternion.Angle(rotation,actor.transform.rotation),Is.LessThan(.01));
        Assert.That(animator.GetBoneTransform(HumanBodyBones.LeftFoot).position.y,Is.GreaterThan(-.1f));
        Assert.That(Begin("stand_up",15),Is.True); Advance(15,30); Assert.That(Active,Is.False); Assert.That(Phase,Is.EqualTo("standing"));
        if(action=="work_desk")
        {
            Assert.That(Vector3.Distance(actor.transform.position,initial),Is.LessThan(.001f));
            Assert.That(Quaternion.Angle(actor.transform.rotation,facing),Is.LessThan(.01f));
        }
    }
    [Test] public void WorkingDoesNotAccumulateSpineLeanWhenAnimatorIsPaused()
    {
        Assert.That(Begin("work_desk"),Is.True); Advance(0,12);
        Transform spine=animator.GetBoneTransform(HumanBodyBones.Spine);
        Quaternion first=spine.localRotation;
        Advance(12,120);
        Assert.That(Quaternion.Angle(first,spine.localRotation),Is.LessThan(.01f));
    }
    [Test] public void WorkingHandsFaceTheDeskAndKeepWristAtTheReachableTabletopHeight()
    {
        Object.DestroyImmediate(room);room=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        rig=room.GetComponentInChildren(TypeOf("AvatarFurnitureRig"));
        Assert.That(Begin("work_desk"),Is.True);Advance(0,12);
        object anchor=rig.GetType().GetMethod("Find").Invoke(rig,new object[]{"desk"});
        Transform surface=(Transform)anchor.GetType().GetField("WorkSurface").GetValue(anchor);
        Transform seat=(Transform)anchor.GetType().GetField("Seat").GetValue(anchor);
        foreach(bool left in new[]{true,false})
        {
            Transform hand=animator.GetBoneTransform(left?HumanBodyBones.LeftHand:HumanBodyBones.RightHand);
            Transform middle=animator.GetBoneTransform(left?HumanBodyBones.LeftMiddleProximal:HumanBodyBones.RightMiddleProximal);
            if(middle==null)foreach(var child in hand.GetComponentsInChildren<Transform>())if(child.name=="CC_Base_"+(left?"L_":"R_")+"Mid1")middle=child;
            Assert.That(middle,Is.Not.Null);
            Assert.That(hand.position.y,Is.EqualTo(surface.position.y+.025f).Within(.04f));
            Assert.That(Vector3.Dot((middle.position-hand.position).normalized,seat.forward),Is.GreaterThan(.9f));
        }
    }
    [Test] public void BedSleepWakeIsContinuousAndStandingRestoresUprightActor()
    {
        Assert.That(Begin("lie_bed"),Is.True); Advance(0,12); Assert.That(Phase,Is.EqualTo("lying"));
        Assert.That(Vector3.Dot(actor.transform.forward,Vector3.up),Is.GreaterThan(.95));
        Vector3 position=actor.transform.position; Quaternion rotation=actor.transform.rotation;
        Assert.That(Begin("sit_bed",12),Is.True); Call("Advance",12f,0f);
        Assert.That(Vector3.Distance(position,actor.transform.position),Is.LessThan(.001));
        Assert.That(Quaternion.Angle(rotation,actor.transform.rotation),Is.LessThan(.01));
        Advance(12,14); Assert.That(Phase,Is.EqualTo("seated"));
        Assert.That(Vector3.Dot(actor.transform.up,Vector3.up),Is.GreaterThan(.99));
        Assert.That(Begin("stand_up",14),Is.True); Advance(14,16); Assert.That(Active,Is.False);
    }
    [Test] public void SceneDisappearanceCancelsAndReleasesOccupancy()
    {
        Assert.That(Begin("sit_chair"),Is.True); room.SetActive(false); Call("Advance",1f,.1f);
        Assert.That(Active,Is.False); room.SetActive(true); Assert.That(Begin("sit_chair",2),Is.True);
    }
    [Test] public void MissingRigAndUnknownSemanticCommandsFailWithoutMoving()
    {
        Vector3 initial=actor.transform.position;
        Assert.That(Begin("raw_bone_x"),Is.False);
        Assert.That((bool)Call("Begin","sit_sofa",actor.transform,animator,null,0f,(Action<string>)(_=>{}),(Action<bool>)(_=>{})),Is.False);
        Assert.That(actor.transform.position,Is.EqualTo(initial)); Assert.That(Active,Is.False);
    }
}
