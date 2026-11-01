using System;
using System.IO;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

public sealed class ImmersiveAvatarFramingTests
{
    private static Type AvatarType(string name) =>
        Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);

    private static object Call(object target, string name, params object[] arguments) =>
        target.GetType().GetMethods(BindingFlags.Public | BindingFlags.NonPublic |
            BindingFlags.Instance).Single(method => method.Name == name &&
                method.GetParameters().Length == arguments.Length).Invoke(target, arguments);

    private static T Property<T>(object target, string name) =>
        (T)target.GetType().GetProperty(name).GetValue(target);

    [TestCase(0.65f)]
    [TestCase(1f)]
    [TestCase(1.5f)]
    public void HeadFallbackGetsCloserThanBroadUpperBodyWithoutHumanoidBones(float scale)
    {
        using var fixture = new Fixture(scale);
        Vector3 full = fixture.Camera.transform.position;
        Call(fixture.Framing, "SetFramingMode", "upper_body");
        Vector3 upper = fixture.Camera.transform.position;
        Assert.That(upper.z, Is.LessThan(full.z * 0.8f));
        Call(fixture.Framing, "SetFramingMode", "head");
        Vector3 head = fixture.Camera.transform.position;
        Assert.That(head.z, Is.LessThan(upper.z * 0.7f));
        Assert.That(head.z, Is.LessThan(full.z * 0.45f));
        Assert.That(head.y, Is.GreaterThan(full.y));
        Vector3 top = fixture.Camera.WorldToViewportPoint(new Vector3(0f, 1.8f * scale, 0f));
        Assert.That(top.y, Is.InRange(0.7f, 0.85f));
        Assert.That(top.z, Is.GreaterThan(fixture.Camera.nearClipPlane));
    }

    [TestCase(0.75f, 0.5625f)]
    [TestCase(1.4f, 1.777778f)]
    public void HeadShotUsesRealHumanoidHeadAtDifferentScalesAndAspects(float scale, float aspect)
    {
        using var fixture = new Fixture();
        fixture.Body.SetActive(false);
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
            "Assets/MaasoAvatar/Models/Default/Joy.vrm");
        Assert.That(prefab, Is.Not.Null);
        GameObject model = Object.Instantiate(prefab, fixture.Root.transform, false);
        model.transform.localScale = Vector3.one * scale;
        Animator animator = model.GetComponentInChildren<Animator>();
        Assert.That(animator.avatar.isHuman, Is.True);
        Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
        Assert.That(head, Is.Not.Null);
        fixture.Camera.aspect = aspect;
        fixture.SetTarget(fixture.Root.transform);
        Call(fixture.Framing, "FrameNow");
        Vector3 full = fixture.Camera.transform.position;
        Call(fixture.Framing, "SetFramingMode", "head");
        Vector3 headViewport = fixture.Camera.WorldToViewportPoint(head.position);
        Assert.That(headViewport.x, Is.InRange(0.45f, 0.55f));
        Assert.That(headViewport.y, Is.InRange(0.35f, 0.8f));
        Assert.That(fixture.Camera.transform.position.z, Is.LessThan(full.z * 0.65f));

        // A head lean must remain centered even though the full-body bounds
        // intentionally stay cached to avoid breathing/padding jitter.
        head.position += Vector3.right * 0.15f * scale;
        Call(fixture.Framing, "AdvanceFraming", 1f / 60f);
        headViewport = fixture.Camera.WorldToViewportPoint(head.position);
        Assert.That(headViewport.x, Is.EqualTo(0.5f).Within(0.005f));
    }

    [Test]
    public void RuntimeTransitionIsContinuousInterruptibleAndDuplicateModesDoNotRestart()
    {
        using var fixture = new Fixture();
        Vector3 full = fixture.Camera.transform.position;
        Vector3 head = fixture.Snap("head");
        Vector3 upper = fixture.Snap("upper_body");
        fixture.Snap("hero_full_body");
        fixture.Request("head");
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(full));
        Call(fixture.Framing, "AdvanceFraming", 0.3f);
        Assert.That(Vector3.Distance(fixture.Camera.transform.position,
            Vector3.Lerp(full, head, 0.5f)), Is.LessThan(0.001f));
        fixture.Request("head");
        Call(fixture.Framing, "AdvanceFraming", 0.3f);
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(head));
        Assert.That(Property<bool>(fixture.Framing, "IsFramingTransitionActive"), Is.False);

        fixture.Request("hero_full_body");
        Call(fixture.Framing, "AdvanceFraming", 0.2f);
        Vector3 interrupted = fixture.Camera.transform.position;
        fixture.Request("upper_body");
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(interrupted));
        Call(fixture.Framing, "AdvanceFraming", 0.6f);
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(upper));
    }

    [Test]
    public void SafeAreaAndPausedGameClockDoNotSnapOrStopAnActiveTransition()
    {
        using var fixture = new Fixture();
        float previousScale = Time.timeScale;
        try
        {
            fixture.Request("head");
            Call(fixture.Framing, "AdvanceFraming", 0.2f);
            Vector3 middle = fixture.Camera.transform.position;
            Call(fixture.Framing, "AdvanceFraming", float.NaN);
            Assert.That(fixture.Camera.transform.position, Is.EqualTo(middle));
            Call(fixture.Framing, "SetViewportSafeArea", 0.1f, 0.1f);
            Assert.That(fixture.Camera.transform.position, Is.EqualTo(middle));
            Time.timeScale = 0f;
            Call(fixture.Framing, "AdvanceFraming", 0.4f);
            Assert.That(Property<bool>(fixture.Framing, "IsFramingTransitionActive"), Is.False);
            Vector3 completed = fixture.Camera.transform.position;
            Call(fixture.Framing, "FrameNow");
            Assert.That(fixture.Camera.transform.position, Is.EqualTo(completed));
        }
        finally { Time.timeScale = previousScale; }
    }

    [Test]
    public void DisabledWorldAndManualMotionKeepOwnershipAndTargetReplacementDropsOldTransition()
    {
        using var fixture = new Fixture();
        fixture.Request("head");
        Call(fixture.Framing, "AdvanceFraming", 0.2f);
        fixture.Framing.enabled = false;
        Vector3 fixedPose = fixture.Camera.transform.position;
        fixture.Request("upper_body");
        Call(fixture.Framing, "SetViewportSafeArea", 0.1f, 0.1f);
        Call(fixture.Framing, "AdvanceFraming", 5f);
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(fixedPose));
        Assert.That(Property<bool>(fixture.Framing, "IsFramingTransitionActive"), Is.False);
        fixture.Framing.enabled = true;
        fixture.Request("manual_avatar_motion");
        fixedPose = fixture.Camera.transform.position;
        fixture.Root.transform.position += Vector3.right;
        Call(fixture.Framing, "AdvanceFraming", 5f);
        Assert.That(fixture.Camera.transform.position, Is.EqualTo(fixedPose));
        fixture.Request("hero_full_body");
        Call(fixture.Framing, "AdvanceFraming", 0.2f);
        GameObject replacement = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        try
        {
            replacement.transform.position = Vector3.right * 4f;
            fixture.SetTarget(replacement.transform);
            Assert.That(Property<bool>(fixture.Framing, "IsFramingTransitionActive"), Is.False);
            Call(fixture.Framing, "AdvanceFraming", 0f);
            Assert.That(fixture.Camera.transform.position.x, Is.EqualTo(4f).Within(0.001f));
        }
        finally { Object.DestroyImmediate(replacement); }
    }

    [Test]
    public void RealCompanionRendersAllThreePortraitShotsWithHeadAndEyesInsideSafeArea()
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
            Assert.Ignore("Portrait render evidence requires a graphics device.");
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        Type receiverType = AvatarType("UnityAvatarCommandReceiver");
        Component receiver = Object.FindObjectsByType<MonoBehaviour>(FindObjectsInactive.Exclude)
            .First(value => value.GetType() == receiverType);
        Call(receiver, "EnsureAvatar");
        Call(receiver, "TryStartDesignedIdle");
        Transform avatar = Property<Transform>(receiver, "ActiveAvatarRoot");
        Animator animator = avatar.GetComponentInChildren<Animator>();
        animator.Rebind();
        string stateName = (string)receiverType.GetField("designedIdleStateName",
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
            Component map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Call(map, "SetWorldActive", false);
            Call(map, "AlignHomeAvatar", avatar);
            camera.aspect = 393f / 852f;
            Call(framing, "SetViewportSafeArea", 0.15f, 0.2f);
            float upperBodyEyeSeparation = 0f;
            foreach (string mode in new[] { "hero_full_body", "upper_body", "head" })
            {
                Call(framing, "SetFramingMode", mode);
                Call(framing, "FrameNow");
                Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
                Vector3 viewport = camera.WorldToViewportPoint(head.position);
                Assert.That(viewport.x, Is.InRange(0.15f, 0.85f), mode);
                Assert.That(viewport.y, Is.InRange(0.2f, 0.85f), mode);
                foreach (HumanBodyBones bone in new[] { HumanBodyBones.LeftEye, HumanBodyBones.RightEye })
                {
                    Transform eye = animator.GetBoneTransform(bone);
                    if (eye == null) continue;
                    Vector3 eyeViewport = camera.WorldToViewportPoint(eye.position);
                    Assert.That(eyeViewport.x, Is.InRange(0.1f, 0.9f), mode + " " + bone);
                    Assert.That(eyeViewport.y, Is.InRange(0.2f, 0.85f), mode + " " + bone);
                }
                Transform neck = animator.GetBoneTransform(HumanBodyBones.Neck);
                Transform hips = animator.GetBoneTransform(HumanBodyBones.Hips);
                Vector3 neckViewport = camera.WorldToViewportPoint(neck.position);
                Vector3 hipsViewport = camera.WorldToViewportPoint(hips.position);
                if (mode == "head")
                {
                    Assert.That(neckViewport.y, Is.InRange(0.2f, 0.4f),
                        "A face request must fill the portrait, not leave a distant bust shot.");
                    Assert.That(hipsViewport.y, Is.LessThan(0f));
                }
                if (mode == "upper_body")
                {
                    Assert.That(neckViewport.y, Is.InRange(0.48f, 0.68f));
                    Assert.That(hipsViewport.y, Is.LessThan(0.2f),
                        "A speaking shot should end around the waist, not reveal the thighs.");
                }
                Transform leftEye = animator.GetBoneTransform(HumanBodyBones.LeftEye);
                Transform rightEye = animator.GetBoneTransform(HumanBodyBones.RightEye);
                if (leftEye != null && rightEye != null)
                {
                    float eyeSeparation = Mathf.Abs(camera.WorldToViewportPoint(leftEye.position).x -
                        camera.WorldToViewportPoint(rightEye.position).x);
                    if (mode == "upper_body") upperBodyEyeSeparation = eyeSeparation;
                    if (mode == "head") Assert.That(eyeSeparation,
                        Is.GreaterThan(upperBodyEyeSeparation * 1.6f),
                        "The face must be visibly larger than in the speaking shot.");
                }
                Capture(camera, mode);
            }
        }
        finally
        {
            Object.DestroyImmediate(room);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    private static void Capture(Camera camera, string mode)
    {
        RenderTexture previousTarget = camera.targetTexture;
        RenderTexture previousActive = RenderTexture.active;
        var texture = new RenderTexture(393, 852, 24, RenderTextureFormat.ARGB32);
        var image = new Texture2D(393, 852, TextureFormat.RGBA32, false);
        try
        {
            camera.targetTexture = texture;
            camera.Render();
            RenderTexture.active = texture;
            image.ReadPixels(new Rect(0, 0, 393, 852), 0, 0);
            image.Apply();
            File.WriteAllBytes(Path.Combine(Path.GetTempPath(), "maaso-immersive-" + mode + ".png"), image.EncodeToPNG());
        }
        finally
        {
            camera.targetTexture = previousTarget;
            RenderTexture.active = previousActive;
            Object.DestroyImmediate(texture);
            Object.DestroyImmediate(image);
        }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Root;
        public readonly GameObject Body;
        public readonly Camera Camera;
        public readonly Behaviour Framing;

        public Fixture(float scale = 1f)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = new GameObject("FramingAvatar");
            Root.transform.localScale = Vector3.one * scale;
            Body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            Body.transform.SetParent(Root.transform, false);
            Body.transform.localPosition = Vector3.up * 0.9f;
            Body.transform.localScale = new Vector3(1.6f, 1.8f, 0.35f);
            var cameraObject = new GameObject("Main Camera");
            cameraObject.tag = "MainCamera";
            Camera = cameraObject.AddComponent<Camera>();
            Camera.fieldOfView = 37.5f;
            Camera.aspect = 0.5625f;
            Camera.nearClipPlane = 0.01f;
            Framing = (Behaviour)cameraObject.AddComponent(AvatarType("FrontFullBodyCamera"));
            SetTarget(Root.transform);
            Call(Framing, "FrameNow");
        }

        public void SetTarget(Transform target) => Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, target);
        public void Request(string mode) => Call(Framing, "SetFramingModeCore", mode, true);
        public Vector3 Snap(string mode)
        {
            Call(Framing, "SetFramingMode", mode);
            Call(Framing, "FrameNow");
            return Camera.transform.position;
        }
        public void Dispose()
        {
            Object.DestroyImmediate(Camera.gameObject);
            Object.DestroyImmediate(Root);
        }
    }
}
