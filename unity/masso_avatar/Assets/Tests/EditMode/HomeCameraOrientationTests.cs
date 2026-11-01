using System;
using System.IO;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

public sealed class HomeCameraOrientationTests
{
    private static Type AvatarType(string name) =>
        Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static Type WorldType(string name) =>
        Type.GetType("Maaso.World." + name + ", Assembly-CSharp", true);
    private static object Call(object target, string name, params object[] args) =>
        target.GetType().GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Single(method => method.Name == name && method.GetParameters().Length == args.Length)
            .Invoke(target, args);
    private static void Set(object target, string name, object value) =>
        target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(target, value);
    private static void Command(Component receiver, string method, string payload) =>
        Call(receiver, "OnFlutterCommand", "{\"method\":\"" + method + "\",\"json\":\"" +
            payload.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"}");

    private static void AdvanceToTurnHold(Component receiver)
    {
        Set(receiver, "bodyPoseTransitionStartedAt", Time.realtimeSinceStartup - 0.5f);
        Call(receiver, "UpdateBodyPoseTransition");
    }

    [TestCase("turn_back")]
    [TestCase("look_back")]
    public void ReceiverTurnMotionKeepsHomeBackgroundAndResetKeepsSameHeading(string motion)
    {
        using var f = new Fixture();
        Quaternion home = f.Camera.transform.rotation;
        Vector3 initialAvatarForward = f.Root.transform.forward;
        Command(f.Receiver, "playMotion", "{\"type\":\"" + motion + "\"}");
        AdvanceToTurnHold(f.Receiver);
        Call(f.Framing, "AdvanceFraming", 1f);
        float turnedAngle = Quaternion.Angle(home, f.Camera.transform.rotation);
        Assert.That(Vector3.Dot(initialAvatarForward, f.Root.transform.forward), Is.LessThan(-0.99f),
            "The real receiver must execute the turn; suppressing the action is not a camera fix.");
        Command(f.Receiver, "playMotion", "{\"type\":\"reset\"}");
        Call(f.Framing, "AdvanceFraming", 1f);
        float resetAngle = Quaternion.Angle(home, f.Camera.transform.rotation);
        Debug.Log($"[HomeCameraOrientation] motion={motion} turnCameraAngle={turnedAngle:F3} resetCameraAngle={resetAngle:F3}");
        Assert.That(turnedAngle, Is.LessThan(0.01f));
        Assert.That(resetAngle, Is.LessThan(0.01f));
    }

    [Test]
    public void NoMapFallbackKeepsFirstViewAcrossModelReplacement()
    {
        using var f = new Fixture();
        Quaternion initial = f.Camera.transform.rotation;
        GameObject replacement = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        try
        {
            replacement.transform.rotation = Quaternion.Euler(0f, 180f, 0f);
            f.SetTarget(replacement.transform);
            f.Framing.enabled = false;
            f.Framing.enabled = true;
            Call(f.Framing, "AdvanceFraming", 1f);
            AssertHeading(f.Camera, initial);
        }
        finally { Object.DestroyImmediate(replacement); }
    }

    [Test]
    public void ExplicitSceneReferenceSurvivesShotsRootRebindingAndDisableEnable()
    {
        using var f = new Fixture();
        f.Reference.rotation = Quaternion.Euler(7f, 214f, 3f);
        Call(f.Framing, "SetHomeViewReference", f.Reference);
        Call(f.Framing, "FrameNow");
        AssertHeading(f.Camera, f.Reference.rotation);
        foreach (string mode in new[] { "head", "upper_body", "hero_full_body" })
        {
            f.Root.transform.rotation = Quaternion.Euler(0f, 180f, 0f);
            Call(f.Framing, "SetFramingModeCore", mode, true);
            Call(f.Framing, "AdvanceFraming", 0.3f);
            AssertHeading(f.Camera, f.Reference.rotation);
            Call(f.Framing, "AdvanceFraming", 0.3f);
            AssertHeading(f.Camera, f.Reference.rotation);
        }
        f.Framing.enabled = false;
        Command(f.Receiver, "playMotion", "{\"type\":\"reset\"}");
        f.Framing.enabled = true;
        AssertHeading(f.Camera, f.Reference.rotation);
        GameObject replacement = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        try
        {
            replacement.transform.SetPositionAndRotation(Vector3.right * 2f, Quaternion.Euler(0f, 95f, 0f));
            f.SetTarget(replacement.transform);
            Call(f.Framing, "AdvanceFraming", 1f);
            AssertHeading(f.Camera, f.Reference.rotation);
            f.SetTarget(f.Root.transform);
            Call(f.Framing, "FrameNow");
            AssertHeading(f.Camera, f.Reference.rotation);
        }
        finally { Object.DestroyImmediate(replacement); }
    }

