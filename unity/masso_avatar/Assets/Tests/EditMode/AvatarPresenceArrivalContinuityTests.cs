using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class AvatarPresenceArrivalContinuityTests
{
    [TestCase(1800)]
    [TestCase(300)]
    public void RealAvatarSettlesItsWalkDuringTheReturnTurnAndPreservesTheCamera(int durationMs)
    {
        using var f = new RealArrival();
        f.CaptureEvidence = true;
        f.Start(durationMs);
        float duration = durationMs / 1000f;
        float arrival = duration * .85f;
        float walkingSpeed = f.Animator.GetFloat("WorldWalkSpeed");
        Assert.That(Mathf.Abs(walkingSpeed - 1f), Is.GreaterThan(.05f),
            "This real projection must require calibrated gait, so premature speed reset is observable.");
        float elapsed = 0f;
        while (elapsed + 1f / 60f < arrival)
        {
            elapsed += 1f / 60f;
            f.Advance(elapsed, 1f / 60f);
        }
        f.Advance(arrival, arrival - elapsed);
        elapsed = arrival;
        f.Advance(arrival + .01f, .01f);
        elapsed += .01f;
        Assert.That(f.UpcomingState.IsName("standard_walk"), Is.False,
            "The real Animator must already be blending to idle when the root begins facing the camera.");
        Assert.That(f.Animator.IsInTransition(0), Is.True, "Stopping must blend from the sampled walk pose.");
        Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(walkingSpeed).Within(.0001f),
            "The outgoing walk must keep its calibrated speed until its idle blend finishes.");
        f.AssertCameraUnchanged("start of return turn");
        while (elapsed < Mathf.Max(duration, arrival + .25f))
        {
            float step = Mathf.Min(1f / 60f, Mathf.Max(duration, arrival + .25f) - elapsed);
            elapsed += step;
            f.Advance(elapsed, step);
            f.AssertCameraUnchanged("arrival frame " + elapsed);
        }
        Assert.That(f.Animator.IsInTransition(0), Is.False, "The arrival must finish with a settled idle pose.");
        Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f).Within(.0001f));
        Assert.That(Vector3.Distance(f.Root.position, f.HomePosition), Is.LessThan(.0001f));
        Assert.That(Quaternion.Angle(f.Root.rotation, f.HomeRotation), Is.LessThan(.01f));
        f.AssertSettledFeet();
        f.WriteEvidence("arrival-" + durationMs);
    }

    [Test]
    public void RealAvatarStartsAFreshPresenceStrideInsteadOfReusingAnOutgoingWalkingPhase()
    {
        using var f = new RealArrival();
        f.Animator.Play("standard_walk", 0, .73f);
        f.Animator.Update(0f);
        f.Start(1800);
        f.Animator.Update(.001f);
        Assert.That(f.UpcomingState.IsName("standard_walk"), Is.True);
        Assert.That(f.UpcomingState.normalizedTime, Is.LessThan(.05f),
            "A new entrance must have its own phase-zero stride rather than retaining the previous walk.");
    }

    [Test]
    public void AShortArrivalCannotResetTheSpeedOfANewerWorldWalkAfterReleasingPresentation()
    {
        using var f = new RealArrival();
        f.Start(300);
        f.Advance(.255f, .255f);
        f.Advance(.301f, .046f);
        Assert.That(f.OwnsPresentation, Is.False);
        Call(f.Receiver, "SetWorldLocomotion", true);
        Type world = Type.GetType("Maaso.World.WorldLocomotionPresentation, Assembly-CSharp", true);
        world.GetMethod("ApplyWalkingAnimationSpeed").Invoke(null, new object[] { f.Animator, true, 2.7f });
        float speed = f.Animator.GetFloat("WorldWalkSpeed");
        f.Advance(.6f, .299f);
        Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(speed).Within(.0001f),
            "A retired arrival's delayed cleanup cannot overwrite the next movement's gait.");
        Assert.That(f.UpcomingState.IsName("standard_walk"), Is.True);
    }

    [TestCase("model_replaced")]
    [TestCase("renderer_disabled")]
    [TestCase("renderer_destroyed")]
    [TestCase("scene_takeover")]
    public void RetiringARealArrivalResetsItsGaitImmediatelyAndCannotWriteTheNextWalk(string reason)
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(.6f, .6f);
        Call(f.ControllerInstance, "CancelForReset", reason);
        Assert.That(f.OwnsPresentation, Is.False);
        Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f).Within(.0001f));
        Call(f.Receiver, "SetWorldLocomotion", true);
        Type world = Type.GetType("Maaso.World.WorldLocomotionPresentation, Assembly-CSharp", true);
        world.GetMethod("ApplyWalkingAnimationSpeed").Invoke(null, new object[] { f.Animator, true, 2.7f });
        float nextSpeed = f.Animator.GetFloat("WorldWalkSpeed");
        f.Advance(.9f, .3f);
        Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(nextSpeed).Within(.0001f));
    }

    [TestCase("prepare")]
    [TestCase("holdHidden")]
    public void HiddenRealPreparationResetsTheGaitWithoutLeavingALaterCleanup(string phase)
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(.6f, .6f);
        f.PrepareHidden(phase);
        Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f).Within(.0001f));
        Assert.That(f.Root.GetComponentsInChildren<Renderer>(true).All(renderer => renderer.forceRenderingOff), Is.True);
    }

    [Test]
    public void AnActualSceneTakeoverResetsTheRealArrivalBeforeTheNextSceneOwnsTheGait()
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(.6f, .6f);
        Call(f.Receiver, "ReleaseStartupPresenceForScene", "head");
        Assert.That(f.OwnsPresentation, Is.False);
        Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f).Within(.0001f));
    }

    [TestCase("head")]
    [TestCase("target")]
    [TestCase("world")]
    public void TheDeliveredHomeCameraIsReleasedWhenARealSceneChangesItsComposition(string change)
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(1.53f, 1.53f);
        f.Advance(1.8f, .27f);
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(true));
        if (change == "head") Call(f.Framing, "SetFramingMode", "head");
        else if (change == "target") f.Framing.GetType().GetProperty("TargetRoot").SetValue(f.Framing, null);
        else
        {
            Component world = f.Camera.gameObject.AddComponent(Type.GetType("Maaso.World.WorldCameraDirector, Assembly-CSharp", true));
            Assert.That(Call(world, "EnterWorld", f.Camera, f.Framing, f.Root, null), Is.EqualTo(true));
        }
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(false));
    }

    [TestCase("target")]
    [TestCase("manual")]
    [TestCase("world")]
    public void ARealHomeCameraCannotAcquireAPresenceHoldForAnotherPresentation(string presentation)
    {
        using var f = new RealArrival();
        if (presentation == "manual") Call(f.Framing, "SetFramingMode", "manual_avatar_motion");
        else if (presentation == "world")
        {
            Component world = f.Camera.gameObject.AddComponent(Type.GetType("Maaso.World.WorldCameraDirector, Assembly-CSharp", true));
            Assert.That(Call(world, "EnterWorld", f.Camera, f.Framing, f.Root, null), Is.EqualTo(true));
        }
        Transform target = presentation == "target" ? null : f.Root;
        Assert.That(Call(f.Framing, "CompletePresenceCameraRoute", target), Is.EqualTo(false));
    }

    [TestCase("aspect")]
    [TestCase("rect")]
    [TestCase("safe-area")]
    public void AnActualViewportChangeReleasesTheDeliveredPresenceCamera(string change)
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(1.53f, 1.53f);
        f.Advance(1.8f, .27f);
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(true));
        if (change == "aspect") f.Camera.aspect = .7f;
        else if (change == "rect") f.Camera.rect = new Rect(0f, .1f, 1f, .9f);
        else Call(f.Framing, "SetViewportSafeArea", .06f, .12f);
        Call(f.Framing, "LateUpdate");
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(false),
            "An entrance handoff cannot freeze a real resize or safe-area layout.");
    }

    [Test]
    public void RepeatedIdenticalViewportMessagesPreserveTheSettledCamera()
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(1.53f, 1.53f);
        f.Advance(1.8f, .27f);
        float top = Field<float>(f.Framing, "topSafeViewport");
        float bottom = Field<float>(f.Framing, "bottomSafeViewport");
        Call(f.Framing, "SetViewportSafeArea", top, bottom);
        Call(f.Framing, "SetViewportSafeArea", top, bottom);
        Call(f.Framing, "LateUpdate");
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(true));
        f.AssertCameraUnchanged("identical viewport messages");
    }

    [Test]
    public void ANewDoorwayHandoffDoesNotInheritThePreviousPresenceViewportFence()
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(1.53f, 1.53f);
        f.Advance(1.8f, .27f);
        object rig = Field<object>(f.Framing, "entrySafetyRig");
        Call(f.Framing, "CompleteDoorwayCameraRoute", rig);
        f.Camera.aspect = .7f;
        Call(f.Framing, "LateUpdate");
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(true),
            "Presence-only resize cleanup must not clear a newer doorway's existing handoff contract.");
    }

    [Test]
    public void AnotherCameraOwnerCannotKeepAPresenceHoldEvenWhenItsModeNameMatches()
    {
        using var f = new RealArrival();
        f.Start(1800);
        f.Advance(1.53f, 1.53f);
        f.Advance(1.8f, .27f);
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(true));
        string mode = (string)f.Framing.GetType().GetProperty("FramingMode").GetValue(f.Framing);
        f.Framing.GetType().GetField("autoFrameEnabled", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(f.Framing, false);
        Assert.That(f.Framing.GetType().GetProperty("FramingMode").GetValue(f.Framing), Is.EqualTo(mode));
        Call(f.Framing, "LateUpdate");
        Assert.That(Call(f.Framing, "HoldDoorwayCamera"), Is.EqualTo(false));
    }

    private static Type AvatarType(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object subject, string method, params object[] args) => subject.GetType()
        .GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
        .Single(candidate => candidate.Name == method && candidate.GetParameters().Length == args.Length)
        .Invoke(subject, args);
    private static T Field<T>(object subject, string name) => (T)subject.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(subject);

    [Serializable]
    private sealed class Frame
    {
        public float elapsed, gaitSpeed, facingAngle;
        public Vector3 rootPosition, hips, leftFoot, rightFoot, localHips, localLeftFoot, localRightFoot, cameraPosition;
        public Quaternion rootRotation;
        public Quaternion cameraRotation;
        public float fieldOfView;
        public bool blending, walking;
    }

    [Serializable]
    private sealed class Evidence
    {
        public string renderReference = "Synchronous EditMode CPU BakeMesh from sampled Animator and VRM bones; not player GPU capture";
        public Frame[] frames;
    }

    private sealed class RealArrival : IDisposable
    {
        public readonly Component Receiver;
        public readonly Transform Root;
        public readonly Animator Animator;
        public readonly Camera Camera;
        public readonly Behaviour Framing;
        public readonly Vector3 HomePosition;
        public readonly Quaternion HomeRotation;
        private readonly GameObject room;
        private readonly Vrm10Instance vrm;
        private readonly Vector3 restingLeftFoot, restingRightFoot;
        private Vector3 cameraPosition;
        private Quaternion cameraRotation;
        private float fieldOfView;
        private readonly List<Frame> frames = new();
        private long sequence;
        private long utc;
        private float startedAt;
        private int durationMs;
        private readonly HashSet<string> captured = new();
        public bool CaptureEvidence;
        private static string EvidenceFolder => Environment.GetEnvironmentVariable("MAASO_ARRIVAL_EVIDENCE") ??
            Path.Combine(Path.GetTempPath(), "maaso-avatar-arrival-continuity");
        private object Controller => Field<object>(Receiver, "presenceTransition");
        public object ControllerInstance => Controller;
        public bool OwnsPresentation => (bool)Controller.GetType().GetProperty("OwnsPresentation").GetValue(Controller);
        public AnimatorStateInfo UpcomingState => Animator.IsInTransition(0)
            ? Animator.GetNextAnimatorStateInfo(0) : Animator.GetCurrentAnimatorStateInfo(0);

        public RealArrival()
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Receiver = Object.FindAnyObjectByType(AvatarType("UnityAvatarCommandReceiver")) as Component;
            Vrm10Instance bound = Object.FindAnyObjectByType<Vrm10Instance>();
            Assert.That(bound, Is.Not.Null);
            int materialSlots = bound.GetComponentsInChildren<Renderer>()
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .Sum(renderer => renderer.sharedMaterials.Length);
            for (int index = 0; index < materialSlots; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Call(Receiver, "Awake");
            Call(Receiver, "ApplyExpression");
            Root = (Transform)Receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(Receiver);
            Animator = Root.GetComponentInChildren<Animator>(true);
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.Rebind();
            Call(Receiver, "TryStartDesignedIdle", Field<string>(Receiver, "designedIdleStateName"));
            Animator.Update(.25f);
            vrm = Root.GetComponentInChildren<Vrm10Instance>(true);
            vrm.Runtime.Process();
            Camera = Camera.main;
            Framing = Camera.GetComponent(AvatarType("FrontFullBodyCamera")) as Behaviour;
            Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, Root);
            room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
            Component map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Call(map, "SetWorldActive", false);
            Call(map, "AlignHomeAvatar", Root);
            Camera.aspect = 393f / 852f;
            Call(Framing, "FrameNow");
            HomePosition = Root.position;
            HomeRotation = Root.rotation;
            restingLeftFoot = Root.InverseTransformPoint(Animator.GetBoneTransform(HumanBodyBones.LeftFoot).position);
            restingRightFoot = Root.InverseTransformPoint(Animator.GetBoneTransform(HumanBodyBones.RightFoot).position);
            cameraPosition = Camera.transform.position;
            cameraRotation = Camera.transform.rotation;
            fieldOfView = Camera.fieldOfView;
        }

        public void Start(int durationMs)
        {
            this.durationMs = durationMs;
            utc = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            Send("prepare", durationMs);
            Call(Receiver, "OnFlutterCommand", "{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}");
            // A hidden preparation may update the projection from the actual
            // loaded rig. Continuity begins with the first visible entry frame.
            cameraPosition = Camera.transform.position;
            cameraRotation = Camera.transform.rotation;
            fieldOfView = Camera.fieldOfView;
            Send("enter", durationMs);
            startedAt = Field<float>(Controller, "startedAt");
            Assert.That(Root.GetComponentsInChildren<Renderer>(true).Any(renderer =>
                renderer.enabled && !renderer.forceRenderingOff &&
                (Camera.cullingMask & (1 << renderer.gameObject.layer)) != 0), Is.True,
                "The real entrance must render the actor, rather than testing an account-hidden mesh.");
        }

        private void Send(string phase, int durationMs)
        {
            string json = "{\"requestId\":\"continuity-" + ++sequence + "\",\"transitionId\":\"arrival-continuity\",\"doNotInterrupt\":true," +
                "\"phase\":\"" + phase + "\",\"edge\":\"right\",\"durationMs\":" + durationMs +
                ",\"sequence\":" + sequence + ",\"expiresAtMs\":" + (utc + 12000) + "}";
            Call(Receiver, "OnFlutterCommand", "{\"method\":\"transitionPresence\",\"json\":\"" + json.Replace("\"", "\\\"") + "\"}");
        }

        public void PrepareHidden(string phase) => Send(phase, durationMs);

        public void Advance(float elapsed, float delta)
        {
            Animator.Update(delta);
            Call(Controller, "Advance", startedAt + elapsed, utc + (long)(elapsed * 1000));
            vrm.Runtime.Process();
            if (Framing.enabled) Call(Framing, "AdvanceFraming", delta);
            frames.Add(new Frame {
                elapsed = elapsed, gaitSpeed = Animator.GetFloat("WorldWalkSpeed"),
                facingAngle = Quaternion.Angle(Root.rotation, HomeRotation), rootPosition = Root.position,
                hips = Animator.GetBoneTransform(HumanBodyBones.Hips).position,
                leftFoot = Animator.GetBoneTransform(HumanBodyBones.LeftFoot).position,
                rightFoot = Animator.GetBoneTransform(HumanBodyBones.RightFoot).position,
                localHips = Root.InverseTransformPoint(Animator.GetBoneTransform(HumanBodyBones.Hips).position),
                localLeftFoot = Root.InverseTransformPoint(Animator.GetBoneTransform(HumanBodyBones.LeftFoot).position),
                localRightFoot = Root.InverseTransformPoint(Animator.GetBoneTransform(HumanBodyBones.RightFoot).position),
                rootRotation = Root.rotation,
                cameraPosition = Camera.transform.position, cameraRotation = Camera.transform.rotation,
                fieldOfView = Camera.fieldOfView, blending = Animator.IsInTransition(0),
                walking = UpcomingState.IsName("standard_walk"),
            });
            float duration = durationMs / 1000f;
            if (CaptureEvidence)
            {
                if (elapsed >= duration * .85f - .02f) Capture("approaching");
                if (elapsed >= duration * .85f + .01f) Capture("stopping");
                if (elapsed >= duration * .925f) Capture("turning");
                if (elapsed >= duration) Capture("facing-camera");
                if (elapsed >= duration * .85f + .23f) Capture("settled");
            }
        }

        private void Capture(string label)
        {
            if (!captured.Add(label) || SystemInfo.graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Null) return;
            RenderTexture previous = Camera.targetTexture;
            RenderTexture active = RenderTexture.active;
            var target = new RenderTexture(393, 852, 24, RenderTextureFormat.ARGB32);
            var image = new Texture2D(393, 852, TextureFormat.RGBA32, false);
            var bakedMeshes = new List<Mesh>();
            var snapshots = new List<GameObject>();
            var liveMeshes = new List<SkinnedMeshRenderer>();
            try
            {
                // A synchronous EditMode test samples many Animator frames in
                // one Editor frame. Its GPU skin cache is not a new frame per
                // Camera.Render. Bake the actual sampled bones for this visual
                // reference, without changing assets or claiming player GPU QA.
                foreach (SkinnedMeshRenderer renderer in Root.GetComponentsInChildren<SkinnedMeshRenderer>())
                {
                    if (!renderer.enabled || renderer.forceRenderingOff) continue;
                    var mesh = new Mesh();
                    renderer.BakeMesh(mesh);
                    bakedMeshes.Add(mesh);
                    var snapshot = new GameObject("Arrival CPU pose reference");
                    snapshots.Add(snapshot);
                    snapshot.layer = renderer.gameObject.layer;
                    snapshot.transform.SetParent(renderer.transform, false);
                    snapshot.AddComponent<MeshFilter>().sharedMesh = mesh;
                    MeshRenderer visual = snapshot.AddComponent<MeshRenderer>();
                    visual.sharedMaterials = renderer.sharedMaterials;
                    visual.shadowCastingMode = renderer.shadowCastingMode;
                    visual.receiveShadows = renderer.receiveShadows;
                    renderer.enabled = false;
                    liveMeshes.Add(renderer);
                }
                Camera.targetTexture = target;
                Camera.Render();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, 393, 852), 0, 0);
                image.Apply();
                Directory.CreateDirectory(EvidenceFolder);
                File.WriteAllBytes(Path.Combine(EvidenceFolder, "arrival-" + durationMs + "-" + label + ".png"), image.EncodeToPNG());
            }
            finally
            {
                Camera.targetTexture = previous;
                RenderTexture.active = active;
                foreach (SkinnedMeshRenderer renderer in liveMeshes) if (renderer != null) renderer.enabled = true;
                foreach (GameObject snapshot in snapshots) Object.DestroyImmediate(snapshot);
                foreach (Mesh mesh in bakedMeshes) Object.DestroyImmediate(mesh);
                Object.DestroyImmediate(image);
                Object.DestroyImmediate(target);
            }
        }

        public void AssertCameraUnchanged(string phase)
        {
            Assert.That(Vector3.Distance(Camera.transform.position, cameraPosition), Is.LessThan(.0002f), phase);
            Assert.That(Quaternion.Angle(Camera.transform.rotation, cameraRotation), Is.LessThan(.01f), phase);
            Assert.That(Camera.fieldOfView, Is.EqualTo(fieldOfView).Within(.0002f), phase);
        }

        public void AssertSettledFeet()
        {
            Vector3 left = Root.InverseTransformPoint(Animator.GetBoneTransform(HumanBodyBones.LeftFoot).position);
            Vector3 right = Root.InverseTransformPoint(Animator.GetBoneTransform(HumanBodyBones.RightFoot).position);
            Assert.That(Vector3.Distance(left, restingLeftFoot), Is.LessThan(.03f),
                "The sampled real left foot must settle back to its idle support pose.");
            Assert.That(Vector3.Distance(right, restingRightFoot), Is.LessThan(.03f),
                "The sampled real right foot must settle back to its idle support pose.");
        }

        public void WriteEvidence(string label)
        {
            string folder = EvidenceFolder;
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, label + ".json"), JsonUtility.ToJson(new Evidence { frames = frames.ToArray() }, true));
        }

        public void Dispose()
        {
            if (Controller != null) Call(Controller, "CancelForReset", "test_finished");
            if (room != null) Object.DestroyImmediate(room);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}
