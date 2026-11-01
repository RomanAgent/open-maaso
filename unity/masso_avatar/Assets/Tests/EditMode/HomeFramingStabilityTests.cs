using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class HomeFramingStabilityTests
{
    private const BindingFlags Instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    private static object Call(object target, string name, params object[] args) => target.GetType()
        .GetMethods(Instance).Single(method => method.Name == name && method.GetParameters().Length == args.Length)
        .Invoke(target, args);
    private static T Field<T>(object target, string name) =>
        (T)target.GetType().GetField(name, Instance).GetValue(target);

    [TestCase("hero_full_body")]
    [TestCase("full")]
    [TestCase("front_full_body")]
    [TestCase("three_quarter")]
    public void PublishedHomeLensDoesNotFollowIdleBones(string mode)
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        GameObject actor = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        GameObject room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        var camera = new GameObject("Published standing Home camera") { tag = "MainCamera" }.AddComponent<Camera>();
        try
        {
            Animator animator = actor.GetComponentInChildren<Animator>();
            animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.Rebind(); animator.Play("idle_shrug", 0, .25f); animator.Update(0);
            camera.aspect = 393f / 852f; camera.fieldOfView = 37.5f; camera.nearClipPlane = .3f;
            camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = Color.white;
            Component framing = camera.gameObject.AddComponent(
                Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp", true));
            framing.GetType().GetProperty("TargetRoot").SetValue(framing, actor.transform);
            Component map = room.GetComponent(
                Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Call(map, "SetWorldActive", false);
            Assert.That(Call(map, "AlignHomeAvatar", actor.transform), Is.EqualTo(true));
            Call(framing, "SetFramingMode", mode);
            object rig = Field<object>(framing, "entrySafetyRig");
            Assert.That(rig, Is.Not.Null,
                "The published room must exercise the interior solver that runs before ordinary framing.");
            object[] QueryArgs() => new object[] { actor.transform, mode, rig,
                Field<Vector3>(framing, "stableHomeFront"), false,
                Activator.CreateInstance(Type.GetType("Maaso.Avatar.CameraPose, Assembly-CSharp", true)), 0f,
                default(Bounds), false };
            // Furniture deliberately keeps the pre-fix live Humanoid solver.
            // Compare the first standing projection with that same live input,
            // so freezing motion cannot change the initial shot's body scale.
            Call(framing, "SetFurniturePoseActive", true);
            object[] legacy = QueryArgs();
            Assert.That(Call(framing, "TryGetInteriorOwnedFramingPose", legacy), Is.EqualTo(true));
            Call(framing, "SetFurniturePoseActive", false);
            object[] firstStanding = QueryArgs();
            Assert.That(Call(framing, "TryGetInteriorOwnedFramingPose", firstStanding), Is.EqualTo(true));
            Vector3 Position(object pose) => (Vector3)pose.GetType().GetProperty("Position").GetValue(pose);
            Quaternion Rotation(object pose) => (Quaternion)pose.GetType().GetProperty("Rotation").GetValue(pose);
            Assert.That(Vector3.Distance(Position(firstStanding[5]), Position(legacy[5])), Is.LessThan(.00001f));
            Assert.That(Quaternion.Angle(Rotation(firstStanding[5]), Rotation(legacy[5])), Is.LessThan(.001f));
            Assert.That((float)firstStanding[6], Is.EqualTo((float)legacy[6]).Within(.00001f));
            Call(framing, "FrameNow");
            for (int frame = 0; frame < 360; frame++) Call(framing, "AdvanceFraming", 1f / 60f);
            Assert.That(Field<bool>(framing, "furniturePoseActive"), Is.False);
            float standingFov = camera.fieldOfView;
            Vector3 standingCameraPosition = camera.transform.position;
            Vector3 actorPosition = actor.transform.position;
            float initialAnimationTime = animator.GetCurrentAnimatorStateInfo(0).normalizedTime;
            Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
            Assert.That(head, Is.Not.Null);
            Vector3 headLocalPosition = head.localPosition;
            float maximumFovDelta = 0f, maximumPositionDelta = 0f;
            for (int frame = 0; frame < 30; frame++)
            {
                head.localPosition = headLocalPosition;
                animator.Update(1f / 30f);
                // The receiver layers conversational micro-motion after the
                // Animator. Exercise that final-pose boundary deterministically
                // while the authoritative actor root remains stationary.
                head.position += Vector3.up * (Mathf.Sin(frame * .4f) * .004f);
                Call(framing, "AdvanceFraming", 1f / 30f);
                maximumFovDelta = Mathf.Max(maximumFovDelta, Mathf.Abs(camera.fieldOfView - standingFov));
                maximumPositionDelta = Mathf.Max(maximumPositionDelta,
                    Vector3.Distance(camera.transform.position, standingCameraPosition));
            }
            TestContext.WriteLine($"Published Home {mode}, model=Joy: maximum idle FOV delta={maximumFovDelta:F7}, position delta={maximumPositionDelta:F7}");
            Assert.That(animator.GetCurrentAnimatorStateInfo(0).normalizedTime,
                Is.GreaterThan(initialAnimationTime + .01f), "The real idle animation must keep running.");
            Assert.That(actor.transform.position, Is.EqualTo(actorPosition));
            Assert.That(maximumFovDelta, Is.LessThan(.0001f),
                "Standing Home must not refit the room lens to each animated Humanoid pose.");
            Assert.That(maximumPositionDelta, Is.LessThan(.0001f),
                "Three-quarter framing must not move the camera when its standing body bounds breathe.");
        }
        finally
        {
            Object.DestroyImmediate(camera.gameObject);
            Object.DestroyImmediate(actor);
            Object.DestroyImmediate(room);
        }
    }

    [Test]
    public void HiddenSubjectProbesDoNotMakeTheStandingHomeLensFollowAnimation()
    {
        using var f = new Fixture();
        f.Frame();
        float standingFov = f.Camera.fieldOfView;
        Vector3 standingPosition = f.Camera.transform.position;
        Bounds standingBounds = Field<Bounds>(f.Framing, "cachedLocalBounds");
        Assert.That(standingFov, Is.GreaterThan(Fixture.AuthoredFov),
            "Use the constrained phone Home shot so changing body height would change its lens.");

        for (int frame = 0; frame < 30; frame++)
        {
            f.SetBodyHeight(2.7f + Mathf.Sin(frame * .3f) * .15f);
            Vector3 focus = (Vector3)f.Framing.GetType().GetProperty("DoorwaySubjectFocus").GetValue(f.Framing);
            Assert.That(Vector3.Distance(focus, f.Body.bounds.center), Is.LessThan(.0001f),
                "The hidden probe must still return the current body, rather than stale standing geometry.");
            f.Frame();
            Assert.That(f.Camera.fieldOfView, Is.EqualTo(standingFov).Within(.0001f),
                "A live doorway subject query must not replace the standing Home framing cache at frame " + frame);
            Assert.That(Vector3.Distance(f.Camera.transform.position, standingPosition), Is.LessThan(.0001f));
            Assert.That(Field<Bounds>(f.Framing, "cachedLocalBounds"), Is.EqualTo(standingBounds));
        }
    }

    [Test]
    public void HiddenPreparationCanInitializeTheFirstHomeBoundsWithoutMakingTheBodyVisible()
    {
        using var f = new Fixture();
        f.Body.enabled = false;
        Assert.That(Field<bool>(f.Framing, "hasCachedLocalBounds"), Is.False);
        Bounds prepared = f.Bounds(f.Root.transform, true);
        Assert.That(Field<bool>(f.Framing, "hasCachedLocalBounds"), Is.True,
            "The first hidden presentation still needs standing bounds for a later Home return query.");
        Assert.That(Field<Transform>(f.Framing, "cachedBoundsRoot"), Is.SameAs(f.Root.transform));
        Assert.That(f.Body.enabled, Is.False);

        f.Body.enabled = true;
        f.SetBodyHeight(2.9f);
        Bounds resumed = f.Bounds(f.Root.transform, false);
        Assert.That(resumed, Is.EqualTo(prepared), "Visibility recovery must retain the prepared Home composition.");
    }

    [Test]
    public void HiddenProbeForAnotherAvatarDoesNotEvictTheStandingHomeCache()
    {
        using var f = new Fixture();
        f.Frame();
        float standingFov = f.Camera.fieldOfView;
        Bounds standingBounds = Field<Bounds>(f.Framing, "cachedLocalBounds");
        GameObject other = f.CreateBody("Other preview avatar", 3.3f);
        try
        {
            Bounds preview = f.Bounds(other.transform, true);
            Assert.That(preview.size.y, Is.EqualTo(3.3f).Within(.0001f),
                "The other avatar's preview still needs its own live geometry.");
            Assert.That(Field<Transform>(f.Framing, "cachedBoundsRoot"), Is.SameAs(f.Root.transform));
            Assert.That(Field<Bounds>(f.Framing, "cachedLocalBounds"), Is.EqualTo(standingBounds));
            f.SetBodyHeight(2.9f);
            f.Frame();
            Assert.That(f.Camera.fieldOfView, Is.EqualTo(standingFov).Within(.0001f));
        }
        finally { Object.DestroyImmediate(other); }
    }

    [Test]
    public void FurnitureBoundsRemainLiveAndStandingRecoveryCanEstablishANewCache()
    {
        using var f = new Fixture();
        f.Frame();
        Call(f.Framing, "SetFurniturePoseActive", true);
        Assert.That(Field<bool>(f.Framing, "hasCachedLocalBounds"), Is.False);
        f.SetBodyHeight(1.3f);
        Bounds seated = f.Bounds(f.Root.transform, false);
        f.SetBodyHeight(1.5f);
        Bounds movingSeated = f.Bounds(f.Root.transform, false);
        Assert.That(movingSeated.size.y, Is.EqualTo(1.5f).Within(.0001f));
        Assert.That(movingSeated.size.y, Is.GreaterThan(seated.size.y + .1f),
            "Furniture framing must keep measuring the current pose.");

        Call(f.Framing, "SetFurniturePoseActive", false);
        Assert.That(Field<bool>(f.Framing, "hasCachedLocalBounds"), Is.False);
        f.SetBodyHeight(2.6f);
        f.Frame();
        Bounds recovered = Field<Bounds>(f.Framing, "cachedLocalBounds");
        Assert.That(recovered.size.y, Is.EqualTo(2.6f).Within(.0001f));
        f.SetBodyHeight(2.9f);
        f.Bounds(f.Root.transform, true);
        Assert.That(Field<Bounds>(f.Framing, "cachedLocalBounds"), Is.EqualTo(recovered));
    }

    [Test]
    public void AuthoritativeTargetReplacementInvalidatesAndRebuildsStandingBounds()
    {
        using var f = new Fixture();
        f.Frame();
        float firstFov = f.Camera.fieldOfView;
        GameObject replacement = f.CreateBody("Replacement avatar", 3.2f);
        try
        {
            f.Framing.GetType().GetProperty("TargetRoot").SetValue(f.Framing, replacement.transform);
            Assert.That(Field<bool>(f.Framing, "hasCachedLocalBounds"), Is.False);
            f.Frame();
            Assert.That(Field<Transform>(f.Framing, "cachedBoundsRoot"), Is.SameAs(replacement.transform));
            Assert.That(Field<Bounds>(f.Framing, "cachedLocalBounds").size.y,
                Is.EqualTo(3.2f).Within(.0001f));
            Assert.That(f.Camera.fieldOfView, Is.GreaterThan(firstFov + .1f),
                "A different model must get a new composition rather than inherit the previous actor's cache.");
        }
        finally { Object.DestroyImmediate(replacement); }
    }

    private sealed class Fixture : IDisposable
    {
        public const float AuthoredFov = 35f;
        public readonly GameObject Root;
        public readonly Renderer Body;
        public readonly Camera Camera;
        public readonly Component Framing;
        private readonly Component map;

        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = CreateBody("Standing Home avatar", 2.4f);
            Body = Root.GetComponentInChildren<Renderer>();
            Camera = new GameObject("Stable Home camera") { tag = "MainCamera" }.AddComponent<Camera>();
            Camera.aspect = 390f / 844f;
            Camera.fieldOfView = AuthoredFov;
            Camera.clearFlags = CameraClearFlags.SolidColor;
            Camera.backgroundColor = Color.gray;
            Type framingType = Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp", true);
            Framing = Camera.gameObject.AddComponent(framingType);
            Type mapType = Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true);
            map = (Component)mapType.GetMethod("BuildDefaultMap").Invoke(null,
                new object[] { new GameObject("Stable Home map") });
            Transform environment = (Transform)mapType.GetProperty("PersistentEnvironmentRoot").GetValue(map);
            GameObject wall = GameObject.CreatePrimitive(PrimitiveType.Cube);
            wall.transform.SetParent(environment, false);
            wall.transform.localPosition = new Vector3(3.9f, 1.2f, 0f);
            framingType.GetProperty("TargetRoot").SetValue(Framing, Root.transform);
            Call(Framing, "SetHomeViewReference", mapType.GetProperty("HomeCameraReference").GetValue(map));
        }

        public GameObject CreateBody(string name, float height)
        {
            var root = new GameObject(name);
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            body.transform.SetParent(root.transform, false);
            body.transform.localPosition = Vector3.up * (height * .5f);
            body.transform.localScale = new Vector3(1.8f, height, .5f);
            return root;
        }

        public void SetBodyHeight(float height)
        {
            Body.transform.localPosition = Vector3.up * (height * .5f);
            Body.transform.localScale = new Vector3(1.8f, height, .5f);
        }

        public Bounds Bounds(Transform root, bool includeHidden)
        {
            object[] args = { root, new List<Renderer>(), default(Bounds), includeHidden };
            Assert.That(Call(Framing, "TryGetTargetBounds", args), Is.EqualTo(true));
            return (Bounds)args[2];
        }

        public void Frame() => Call(Framing, "FrameNow");

        public void Dispose()
        {
            Object.DestroyImmediate(Camera.gameObject);
            Object.DestroyImmediate(Root);
            Object.DestroyImmediate(map.gameObject);
        }
    }
}
