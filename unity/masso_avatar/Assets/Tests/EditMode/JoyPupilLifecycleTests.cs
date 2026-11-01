using System;
using System.Collections;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

/// <summary>Actual Unity activation callbacks on the shipped Joy hierarchy.
/// The camera Receiver remains live while only its avatar child is suspended.</summary>
public sealed class JoyPupilLifecycleTests
{
    private const BindingFlags Flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object target, string name, params object[] args) =>
        target.GetType().GetMethods(Flags).Single(method => method.Name == name &&
            method.GetParameters().Length == args.Length).Invoke(target, args);
    private static T Property<T>(object target, string name) => (T)target.GetType().GetProperty(name).GetValue(target);

    [UnityTest]
    public IEnumerator ActualJoyChildDisableEnableKeepsBindingAndResumesTheRealAperture()
    {
        if (!Application.isPlaying)
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        yield return new EnterPlayMode();
        using var f = new RuntimeFixture();
        Assert.That(f.Receiver.isActiveAndEnabled, Is.True);
        Assert.That(f.Bound, Is.True);
        f.Affect(1f);
        yield return new WaitForSecondsRealtime(1.5f);
        Assert.That(f.Weight, Is.GreaterThan(8f), "The real continuous LateUpdates must first dilate Joy.");

        f.Root.gameObject.SetActive(false);
        yield return null;
        Assert.That(f.Receiver.isActiveAndEnabled, Is.True, "This is not a Receiver disable/rebind test.");
        Assert.That(f.Weight, Is.Zero.Within(.0001f), "Suspension restores the source aperture.");
        Assert.That(f.Bound, Is.True, "A child activation boundary must not retire the driver's binding.");
        // A held driver is still advancing on the camera. It must not write
        // onto its inactive eye, even when explicitly asked to present.
        f.Eye.SetBlendShapeWeight(f.Shape, 37f);
        Call(f.Driver, "Present");
        yield return null;
        Assert.That(f.Weight, Is.EqualTo(37f), "Inactive presentation must leave the renderer alone.");
        f.Eye.SetBlendShapeWeight(f.Shape, 0f);

        f.Root.gameObject.SetActive(true);
        f.Affect(.8f);
        yield return new WaitForSecondsRealtime(1.2f);
        Assert.That(f.Bound, Is.True);
        Assert.That(f.Weight, Is.InRange(8f, 12f), "A subsequent affect resumes the same real pupil morph.");
        Vector3[] delta = new Vector3[f.Eye.sharedMesh.vertexCount];
        f.Eye.sharedMesh.GetBlendShapeFrameVertices(f.Shape, 0, delta, null, null);
        Assert.That(delta.Count(value => value.sqrMagnitude > .0000000001f), Is.GreaterThan(100),
            "This must be the authored nonempty eye aperture, not a synthetic driver value.");
        TestContext.WriteLine("Child-only resume: bound=" + f.Bound + "; authored pupil weight=" + f.Weight);
    }

    [UnityTest]
    public IEnumerator ExplicitDriverDisposeWhileChildIsInactiveCannotBeRevivedByActivation()
    {
        if (!Application.isPlaying)
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        yield return new EnterPlayMode();
        using var f = new RuntimeFixture();
        f.Affect(1f);
        yield return new WaitForSecondsRealtime(1.2f);
        Assert.That(f.Weight, Is.GreaterThan(8f));
        f.Root.gameObject.SetActive(false);
        yield return null;
        Call(f.Driver, "Dispose");
        Assert.That(f.Bound, Is.False);
        f.Root.gameObject.SetActive(true);
        f.Affect(1f);
        yield return new WaitForSecondsRealtime(.5f);
        Assert.That(f.Receiver.isActiveAndEnabled, Is.True);
        Assert.That(f.Bound, Is.False, "Only an explicit model Bind can recreate authority after Dispose.");
        Assert.That(f.Weight, Is.Zero.Within(.0001f));
    }

    [UnityTearDown]
    public IEnumerator LeaveRuntime()
    {
        if (Application.isPlaying) yield return new ExitPlayMode();
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
    }

    private sealed class RuntimeFixture : IDisposable
    {
        public readonly Behaviour Receiver;
        public readonly Transform Root;
        public readonly SkinnedMeshRenderer Eye;
        public readonly int Shape;
        public readonly object Driver;
        public bool Bound => Property<bool>(Driver, "IsBound");
        public float Weight => Eye.GetBlendShapeWeight(Shape);
        public RuntimeFixture()
        {
            Receiver = Object.FindAnyObjectByType(A("UnityAvatarCommandReceiver")) as Behaviour;
            Assert.That(Receiver, Is.Not.Null);
            Root = Property<Transform>(Receiver, "ActiveAvatarRoot");
            Assert.That(Root, Is.Not.Null);
            Assert.That(Receiver.transform.IsChildOf(Root), Is.False,
                "Disabling the avatar must leave the camera Receiver running.");
            Driver = Receiver.GetType().GetField("pupilDynamics", Flags).GetValue(Receiver);
            Eye = Root.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Single(renderer => renderer.name == "Joy_eye");
            Shape = Eye.sharedMesh.GetBlendShapeIndex("eye_dilate");
            Assert.That(Shape, Is.GreaterThanOrEqualTo(0));
            Send("setLocalAvatarVisible", new JObject { ["visible"] = true });
            Receiver.GetType().GetField("autoBlink", Flags).SetValue(Receiver, false);
        }
        public void Affect(float surprise) => Send("setExpression", new JObject
            { ["surprised"] = surprise, ["eyeOpen"] = 1f });
        private void Send(string method, JObject payload) => Call(Receiver, "OnFlutterCommand",
            new JObject { ["method"] = method, ["json"] = payload.ToString() }.ToString());
        public void Dispose()
        {
            if (Root != null && !Root.gameObject.activeSelf) Root.gameObject.SetActive(true);
        }
    }
}
