using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using Object=UnityEngine.Object;

public sealed class PersonalSpaceNavigationTests
{
    private GameObject room;
    private Component navigation;
    private static Type TypeOf(string name)=>Type.GetType("Maaso.Avatar."+name+", Assembly-CSharp",true);
    private void Field(string name,object value)=>navigation.GetType().GetField(name).SetValue(navigation,value);
    private object Call(string name,params object[] args)=>navigation.GetType().GetMethod(name).Invoke(navigation,args);
    private Transform Point(string name,Vector3 position){var node=new GameObject(name);node.transform.SetParent(room.transform,false);node.transform.localPosition=position;return node.transform;}
    [SetUp] public void SetUp()
    {
        room=new GameObject("V4NavigationFixture");navigation=room.AddComponent(TypeOf("PersonalSpaceNavigation"));Field("Revision","v4-fixture");
        Field("WalkableRegions",new[]{new Bounds(new Vector3(0,.05f,0),new Vector3(8,.1f,8)),
            new Bounds(new Vector3(6,.05f,2.2f),new Vector3(3.6f,.1f,3.6f)),
            new Bounds(new Vector3(4.1f,.05f,2.1f),new Vector3(.2f,.1f,1))});
        Field("BedroomPortal",new Bounds(new Vector3(4.1f,1.15f,2.1f),new Vector3(.2f,2.3f,1)));
        Field("Obstacles",new[]{new Bounds(new Vector3(6.55f,.575f,2.1f),new Vector3(2.2f,1.15f,1.7f))});
        Field("RouteNodes",new[]{Point("outside",new Vector3(3.25f,0,2.1f)),Point("inside",new Vector3(4.75f,0,2.1f)),
            Point("foot",new Vector3(5.1f,0,2.1f)),Point("footSouth",new Vector3(5.1f,0,3.28f))});
    }
    [TearDown] public void TearDown()=>Object.DestroyImmediate(room);
    [Test] public void LShapeUsesUnionAndDoesNotInventFloorInTheMissingCorner()
    {
        Assert.That(Call("ContainsFoot",new Vector3(0,0,0)),Is.True);
        Assert.That(Call("ContainsFoot",new Vector3(7.2f,0,3.5f)),Is.True);
        Assert.That(Call("ContainsFoot",new Vector3(6,0,-2)),Is.False);
        Assert.That(Call("ContainsFoot",new Vector3(4.1f,0,2.1f)),Is.True);
        Assert.That(Call("ContainsFoot",new Vector3(4.1f,0,2.58f)),Is.False,"Body radius must fit through the actual portal.");
    }
    [Test] public void BedFootToSouthDiagonalIsRejectedAndRouteTurnsAroundTheFoot()
    {
        Vector3 start=new(-.35f,0,.85f),destination=new(6.3f,0,3.28f);
        Assert.That(Call("SegmentIsClear",new Vector3(5.1f,0,2.1f),destination),Is.False);
        object[] args={start,destination,Array.Empty<Transform>(),null};
        Assert.That(Call("TryBuildRoute",args),Is.True);var route=(List<Vector3>)args[3];
        Assert.That(route,Does.Contain(new Vector3(5.1f,0,3.28f)));
        Vector3 previous=start;foreach(var point in route){Assert.That(Call("SegmentIsClear",previous,point),Is.True);previous=point;}
        Assert.That(Call("CrossesBedroomPortal",start,route),Is.True);
    }
    [Test] public void ReparentedSceneUsesLocalCoordinatesAndBlockedGoalFails()
    {
        room.transform.SetPositionAndRotation(new Vector3(20,0,-7),Quaternion.Euler(0,90,0));
        Assert.That(Call("ContainsFoot",room.transform.TransformPoint(Vector3.zero)),Is.True);
        object[] args={room.transform.TransformPoint(Vector3.zero),room.transform.TransformPoint(new Vector3(6.5f,0,2)),Array.Empty<Transform>(),null};
        Assert.That(Call("TryBuildRoute",args),Is.False);
    }
    [Test] public void PocketDoorSlidesExistingRootBeforeReportingOpen()
    {
        var controller=room.AddComponent(TypeOf("PersonalSpacePocketDoor"));var root=Point("existing-slide",new Vector3(4.12f,0,2.1f));
        void Set(string name,object value)=>controller.GetType().GetField(name).SetValue(controller,value);
        object Invoke(string name,params object[] args)=>controller.GetType().GetMethod(name).Invoke(controller,args);
        Set("SlidingRoot",root);Set("ClosedLocalPosition",root.localPosition);Set("OpenLocalPosition",new Vector3(4.12f,0,1.06f));
        Assert.That(Invoke("RequestOpen"),Is.True);Invoke("Advance",.2f);
        Assert.That((bool)controller.GetType().GetProperty("IsOpen").GetValue(controller),Is.False);
        Assert.That(root.localPosition.z,Is.InRange(1.07f,2.09f));Invoke("Advance",.3f);
        Assert.That((bool)controller.GetType().GetProperty("IsOpen").GetValue(controller),Is.True);
        Assert.That(root.localPosition.z,Is.EqualTo(1.06f).Within(.0001f));
    }
    [Test] public void OrdinaryBedroomKeepsTheExistingPocketLeafClear()
    {
        var controller=room.AddComponent(TypeOf("PersonalSpacePocketDoor"));var root=Point("existing-bedroom-leaf",new Vector3(4.12f,0,2.1f));
        void Set(string name,object value)=>controller.GetType().GetField(name).SetValue(controller,value);
        Set("SlidingRoot",root);Set("ClosedLocalPosition",root.localPosition);Set("OpenLocalPosition",new Vector3(4.12f,0,1.06f));
        int children=room.GetComponentsInChildren<Transform>(true).Length;
        controller.GetType().GetMethod("PresentOpenByDefault").Invoke(controller,null);
        Assert.That((bool)controller.GetType().GetProperty("IsOpen").GetValue(controller),Is.True);
        Assert.That(root.localPosition.z,Is.EqualTo(1.06f).Within(.0001f));
        Assert.That(room.GetComponentsInChildren<Transform>(true).Length,Is.EqualTo(children),"Opening must move the authored leaf, never make a replacement.");
    }
    [Test] public void CameraMustUseTheRealPortalBelowItsHeaderAndStayAboveTheBed()
    {
        Vector3 start=new(0,1.4f,.85f),goal=new(6.5f,2.8f,2.1f);
        Assert.That(Call("ContainsCamera",new Vector3(6.5f,.7f,2.1f),.08f),Is.False);
        Assert.That(Call("ContainsCamera",new Vector3(6.5f,2.8f,2.1f),.08f),Is.True);
        Assert.That(Call("ContainsCamera",new Vector3(4.1f,2.28f,2.1f),.08f),Is.False);
        Assert.That(Call("CameraSegmentIsClear",start,goal,.08f),Is.False);
        object[] args={start,goal,null};Assert.That(Call("TryBuildCameraRoute",args),Is.True);
        var route=(List<Vector3>)args[2];Assert.That(route.Count,Is.GreaterThan(1));
        Vector3 previous=start;foreach(var point in route){Assert.That(Call("CameraSegmentIsClear",previous,point,.08f),Is.True);previous=point;}
        Assert.That(Call("CrossesBedroomPortal",start,route),Is.True);
        Assert.That(Call("ContainsCamera",new Vector3(6,1.4f,-.1f),.08f),Is.False,"The camera cannot go through the bedroom's panoramic glass.");
    }
}
