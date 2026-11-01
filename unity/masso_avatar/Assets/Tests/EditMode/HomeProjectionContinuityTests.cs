using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class HomeProjectionContinuityTests
{
    private static Type AvatarType(string name) =>
        Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);

    private static object Call(object target, string name, params object[] args) =>
        target.GetType().GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
            .Single(method => method.Name == name && method.GetParameters().Length == args.Length)
            .Invoke(target, args);

    private static T PrivateField<T>(object target, string name)
    {
        FieldInfo field = target.GetType().GetField(name, BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, "The framing contract must retain " + name + ".");
        return (T)field.GetValue(target);
    }

    [Test]
    public void PresenceHoldsIndoorPoseAndLensFromTheFirstDepartureFrame()
    {
        using var f = new Fixture();
        Projection home = f.Read();
        Assert.That(home.fov, Is.GreaterThan(38f), "The actual room must require its wider indoor lens.");
        f.Execute("exit");
        f.AssertProjection(home, "first exit command");
        for (int frame = 1; frame <= 60; frame++)
        {
            f.Advance(frame / 60f);
            f.AssertProjection(home, "departure frame " + frame);
        }
        f.WriteEvidence("departure", new[] { home, f.Read() });
    }

    [TestCase(false)]
    [TestCase(true)]
    public void FirstPrepareReframesAnAlreadyHiddenActorUsingItsRealGeometry(bool forceHidden)
    {
        using var f = new Fixture();
        Projection expected = f.Read();
        f.Mesh.enabled = forceHidden;
        f.Mesh.forceRenderingOff = forceHidden;
        f.ResetBoundsCache();
        f.Camera.fieldOfView = 37.5f;
        f.Camera.transform.position += Vector3.back * 2f;
        f.Execute("prepare");
        f.AssertProjection(expected, "cold hidden prepare");
        Assert.That(f.Mesh.enabled, Is.EqualTo(forceHidden));
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        Assert.That(f.Framing.enabled, Is.False);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void HiddenGeometryRefreshPreservesBothVisibilityFlagsAndExcludesInactiveMeshes(bool forceHidden)
    {
        using var f = new Fixture();
        Projection expected = f.Read();
        GameObject inactive = GameObject.CreatePrimitive(PrimitiveType.Cube);
        inactive.transform.SetParent(f.Root, false);
        inactive.transform.localScale = Vector3.one * 100f;
        inactive.SetActive(false);
        f.Mesh.enabled = forceHidden;
        f.Mesh.forceRenderingOff = forceHidden;
        f.ResetBoundsCache();
        f.Framing.enabled = false;
        Assert.That(Call(f.Framing, "FrameHiddenHomePresentation", f.Root), Is.EqualTo(true));
        f.AssertProjection(expected, "hidden geometry");
        Assert.That(f.Mesh.enabled, Is.EqualTo(forceHidden));
        Assert.That(f.Mesh.forceRenderingOff, Is.EqualTo(forceHidden));
        Assert.That(inactive.activeSelf, Is.False);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void LateHomeViewportIsAppliedBeforeEntryAndMatchesTheFinalProjection(bool rotated)
    {
        using var f = new Fixture();
        float finalAspect = rotated ? 852f / 393f : 393f / 852f;
        f.Camera.aspect = finalAspect;
        f.SafeArea(0.15f, 0.2f);
        Projection expected = f.Read();
        f.Camera.aspect = 393f / 852f;
        f.SafeArea(0f, 0f);
        f.Execute("prepare");
        Projection beforeLayout = f.Read();
        f.Camera.aspect = finalAspect;
        f.SafeArea(0.15f, 0.2f);
        Assert.That(f.Camera.fieldOfView, Is.EqualTo(beforeLayout.fov),
            "A viewport message only stores margins while Presence holds the camera.");
        Assert.That(f.Camera.transform.position, Is.EqualTo(beforeLayout.position));
        f.Execute("enter");
        f.AssertProjection(expected, "first visible entry frame");
        Projection first = f.Read();
        for (int frame = 1; frame <= 60; frame++)
        {
            f.Advance(frame / 60f);
            f.AssertProjection(expected, "entry frame " + frame);
        }
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        Call(f.Framing, "AdvanceFraming", 1f / 60f);
        f.AssertProjection(first, "first ordinary Home frame after entry");
        f.WriteEvidence(rotated ? "entry-rotated" : "entry-portrait", new[] { beforeLayout, first, f.Read() });
    }

    [TestCase("head", false)]
    [TestCase("upper_body", false)]
    [TestCase("head", true)]
    [TestCase("upper_body", true)]
    public void IndoorFramingInterpolatesLensAndPoseTogetherWithoutAProjectedSizePulse(string closeMode, bool returning)
    {
        using var f = new Fixture();
        // This legacy interpolation contract exercises AdvanceFraming's
        // SmoothStep branch. The V4 entry rig owns a separate routed camera
        // path and has its own real-room doorway coverage.
        Call(f.Framing, "BindEntrySafety", (object)null);
        string from = returning ? closeMode : "hero_full_body";
        string to = returning ? "hero_full_body" : closeMode;
        f.Snap(to);
        Projection destination = f.Read();
        f.Snap(from);
        Projection origin = f.Read();
        Assert.That(Mathf.Abs(destination.fov - origin.fov), Is.GreaterThan(0.5f));
        Call(f.Framing, "SetFramingModeCore", to, true);
        f.AssertProjection(origin, "mode request");
        // Computing the destination is a query, including its FOV.
        Assert.That(Call(f.Framing, "TryCalculateCurrentPose", null, 0f, false, false), Is.EqualTo(true));
        f.AssertProjection(origin, "destination calculation");
        var frames = new List<Projection> { origin };
        float previousHeight = origin.projectedHeight;
        for (int frame = 1; frame <= 36; frame++)
        {
            Call(f.Framing, "AdvanceFraming", 1f / 60f);
            Projection current = f.Read();
            float progress = Mathf.SmoothStep(0f, 1f, Mathf.Min(1f, frame / 36f));
            Assert.That(current.fov, Is.EqualTo(Mathf.Lerp(origin.fov, destination.fov, progress)).Within(0.0002f));
            Assert.That(Vector3.Distance(current.position, Vector3.Lerp(origin.position, destination.position, progress)),
                Is.LessThan(0.0002f));
            Assert.That(current.projectedHeight, Is.InRange(
                Mathf.Min(origin.projectedHeight, destination.projectedHeight) - 0.0002f,
                Mathf.Max(origin.projectedHeight, destination.projectedHeight) + 0.0002f));
            Assert.That(returning ? current.projectedHeight <= previousHeight + 0.0002f :
                current.projectedHeight >= previousHeight - 0.0002f, Is.True, "projection at frame " + frame);
            previousHeight = current.projectedHeight;
            frames.Add(current);
        }
        f.AssertProjection(destination, "final composition");
        f.WriteEvidence(closeMode + (returning ? "-return" : "-approach"), frames.ToArray());
    }

    [TestCase("transparent")]
    [TestCase("avatar_layer_excluded")]
    [TestCase("environment_hidden")]
    [TestCase("orthographic")]
    public void HiddenRefreshCannotClaimAnotherPresentation(string presentation)
    {
        using var f = new Fixture();
        f.Framing.enabled = false;
        f.Mesh.enabled = false;
        if (presentation == "transparent")
        {
            f.Camera.clearFlags = CameraClearFlags.SolidColor;
            f.Camera.backgroundColor = Color.clear;
        }
        else if (presentation == "avatar_layer_excluded")
        {
            f.Mesh.gameObject.layer = 30;
            f.Camera.cullingMask &= ~(1 << 30);
        }
        else if (presentation == "environment_hidden") f.Environment.gameObject.SetActive(false);
        else f.Camera.orthographic = true;
        Projection before = f.Read();
        Assert.That(Call(f.Framing, "FrameHiddenHomePresentation", f.Root), Is.EqualTo(false));
        f.AssertProjection(before, presentation);
        Assert.That(f.Mesh.enabled, Is.False);
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
    }

    [Test]
    public void RealHumanoidHeadReturnQueryProjectsBonesWithoutMovingTheActorOrCamera()
    {
        using var f = new Fixture();
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm");
        Assert.That(prefab, Is.Not.Null);
        Object.Instantiate(prefab, f.Root, false);
        f.Mesh.gameObject.SetActive(false);
        f.ResetBoundsCache();
        Assert.That(Call(f.Map, "AlignHomeAvatar", f.Root), Is.EqualTo(true));
        f.Snap("head");
        Assert.That(Call(f.Framing, "TryCalculateCurrentPose", null, 0f, false, false),
            Is.EqualTo(true), "The real Humanoid must populate a queryable Home pose before world ownership.");
        Projection expected = f.Read();
        object[] unownedHomeArgs = { null, 0f, false, true };
        Assert.That(Call(f.Framing, "TryCalculateCurrentPose", unownedHomeArgs), Is.EqualTo(true),
            "The same real Humanoid must have an indoor pose without entry-safety clamping.");
        object unownedHomePose = unownedHomeArgs[0];
        Vector3 unownedHomePosition = (Vector3)unownedHomePose.GetType()
            .GetProperty("Position").GetValue(unownedHomePose);
        Quaternion unownedHomeRotation = (Quaternion)unownedHomePose.GetType()
            .GetProperty("Rotation").GetValue(unownedHomePose);
        float unownedHomeFov = (float)unownedHomeArgs[1];
        Animator animator = f.Root.GetComponentInChildren<Animator>();
        Assert.That(animator != null && animator.isHuman, Is.True);
        Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
        f.Framing.enabled = false;
        f.Root.SetPositionAndRotation(new Vector3(2f, 0.3f, -2f), Quaternion.Euler(0f, 137f, 0f));
        f.Environment.gameObject.SetActive(false);
        Matrix4x4 rootBefore = f.Root.localToWorldMatrix;
        Vector3 headBefore = head.position;
        Projection cameraBefore = f.Read();
        Transform anchor = (Transform)f.Map.GetType().GetProperty("HomeAgentAnchor").GetValue(f.Map);
        Transform homeCameraReference = (Transform)f.Map.GetType()
            .GetProperty("HomeCameraReference").GetValue(f.Map);
        Assert.That(f.Framing.enabled, Is.False);
        Assert.That(PrivateField<bool>(f.Framing, "autoFrameEnabled"), Is.True);
        Assert.That(PrivateField<Component>(f.Framing, "homeMap"), Is.SameAs(f.Map));
        Assert.That(PrivateField<Transform>(f.Framing, "homeViewReference"),
            Is.SameAs(homeCameraReference));
        Assert.That(PrivateField<bool>(f.Framing, "hasAuthoredHomeFieldOfView"), Is.True);
        Assert.That(PrivateField<bool>(f.Framing, "hasCachedLocalBounds"), Is.True);
        Assert.That(PrivateField<Transform>(f.Framing, "cachedBoundsRoot"), Is.SameAs(f.Root));
        var realBodyRenderers = new List<Renderer>();
        f.Root.GetComponentsInChildren(false, realBodyRenderers);
        Assert.That(Call(f.Framing, "HasCameraLayerGeometry", realBodyRenderers), Is.EqualTo(true),
            "The real Humanoid must still have Home-camera body geometry while its pose is queried.");
        Assert.That(f.Environment.GetComponentsInChildren<Renderer>(true).Any(renderer =>
            (f.Camera.cullingMask & (1 << renderer.gameObject.layer)) != 0), Is.True,
            "The inactive Home environment must retain camera-owned geometry.");
        object[] args = { anchor, null, 0f };
        Assert.That(Call(f.Framing, "TryGetHomeReturnFramingPose", args), Is.EqualTo(true));
        object pose = args[1];
        Vector3 position = (Vector3)pose.GetType().GetProperty("Position").GetValue(pose);
        Quaternion rotation = (Quaternion)pose.GetType().GetProperty("Rotation").GetValue(pose);
        TestContext.WriteLine("real-head return-to-unowned-home=" +
            Vector3.Distance(position, unownedHomePosition).ToString("F6") +
            " return-to-displayed-camera=" + Vector3.Distance(position, expected.position).ToString("F6"));
        Assert.That(Vector3.Distance(position, unownedHomePosition), Is.LessThan(0.0005f),
            "The return query must reproduce the same grounded real-Humanoid indoor pose, not a new framing.");
        Assert.That(Quaternion.Angle(rotation, unownedHomeRotation), Is.LessThan(0.01f));
        Assert.That((float)args[2], Is.EqualTo(unownedHomeFov).Within(0.0002f));
        Assert.That(Vector3.Distance(position, expected.position), Is.LessThan(0.0005f));
        Assert.That(Quaternion.Angle(rotation, expected.rotation), Is.LessThan(0.01f));
        Assert.That((float)args[2], Is.EqualTo(expected.fov).Within(0.0002f));
        Assert.That(f.Root.localToWorldMatrix, Is.EqualTo(rootBefore));
        Assert.That(head.position, Is.EqualTo(headBefore));
        f.AssertProjection(cameraBefore, "pure return query");
        Assert.That(f.Environment.gameObject.activeSelf, Is.False);
    }

    [Serializable]
    private sealed class Projection
    {
        public Vector3 position;
        public Quaternion rotation;
        public float fov;
        public float projectedHeight;
        public Vector3 topViewport;
        public Vector3 bottomViewport;
    }

    [Serializable]
    private sealed class Evidence
    {
        public string fixture = "Actual PersonalSpaceMap with fixed 1.8m body geometry; Camera.WorldToViewportPoint";
        public Projection[] frames;
    }

    [Serializable]
    private sealed class Command
    {
        public string requestId, transitionId = "projection-continuity", phase, edge = "right";
        public int durationMs = 1000;
        public long sequence, expiresAtMs = 10000;
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Transform Root;
        public readonly Renderer Mesh;
        public readonly Camera Camera;
        public readonly Behaviour Framing;
        public readonly Transform Environment;
        public readonly Component Map;
        private readonly GameObject room;
        private readonly object presence;
        private readonly Vector3 top, bottom;
        private long sequence;
        private bool disposing;

        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = new GameObject("Projection avatar").transform;
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            body.transform.SetParent(Root, false);
            body.transform.localPosition = Vector3.up * 0.9f;
            body.transform.localScale = new Vector3(0.65f, 1.8f, 0.3f);
            Mesh = body.GetComponent<Renderer>();
            var cameraObject = new GameObject("Main Camera");
            cameraObject.tag = "MainCamera";
            Camera = cameraObject.AddComponent<Camera>();
            Camera.fieldOfView = 37.5f;
            Camera.aspect = 393f / 852f;
            Camera.nearClipPlane = 0.01f;
            Camera.clearFlags = CameraClearFlags.SolidColor;
            Camera.backgroundColor = Color.white;
            Framing = (Behaviour)cameraObject.AddComponent(AvatarType("FrontFullBodyCamera"));
            ResetBoundsCache();
            GameObject prefab = Resources.Load<GameObject>("PersonalSpaceMap");
            Assert.That(prefab, Is.Not.Null);
            room = Object.Instantiate(prefab);
            Component map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Map = map;
            Call(map, "SetWorldActive", false);
            Assert.That(Call(map, "AlignHomeAvatar", Root), Is.EqualTo(true));
            Environment = (Transform)map.GetType().GetProperty("PersistentEnvironmentRoot").GetValue(map);
            Assert.That(Environment.GetComponentsInChildren<Renderer>().Length, Is.GreaterThan(10));
            SafeArea(0.15f, 0.2f);
            top = new Vector3(Mesh.bounds.center.x, Mesh.bounds.max.y, Mesh.bounds.center.z);
            bottom = new Vector3(Mesh.bounds.center.x, Mesh.bounds.min.y, Mesh.bounds.center.z);
            Type resultType = AvatarType("AvatarPresenceResult");
            var parameter = Expression.Parameter(resultType);
            Action<object> receive = result =>
            {
                if (!disposing)
                    Assert.That((bool)resultType.GetField("ok").GetValue(result), Is.True,
                        (string)resultType.GetField("code").GetValue(result));
            };
            Delegate callback = Expression.Lambda(typeof(Action<>).MakeGenericType(resultType),
                Expression.Invoke(Expression.Constant(receive), Expression.Convert(parameter, typeof(object))), parameter).Compile();
            presence = Activator.CreateInstance(AvatarType("AvatarPresenceTransitionController"), callback);
        }

        public void ResetBoundsCache() => Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, Root);
        public void SafeArea(float topMargin, float bottomMargin) => Call(Framing, "SetViewportSafeArea", topMargin, bottomMargin);
        public void Snap(string mode)
        {
            Call(Framing, "SetFramingMode", mode);
            Call(Framing, "FrameNow");
        }
        public void Execute(string phase)
        {
            var command = new Command { requestId = "projection-" + ++sequence, sequence = sequence, phase = phase };
            Call(presence, "Execute", JsonUtility.FromJson(JsonUtility.ToJson(command), AvatarType("AvatarPresenceCommand")),
                Root, Framing, (Func<bool>)(() => true), (Action)(() => { }), 0f, 1000L);
        }
        public void Advance(float now) => Call(presence, "Advance", now, 1000L + (long)(now * 1000f));
        public Projection Read()
        {
            Vector3 t = Camera.WorldToViewportPoint(top);
            Vector3 b = Camera.WorldToViewportPoint(bottom);
            return new Projection { position = Camera.transform.position, rotation = Camera.transform.rotation,
                fov = Camera.fieldOfView, projectedHeight = t.y - b.y, topViewport = t, bottomViewport = b };
        }
        public void AssertProjection(Projection expected, string phase)
        {
            Projection actual = Read();
            Assert.That(Vector3.Distance(actual.position, expected.position), Is.LessThan(0.0002f), phase + " camera position");
            Assert.That(Quaternion.Angle(actual.rotation, expected.rotation), Is.LessThan(0.01f), phase + " camera heading");
            Assert.That(actual.fov, Is.EqualTo(expected.fov).Within(0.0002f), phase + " FOV");
            Assert.That(actual.projectedHeight, Is.EqualTo(expected.projectedHeight).Within(0.0002f), phase + " projected body height");
        }
        public void WriteEvidence(string name, Projection[] frames)
        {
            string directory = Path.Combine(Path.GetTempPath(), "maaso-home-projection-continuity");
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, name + ".json"), JsonUtility.ToJson(new Evidence { frames = frames }, true));
        }
        public void Dispose()
        {
            disposing = true;
            Call(presence, "CancelForReset", "test_complete");
            Object.DestroyImmediate(Camera.gameObject);
            Object.DestroyImmediate(Root.gameObject);
            Object.DestroyImmediate(room);
        }
    }
}
