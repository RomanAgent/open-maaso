using System;
using System.Collections.Generic;
using System.Linq.Expressions;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class OpenMaasoLoginDoorwayTests
{
    private GameObject mapRoot, cameraRoot, avatar;
    private Component map, rig;
    private static Type RuntimeType(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);

    [SetUp]
    public void SetUp()
    {
        Type builder = Type.GetType("Maaso.Avatar.Editor.OpenMaasoLoginDoorwayBuilder, Assembly-CSharp-Editor", true);
        map = (Component)builder.GetMethod("Install").Invoke(null, null);
        mapRoot = map.gameObject;
        rig = (Component)RuntimeType("LoginDoorwayRig").GetMethod("Ensure").Invoke(null, new object[] { map });
        cameraRoot = new GameObject("PublicEntryTestCamera");
        var camera = cameraRoot.AddComponent<Camera>(); camera.aspect = 900f / 1950f;
        var framing = cameraRoot.AddComponent(RuntimeType("FrontFullBodyCamera"));
        avatar = GameObject.CreatePrimitive(PrimitiveType.Cube);
        avatar.name = "SameExistingActor"; avatar.transform.position = Vector3.up;
        avatar.transform.localScale = new Vector3(.5f, 2, .3f);
        framing.GetType().GetProperty("TargetRoot").SetValue(framing, avatar.transform);
        framing.GetType().GetMethod("FrameNow").Invoke(framing, null);
    }

    [TearDown]
    public void TearDown()
    {
        Object.DestroyImmediate(avatar); Object.DestroyImmediate(cameraRoot); Object.DestroyImmediate(mapRoot);
    }

    [Test]
    public void PublicSceneProvidesOneValidatedSharedEntryWithoutRoomArt()
    {
        Assert.That(rig, Is.Not.Null);
        Assert.That((bool)rig.GetType().GetProperty("IsSceneEntryBound").GetValue(rig), Is.True);
        Assert.That((bool)rig.GetType().GetMethod("ValidateEntryRoute").Invoke(rig, null), Is.True);
        Assert.That(mapRoot.GetComponentsInChildren(RuntimeType("LoginDoorwayRig"), true).Length, Is.EqualTo(1));
        var leaf = (Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Assert.That(leaf.GetComponentsInChildren<Renderer>().Length, Is.GreaterThan(1));
        foreach (var mesh in mapRoot.GetComponentsInChildren<MeshFilter>(true))
            Assert.That(mesh.sharedMesh.name, Is.EqualTo("Cube"), "Door/environment meshes must be built-in primitives, not excluded FBX art.");
    }

    [Test]
    public void OriginalDoorPhasesAnimateTheSharedLeafAndReachTheUnmovedActor()
    {
        var results = new List<string>();
        Type resultType = RuntimeType("LoginDoorwayResult");
        var parameter = Expression.Parameter(resultType);
        Action<object> report = value => results.Add(JsonUtility.ToJson(value));
        Delegate callback = Expression.Lambda(typeof(Action<>).MakeGenericType(resultType),
            Expression.Invoke(Expression.Constant(report), Expression.Convert(parameter, typeof(object))), parameter).Compile();
        Type controllerType = RuntimeType("LoginDoorwayTransitionController");
        object controller = Activator.CreateInstance(controllerType, callback);
        var framing = cameraRoot.GetComponent(RuntimeType("FrontFullBodyCamera"));
        int sequence = 0;
        void Phase(string phase, int duration, float now)
        {
            var command = JsonUtility.FromJson("{\"requestId\":\"public-" + phase + "\",\"transitionId\":\"public-entry-test\",\"phase\":\"" + phase +
                "\",\"durationMs\":" + duration + ",\"sequence\":" + (++sequence) + ",\"expiresAtMs\":10000}", RuntimeType("LoginDoorwayCommand"));
            controllerType.GetMethod("Execute").Invoke(controller, new[] { command, framing, rig, (object)true, now, 1000L });
        }
        void Advance(float now) => controllerType.GetMethod("Advance").Invoke(controller, new object[] { now, 1000L });
        Vector3 actorPosition = avatar.transform.position;
        Quaternion actorRotation = avatar.transform.rotation;
        var hinge = (Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Phase("prepare", 0, 0);
        Assert.That(results[^1], Does.Contain("\"ok\":true"));
        Vector3 closedCamera = cameraRoot.transform.position;
        Phase("open", 650, 0); Advance(.325f);
        Assert.That(Quaternion.Angle(hinge.localRotation, Quaternion.identity), Is.InRange(20, 80));
        Assert.That(Vector3.Distance(cameraRoot.transform.position, closedCamera), Is.GreaterThan(.05f));
        Advance(.65f);
        Phase("enter", 1200, .65f); Advance(1.86f);
        Phase("frame", 300, 1.86f); Advance(2.17f);
        Assert.That(results, Has.Count.EqualTo(4));
        Assert.That(results.TrueForAll(value => value.Contains("\"ok\":true")), Is.True, string.Join("\n", results));
        Assert.That((bool)controllerType.GetProperty("OwnsCamera").GetValue(controller), Is.False);
        Assert.That(Quaternion.Angle(hinge.localRotation, Quaternion.identity), Is.LessThan(.01f));
        Assert.That(avatar.transform.position, Is.EqualTo(actorPosition));
        Assert.That(avatar.transform.rotation, Is.EqualTo(actorRotation));
    }
}
