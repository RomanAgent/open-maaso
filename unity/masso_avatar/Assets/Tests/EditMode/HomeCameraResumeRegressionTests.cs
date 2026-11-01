using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEditor;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class HomeCameraResumeRegressionTests
{
    private static Type Avatar(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object target, string method, params object[] args) => target.GetType()
        .GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
        .Single(value => value.Name == method && value.GetParameters().Length == args.Length).Invoke(target, args);
    private static object Field(object target, string name) => target.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).GetValue(target);
    private static object Property(object target, string name) => target.GetType().GetProperty(name).GetValue(target);

    [Test]
    public void RealCoastalRoomAndJoyResolveAnIndoorColdHomeDestination()
    {
        using var fixture = new Fixture();
        bool fits = fixture.Record("cold-home");
        fixture.Capture("cold-home");
        Assert.That(fits, Is.True, "The published Joy and Coastal room must resolve an interior camera destination.");
        Assert.That(fixture.Inside, Is.True, "Cold Home must frame from inside the actual room.");
    }

    [TestCase(false)]
    [TestCase(true)]
    public void PreviouslyFramedOutsideCameraRecoversWhenHomeFramingIsReenabled(bool observedDevicePose)
    {
        using var fixture = new Fixture();
        fixture.Record("before-outside-restore");
        Assert.That(fixture.Inside, Is.True);
        fixture.Framing.enabled = false;
        if (observedDevicePose) fixture.RestoreObservedDevicePose();
        else fixture.RestoreSerializedScenePose();
        Assert.That(fixture.Inside, Is.False, "The shipped Companion scene pose lies beyond the room wall.");
        string prefix = observedDevicePose ? "device-pose" : "outside";
        fixture.Record(prefix + "-before-reenable");
        fixture.Capture(prefix + "-before-reenable");
        fixture.Framing.enabled = true;
        fixture.Advance();
        bool fits = fixture.Record(prefix + "-after-reenable");
        fixture.Capture(prefix + "-after-reenable");
        Assert.That(fits, Is.True, "An unavailable interior destination must be diagnosed before blaming the outside-pose guard.");
        Assert.That(fixture.Inside, Is.True, "A remembered frame must not permanently retain an out-of-room pose on restore.");
    }

    [Test]
    public void WorldOwnedOutsideCameraIsNotRecoveredByHome()
    {
        using var fixture = new Fixture();
        var type = Type.GetType("Maaso.World.WorldCameraDirector, Assembly-CSharp", true);
        var world = fixture.Camera.gameObject.AddComponent(type);
        var phase = type.GetField("phase", BindingFlags.Instance | BindingFlags.NonPublic);
        phase.SetValue(world, Enum.Parse(phase.FieldType, "Active"));
        fixture.RestoreObservedDevicePose();
        Vector3 original = fixture.Camera.transform.position;
        fixture.Advance();
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(original));
        phase.SetValue(world, Enum.Parse(phase.FieldType, "Home"));
    }

    [Test]
    public void DisabledDoorwayCameraAndValidDoorwayHandoffKeepTheirPose()
    {
        using var fixture = new Fixture();
        fixture.Framing.enabled = false;
        fixture.RestoreObservedDevicePose();
        Vector3 exterior = fixture.Camera.transform.position;
        fixture.Advance();
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(exterior), "An active doorway disables Home framing.");
        fixture.Framing.enabled = true;
        fixture.Advance();
        Assert.That(fixture.Inside, Is.True);
        Vector3 handoff = fixture.Camera.transform.position + Vector3.left * .15f;
        fixture.Camera.transform.position = handoff;
        fixture.HoldDoorwayCamera();
        fixture.Advance();
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(handoff), "A valid completed doorway shot remains stable.");
    }

    [Test]
    public void ValidIndoorCameraContinuesItsRouteWithoutJumpingToLobby()
    {
        using var fixture = new Fixture();
        Vector3 start = fixture.Camera.transform.position + Vector3.left * .5f;
        fixture.Camera.transform.position = start;
        Assert.That(fixture.Inside, Is.True);
        Call(fixture.Framing, "AdvanceFraming", 1f / 60f);
        Assert.That(Vector3.Distance(fixture.Camera.transform.position, start), Is.LessThan(.025f));
        fixture.Advance();
        Assert.That(fixture.Inside, Is.True);
    }

    [Test]
    public void RealJoyHiddenPresencePrepareAndRestoreReturnAnIndoorCamera()
    {
        using var fixture = new Fixture();
        fixture.RestoreSerializedScenePose();
        fixture.Record("presence-before-prepare");
        fixture.Execute("prepare");
        fixture.Record("presence-after-prepare");
        fixture.Capture("presence-after-prepare");
        fixture.Execute("restore");
        fixture.Advance();
        bool fits = fixture.Record("presence-after-restore");
        fixture.Capture("presence-after-restore");
        Assert.That(fits, Is.True);
        Assert.That(fixture.Inside, Is.True, "The hidden preparation and restoration must not strand the camera behind a wall.");
    }

    [Test]
    public void ColdCompanionReceiverPreparesHiddenJoyInsideRoomBeforeFirstEnterFrame()
    {
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        Camera camera = Camera.main;
        Assert.That(camera, Is.Not.Null);
        var receiver = camera.GetComponent(Avatar("UnityAvatarCommandReceiver"));
        var framing = (Behaviour)camera.GetComponent(Avatar("FrontFullBodyCamera"));
        GameObject room = null;
        Transform selected = null;
        var receipts = new List<JObject>();
        void CaptureResult(string message, string stack, LogType kind)
        {
            const string prefix = "[UnityAvatar] command result ";
            if (message.StartsWith(prefix, StringComparison.Ordinal)) receipts.Add(JObject.Parse(message.Substring(prefix.Length)));
        }
        void Send(string method, JObject body) => Call(receiver, "OnFlutterCommand",
            new JObject { ["method"] = method, ["json"] = body.ToString() }.ToString());
        Application.logMessageReceived += CaptureResult;
        try
        {
            // The real bundled VRM initializes material instances in Awake.
            // Match only Unity's known EditMode message for those exact slots.
            var initialVrm = Object.FindAnyObjectByType<Vrm10Instance>();
            Assert.That(initialVrm, Is.Not.Null);
            int materialAccessCount = initialVrm.GetComponentsInChildren<Renderer>()
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .Sum(renderer => renderer.sharedMaterials.Length);
            for (int index = 0; index < materialAccessCount; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Call(receiver, "Awake");
            Send("setLocalAvatarVisible", new JObject { ["visible"] = false });
            camera.aspect = 393f / 852f;
            Send("setViewportSafeArea", new JObject { ["top"] = .175f, ["bottom"] = .12f });
            room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
            var map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Call(map, "SetWorldActive", false);
            Send("loadAvatar", new JObject { ["requestId"] = "hidden-joy-load", ["modelUrl"] = "unity://masso/avatar_agent" });
            Assert.That(receipts.Any(r => (string)r["requestId"] == "hidden-joy-load" && (bool)r["ok"]), Is.True);
            selected = (Transform)Property(receiver, "ActiveAvatarRoot");
            Assert.That(selected.GetComponentInChildren<Vrm10Instance>(true), Is.Not.Null);
            Assert.That(selected.GetComponentsInChildren<Renderer>(true).All(renderer => !renderer.enabled), Is.True);
            Call(map, "TryAlignActiveHomeAvatar");
            Call(framing, "AdvanceFraming", 1f / 60f);
            var navigation = room.GetComponentInChildren(Avatar("PersonalSpaceNavigation"));
            void Record(string label)
            {
                TestContext.WriteLine(new JObject { ["label"] = label, ["camera"] = camera.transform.position.ToString("F5"),
                    ["fov"] = camera.fieldOfView, ["framingEnabled"] = framing.enabled,
                    ["homeReferenceBound"] = Field(framing, "homeViewReference") != null,
                    ["homeMapBound"] = Field(framing, "homeMap") != null,
                    ["target"] = selected.position.ToString("F5"),
                    ["inside"] = (bool)Call(navigation, "ContainsCamera", camera.transform.position, .08f) }.ToString());
            }
            Record("receiver-before-prepare");
            long expires = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 10000;
            Send("transitionPresence", new JObject { ["requestId"] = "hidden-joy-prepare", ["transitionId"] = "hidden-joy-entry",
                ["phase"] = "prepare", ["edge"] = "right", ["sequence"] = 1, ["durationMs"] = 1800,
                ["expiresAtMs"] = expires, ["doNotInterrupt"] = true });
            Record("receiver-after-prepare");
            Assert.That(selected.GetComponentsInChildren<Renderer>(true)
                .All(renderer => !renderer.enabled && renderer.forceRenderingOff), Is.True,
                "Room binding must preserve both the account visibility mask and hidden preparation frame.");
            bool preparedInside = (bool)Call(navigation, "ContainsCamera", camera.transform.position, .08f);
            Send("setLocalAvatarVisible", new JObject { ["visible"] = true });
            Send("transitionPresence", new JObject { ["requestId"] = "hidden-joy-enter", ["transitionId"] = "hidden-joy-entry",
                ["phase"] = "enter", ["edge"] = "right", ["sequence"] = 2, ["durationMs"] = 1800,
                ["expiresAtMs"] = expires, ["doNotInterrupt"] = true });
            Record("receiver-first-enter-frame");
            Assert.That(preparedInside, Is.True, "Hidden local visibility must not prevent binding the room needed by preparation.");
            Assert.That(Call(navigation, "ContainsCamera", camera.transform.position, .08f), Is.True,
                "The first revealed enter frame must already use an indoor camera.");
        }
        finally
        {
            Application.logMessageReceived -= CaptureResult;
            if (receiver != null) Call(receiver, "OnDisable");
            if (selected != null) Object.DestroyImmediate(selected.gameObject);
            if (room != null) Object.DestroyImmediate(room);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Camera Camera;
        public readonly Behaviour Framing;
        private readonly GameObject room, actor;
        private readonly Component map, navigation;
        private readonly object rig, presence;
        private int sequence;
        private bool disposing;
        private static string Output => Path.Combine(Path.GetTempPath(), "maaso-home-camera-recovery");

        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
            actor = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Call(map, "SetWorldActive", false);
            navigation = room.GetComponentInChildren(Avatar("PersonalSpaceNavigation"));
            rig = Avatar("LoginDoorwayRig").GetMethod("Ensure").Invoke(null, new object[] { map });
            Assert.That(rig, Is.Not.Null);
            actor.transform.SetPositionAndRotation(((Transform)Property(map, "HomeAgentAnchor")).position,
                ((Transform)Property(map, "HomeAgentAnchor")).rotation);
            Animator animator = actor.GetComponentInChildren<Animator>();
            animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            animator.Rebind(); animator.Play("idle_shrug", 0, .25f); animator.Update(0);
            Camera = new GameObject("RecoveryTestCamera", typeof(Camera)).GetComponent<Camera>();
            Camera.tag = "MainCamera";
            Camera.aspect = 393f / 852f; Camera.fieldOfView = 37.5f; Camera.nearClipPlane = .3f;
            Camera.backgroundColor = Color.white; Camera.clearFlags = CameraClearFlags.SolidColor;
            RestoreSerializedScenePose();
            Framing = (Behaviour)Camera.gameObject.AddComponent(Avatar("FrontFullBodyCamera"));
            Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, actor.transform);
            Assert.That(Call(map, "AlignHomeAvatar", actor.transform), Is.True);
            Call(Framing, "SetViewportSafeArea", .175f, .12f);
            Advance();
            Type resultType = Avatar("AvatarPresenceResult");
            var parameter = Expression.Parameter(resultType);
            Action<object> receive = result =>
            {
                if (!disposing) Assert.That((bool)Field(result, "ok"), Is.True, (string)Field(result, "code"));
            };
            Delegate callback = Expression.Lambda(typeof(Action<>).MakeGenericType(resultType),
                Expression.Invoke(Expression.Constant(receive), Expression.Convert(parameter, typeof(object))), parameter).Compile();
            presence = Activator.CreateInstance(Avatar("AvatarPresenceTransitionController"), callback);
        }

        // Exact authored Main Camera pose from Companion.unity, not a fabricated
        // geometry fault. This is the pose an old camera restoration can retain.
        public void RestoreSerializedScenePose() => Camera.transform.SetPositionAndRotation(
            new Vector3(-.00009858608f, .7536334f, 4.297187f), new Quaternion(0, 1, 0, 0));
        public void RestoreObservedDevicePose()
        {
            Camera.transform.SetPositionAndRotation(new Vector3(-.35000008f, 1.0447797f, 6.5465117f),
                new Quaternion(0, 1, 0, 0));
            Camera.fieldOfView = 37.5f;
        }
        public void HoldDoorwayCamera() => Call(Framing, "CompleteDoorwayCameraRoute", rig);
        public bool Inside => (bool)Call(navigation, "ContainsCamera", Camera.transform.position, .08f);
        public void Advance()
        {
            for (int frame = 0; frame < 360; frame++) Call(Framing, "AdvanceFraming", 1f / 60f);
        }
        public void Execute(string phase)
        {
            var json = new JObject { ["requestId"] = "camera-recovery-" + ++sequence,
                ["transitionId"] = "camera-recovery", ["phase"] = phase, ["edge"] = "right",
                ["durationMs"] = 1800, ["sequence"] = sequence, ["expiresAtMs"] = 10000,
                ["doNotInterrupt"] = true };
            object command = JsonUtility.FromJson(json.ToString(), Avatar("AvatarPresenceCommand"));
            Call(presence, "Execute", command, actor.transform, Framing, (Func<bool>)(() => true),
                (Action)(() => { }), 0f, 1000L);
        }
        public bool Record(string label)
        {
            Vector3 front = (Vector3)Field(Framing, "stableHomeFront");
            object[] args = { actor.transform, Property(Framing, "FramingMode"), rig, front, false,
                Activator.CreateInstance(Avatar("CameraPose")), 0f, new Bounds(), false };
            bool fits = (bool)Call(Framing, "TryGetInteriorOwnedFramingPose", args);
            Vector3 destination = (Vector3)Property(args[5], "Position");
            object[] routeArgs = { Camera.transform.position, destination, args[7], null };
            bool route = fits && (bool)Call(navigation, "TryBuildCameraRouteAroundSubject", routeArgs);
            var report = new JObject { ["label"] = label, ["camera"] = Camera.transform.position.ToString("F5"),
                ["rotation"] = Camera.transform.rotation.ToString("F5"), ["fov"] = Camera.fieldOfView,
                ["aspect"] = Camera.aspect, ["inside"] = Inside, ["active"] = Framing.isActiveAndEnabled,
                ["target"] = actor.transform.position.ToString("F5"), ["targetBound"] = Field(Framing, "targetRoot") != null,
                ["hasFramedPose"] = (bool)Field(Framing, "hasFramedPose"),
                ["autoFrame"] = (bool)Field(Framing, "autoFrameEnabled"), ["entryBound"] = (bool)Property(rig, "IsSceneEntryBound"),
                ["entrySafetyBound"] = Field(Framing, "entrySafetyRig") != null,
                ["interiorFits"] = fits, ["destination"] = destination.ToString("F5"), ["destinationFov"] = (float)args[6],
                ["destinationInside"] = (bool)Call(navigation, "ContainsCamera", destination, .08f), ["routeFound"] = route };
            Directory.CreateDirectory(Output);
            File.WriteAllText(Path.Combine(Output, label + ".json"), report.ToString());
            TestContext.WriteLine(report.ToString());
            return fits;
        }
        public void Capture(string label)
        {
            var target = new RenderTexture(393, 852, 24, RenderTextureFormat.ARGB32);
            var pixels = new Texture2D(393, 852, TextureFormat.RGBA32, false);
            RenderTexture previousTarget = Camera.targetTexture, previousActive = RenderTexture.active;
            try
            {
                target.Create(); Camera.targetTexture = target; Camera.Render(); RenderTexture.active = target;
                pixels.ReadPixels(new Rect(0, 0, 393, 852), 0, 0); pixels.Apply();
                Directory.CreateDirectory(Output);
                File.WriteAllBytes(Path.Combine(Output, label + ".png"), pixels.EncodeToPNG());
            }
            finally
            {
                Camera.targetTexture = previousTarget; RenderTexture.active = previousActive;
                Object.DestroyImmediate(pixels); target.Release(); Object.DestroyImmediate(target);
            }
        }
        public void Dispose()
        {
            disposing = true;
            if (presence != null) Call(presence, "CancelForReset", "test_complete");
            Object.DestroyImmediate(Camera.gameObject); Object.DestroyImmediate(actor); Object.DestroyImmediate(room);
        }
    }
}