    [Test]
    public void ManualAndLiveFramingDoNotReplaceHomeReference()
    {
        using var f = new Fixture();
        Call(f.Framing, "SetHomeViewReference", f.Reference);
        Vector3 initial = f.Camera.transform.position;
        Quaternion home = f.Camera.transform.rotation;
        Command(f.Receiver, "setFraming", "{\"mode\":\"manual_avatar_motion\"}");
        Command(f.Receiver, "playMotion", "{\"type\":\"turn_back\"}");
        AdvanceToTurnHold(f.Receiver);
        f.Root.transform.position += Vector3.right;
        Call(f.Framing, "AdvanceFraming", 1f);
        Assert.That(f.Camera.transform.position, Is.EqualTo(initial));
        Command(f.Receiver, "setFraming", "{\"mode\":\"upper_body\"}");
        Call(f.Framing, "AdvanceFraming", 1f);
        AssertHeading(f.Camera, home);
        Assert.That(f.Camera.transform.position.x, Is.GreaterThan(0.5f));
        Command(f.Receiver, "setFraming", "{\"mode\":\"hero_full_body\"}");
        Call(f.Framing, "AdvanceFraming", 1f);
        AssertHeading(f.Camera, home);
    }

    [Test]
    public void NewSceneReferenceChangesHeadingWhileReferenceRemovalKeepsLastValidView()
    {
        using var f = new Fixture();
        Call(f.Framing, "SetHomeViewReference", f.Reference);
        f.Reference.rotation = Quaternion.Euler(0f, 225f, 0f);
        Call(f.Framing, "AdvanceFraming", 1f);
        Quaternion expected = f.Reference.rotation;
        AssertHeading(f.Camera, expected);
        Call(f.Framing, "SetHomeViewReference", (object)null);
        f.Root.transform.rotation = Quaternion.Euler(0f, 180f, 0f);
        Call(f.Framing, "AdvanceFraming", 1f);
        AssertHeading(f.Camera, expected);
        f.Reference.rotation = Quaternion.Euler(0f, 135f, 0f);
        Call(f.Framing, "SetHomeViewReference", f.Reference);
        Call(f.Framing, "FrameNow");
        AssertHeading(f.Camera, f.Reference.rotation);
        Object.DestroyImmediate(f.Reference.gameObject);
        Call(f.Framing, "AdvanceFraming", 1f);
        AssertHeading(f.Camera, Quaternion.Euler(0f, 135f, 0f));
    }

    [Test]
    public void WorldExitAndSubsequentHomeFrameKeepSceneHeading()
    {
        using var f = new Fixture();
        Call(f.Framing, "SetHomeViewReference", f.Reference);
        Quaternion home = f.Camera.transform.rotation;
        Component director = f.Camera.gameObject.AddComponent(WorldType("WorldCameraDirector"));
        var owner = new GameObject("WorldOwner");
        try
        {
            owner.transform.position = new Vector3(5f, 0f, -3f);
            Assert.That(Call(director, "EnterWorld", f.Camera, f.Framing, owner.transform, null), Is.True);
            Call(director, "UpdateTransition", Time.realtimeSinceStartup + 5f);
            Command(f.Receiver, "playMotion", "{\"type\":\"turn_back\"}");
            AdvanceToTurnHold(f.Receiver);
            Call(director, "BeginExit", (Action)(() => f.Root.transform.position = Vector3.zero));
            Call(director, "UpdateTransition", Time.realtimeSinceStartup + 5f);
            Assert.That(f.Framing.enabled, Is.True);
            Call(f.Framing, "AdvanceFraming", 1f);
            AssertHeading(f.Camera, home);
        }
        finally { Object.DestroyImmediate(owner); }
    }

    [Test]
    public void RealHomeTurnKeepsWindowBackgroundInRenderedPortrait()
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
            Assert.Ignore("The room background regression requires a graphics device.");
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        Component receiver = Object.FindObjectsByType<MonoBehaviour>(FindObjectsInactive.Exclude)
            .First(item => item.GetType() == AvatarType("UnityAvatarCommandReceiver"));
        Call(receiver, "EnsureAvatar");
        Call(receiver, "TryStartDesignedIdle");
        Transform avatar = (Transform)receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(receiver);
        Animator animator = avatar.GetComponentInChildren<Animator>();
        animator.Rebind();
        string stateName = (string)receiver.GetType().GetField("designedIdleStateName",
            BindingFlags.NonPublic | BindingFlags.Instance).GetValue(receiver);
        int state = Animator.StringToHash(string.IsNullOrWhiteSpace(stateName) ? "idle" : stateName);
        for (int layer = 0; layer < animator.layerCount; layer++)
            if (animator.HasState(layer, state)) animator.Play(state, layer, 0.5f);
        animator.Update(1f / 60f);
        Camera camera = Camera.main;
        Component framing = camera.GetComponent(AvatarType("FrontFullBodyCamera"));
        framing.GetType().GetProperty("TargetRoot").SetValue(framing, avatar);
        GameObject room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        try
        {
            Component map = room.GetComponent(WorldType("PersistentWorldMapController"));
            Call(map, "SetWorldActive", false);
            Call(map, "AlignHomeAvatar", avatar);
            camera.aspect = 393f / 852f;
            Call(framing, "SetViewportSafeArea", 0.15f, 0.2f);
            Call(framing, "FrameNow");
            Quaternion initial = camera.transform.rotation;
            Vector3 initialAvatarForward = avatar.forward;
            Capture(camera, "before");
            Command(receiver, "playMotion", "{\"type\":\"turn_back\"}");
            AdvanceToTurnHold(receiver);
            Call(framing, "AdvanceFraming", 1f);
            float turnAngle = Quaternion.Angle(initial, camera.transform.rotation);
            Assert.That(Vector3.Dot(initialAvatarForward, avatar.forward), Is.LessThan(-0.99f));
            Capture(camera, turnAngle < 0.01f ? "fixed-turn-back" : "reproduced-turn-back");
            Set(receiver, "actionPoseHoldUntil", -1f);
            Call(receiver, "UpdateIdlePose");
            AdvanceToTurnHold(receiver);
            Call(framing, "AdvanceFraming", 1f);
            Capture(camera, "automatic-return");
            Debug.Log($"[HomeCameraOrientation] realRoom turnCameraAngle={turnAngle:F3}");
            Assert.That(turnAngle, Is.LessThan(0.01f));
            Assert.That(Vector3.Dot(initialAvatarForward, avatar.forward), Is.GreaterThan(0.99f),
                "The temporary conversational turn must return to facing the user.");
            AssertHeading(camera, initial);
        }
        finally
        {
            Object.DestroyImmediate(room);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    private static void AssertHeading(Camera camera, Quaternion expected) =>
        Assert.That(Quaternion.Angle(camera.transform.rotation, expected), Is.LessThan(0.01f));

    private static void Capture(Camera camera, string label)
    {
        RenderTexture previousTarget = camera.targetTexture;
        RenderTexture previousActive = RenderTexture.active;
        var target = new RenderTexture(393, 852, 24, RenderTextureFormat.ARGB32);
        var image = new Texture2D(393, 852, TextureFormat.RGBA32, false);
        try
        {
            camera.targetTexture = target;
            camera.Render();
            RenderTexture.active = target;
            image.ReadPixels(new Rect(0, 0, 393, 852), 0, 0);
            image.Apply();
            File.WriteAllBytes(Path.Combine(Path.GetTempPath(), "maaso-home-orientation-" + label + ".png"), image.EncodeToPNG());
        }
        finally
        {
            camera.targetTexture = previousTarget;
            RenderTexture.active = previousActive;
            Object.DestroyImmediate(target);
            Object.DestroyImmediate(image);
        }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Root;
        public readonly Component Receiver;
        public readonly Camera Camera;
        public readonly Behaviour Framing;
        public readonly Transform Reference;
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = new GameObject("HomeAvatar");
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            body.transform.SetParent(Root.transform, false);
            body.transform.localPosition = Vector3.up;
            Receiver = Root.AddComponent(AvatarType("UnityAvatarCommandReceiver"));
            Set(Receiver, "avatarRoot", Root.transform);
            Call(Receiver, "EnsureAvatar");
            var cameraHost = new GameObject("Main Camera");
            cameraHost.tag = "MainCamera";
            Camera = cameraHost.AddComponent<Camera>();
            Camera.aspect = 393f / 852f;
            Camera.fieldOfView = 37.5f;
            Framing = (Behaviour)cameraHost.AddComponent(AvatarType("FrontFullBodyCamera"));
            SetTarget(Root.transform);
            Call(Framing, "FrameNow");
            Reference = new GameObject("HomeCameraReference").transform;
            Reference.rotation = Quaternion.Euler(0f, 180f, 0f);
        }
        public void SetTarget(Transform target) =>
            Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, target);
        public void Dispose()
        {
            if (Reference != null) Object.DestroyImmediate(Reference.gameObject);
            Object.DestroyImmediate(Camera.gameObject);
            Object.DestroyImmediate(Root);
        }
    }
}
