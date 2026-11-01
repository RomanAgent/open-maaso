using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

/// <summary>
/// Observes final Joy render-bone poses through the real Receiver boundary.
/// A separate native Animator is the reference, and its actual joint geometry
/// must itself pass a lowered-arm gate; an idle ID is not evidence of posture.
/// </summary>
public sealed class AvatarNaturalIdlePresentationTests
{
    private const string ControllerPath = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
    private const string ModelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
    private const string NativeIdle = "idle_shrug";
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object value, string name, params object[] args)
    {
        MethodInfo method = value.GetType().GetMethod(name, Private | BindingFlags.Public);
        Assert.That(method, Is.Not.Null, value.GetType().Name + "." + name);
        return method.Invoke(value, args);
    }
    private static T P<T>(object value, string name) => (T)value.GetType().GetProperty(name).GetValue(value);

    [TestCase(false)]
    [TestCase(true)]
    public void NativeReferenceItselfKeepsArmsLoweredThroughoutItsCycle(bool controls)
    {
        using var f = new Fixture(controls);
        for (int sample = 0; sample < 24; sample++)
        {
            f.Reference.SampleNative(sample / 24f);
            AssertLoweredArms(f.Reference, "native reference phase=" + sample + "/24");
        }
    }

    [TestCase(false, "stopped")]
    [TestCase(true, "stopped")]
    [TestCase(false, "listening")]
    [TestCase(true, "listening")]
    public void WaitingAndListeningPresentNativeLoweredArms(bool controls, string phase)
    {
        using var f = new Fixture(controls);
        f.SetPhase(phase);
        f.RunTo(2f);
        f.AssertNativePresentation(phase);
        f.RunTo(5f);
        f.AssertNativePresentation(phase + " sustained");
    }

    [TestCase(false)]
    [TestCase(true)]
    public void LongListeningKeepsActualPoseAndPhaseAcrossThirtySecondLease(bool controls)
    {
        using var f = new Fixture(controls);
        f.SetPhase("listening");
        f.RunTo(29.9f);
        f.AssertNativePresentation("before thirty-second lease renewal");
        object player = f.Get<object>("annieMotion");
        long priorEpisode = P<long>(player, "EpisodeId");
        float leaseStarted = (float)player.GetType().GetField("startedAt", Private).GetValue(player);
        float leaseEnds = (float)player.GetType().GetField("endsAt", Private).GetValue(player);
        TestContext.WriteLine("Lease boundary before=" + f.Diagnostic());
        TestContext.WriteLine("Lease admissions=" + f.LeaseAdmissions.ToString(Newtonsoft.Json.Formatting.None));
        Assert.That(P<string>(f.Get<object>("conversationMotion"), "Phase"), Is.EqualTo("listening"),
            "The long wait must remain a real listening episode.");
        Assert.That(priorEpisode, Is.EqualTo(1L),
            "Continuous initial listening must keep its first native admission until the first lease boundary.");
        Assert.That(leaseEnds - leaseStarted, Is.EqualTo(30f).Within(.001f),
            "Observe the actual bounded native lease, not a presumed first-admission time.");
        Assert.That(leaseEnds, Is.GreaterThan(f.Now), "The observed current lease must still be live before its boundary.");
        float priorPhase = f.Actual.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime;
        // A phase change or another production admission can renew the lease
        // before this observation. Cross the actual current player's deadline
        // on this fixture's monotonic timeline rather than assuming t=31.2.
        f.RunTo(f.Seconds + (leaseEnds - f.Now) + .5f);
        TestContext.WriteLine("Lease boundary after=" + f.Diagnostic());
        f.AssertNativePresentation("after thirty-second lease renewal");
        Assert.That(P<long>(player, "EpisodeId"), Is.GreaterThan(priorEpisode),
            "The production player must actually renew its lease, not silently keep an expired record.");
        Assert.That(f.Actual.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime, Is.GreaterThan(priorPhase),
            "A lease refresh must not restart the native Animator's real clock.");
    }

    [TestCase(false)]
    [TestCase(true)]
    public void SpeechStopReleasesAuthoredArmsAndReturnsToNativePose(bool controls)
    {
        using var f = new Fixture(controls);
        f.StartSpeech();
        f.RunTo(.6f);
        Assert.That(P<bool>(f.Get<object>("speechGestureAnimator"), "UsesDirectSource"), Is.True,
            "Exercise actual authored speech before testing its release.");
        Assert.That(f.SyncSpeech("stop", 2, 600), Is.True);
        f.SetPhase("stopped");
        f.RunTo(2f);
        f.AssertNativePresentation("after speech stop");
    }

    [TestCase(false)]
    [TestCase(true)]
    public void BentArmInterludeCompletesOneCycleThenRestoresNativePose(bool controls)
    {
        using var f = new Fixture(controls);
        f.SetPhase("stopped");
        f.RunTo(.6f);
        f.AssertNativePresentation("before interlude");
        object policy = f.Get<object>("conversationMotion");
        // Restrict the available local catalog, rather than injecting a pose or
        // bypassing the production admission/player. The remaining source must
        // still be selected by the real policy after its stable-silence gate.
        string[] fidgets = (string[])policy.GetType().GetField("Fidgets", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
        foreach (string id in fidgets.Where(id => id != "annie_idle_c"))
            Call(policy, "Reject", id, f.Now);
        policy.GetType().GetField("randomState", Private).SetValue(policy, 1u);
        float entered = float.NaN;
        for (int frame = 37; frame <= 1200; frame++)
        {
            f.Frame(frame / 60f);
            if (P<string>(f.Get<object>("annieMotion"), "ActiveId") != "annie_idle_c") continue;
            entered = f.Seconds;
            break;
        }
        Assert.That(float.IsNaN(entered), Is.False,
            "The real policy must admit the retained optional interlude. " + f.Diagnostic());
        f.RunTo(entered + 5.8f);
        Assert.That(P<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo("annie_idle_c"),
            "Do not hide this regression by cutting the six-second source short.");
        f.RunTo(entered + 7f);
        f.AssertNativePresentation("after complete six-second interlude");
    }

    private static void AssertLoweredArms(Model model, string context)
    {
        Vector3 hips = model.Raw(HumanBodyBones.Hips).position;
        float scale = model.Animator.humanScale;
        Assert.That(scale, Is.GreaterThan(.1f), context + ": actual Humanoid scale");
        foreach (var side in new[] {
            ("left", HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand),
            ("right", HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand) })
        {
            Vector3 shoulder = model.Raw(side.Item2).position;
            Vector3 elbow = model.Raw(side.Item3).position;
            Vector3 wrist = model.Raw(side.Item4).position;
            Vector3 upper = elbow - shoulder, lower = wrist - elbow;
            string label = context + "/" + side.Item1;
            float elbowFlex = Vector3.Angle(upper, lower);
            float forearmFromDown = Vector3.Angle(lower, -model.Actor.transform.up);
            float lateralWrist = Mathf.Abs(Vector3.Dot(wrist - elbow, model.Actor.transform.right));
            float handBeyondShoulder = Mathf.Abs(Vector3.Dot(wrist - hips, model.Actor.transform.right)) -
                Mathf.Abs(Vector3.Dot(shoulder - hips, model.Actor.transform.right));
            TestContext.WriteLine(label + ": elbow flex=" + elbowFlex + "; forearm/down=" + forearmFromDown +
                "; wrist/elbow lateral=" + lateralWrist + "; wrist relative hips Y=" + (wrist.y - hips.y));
            Assert.That(wrist.y, Is.LessThan(hips.y + .035f * scale), label + ": wrists remain beside the pelvis, rather than propped above it.");
            Assert.That(elbow.y - wrist.y, Is.GreaterThan(.14f * scale), label + ": forearms descend from elbows.");
            Assert.That(elbowFlex, Is.LessThan(28f), label + ": measure real joint directions, not quaternion rotation magnitude.");
            Assert.That(forearmFromDown, Is.LessThan(26f), label + ": forearms must not stay propped outward.");
            Assert.That(lateralWrist, Is.LessThan(.11f * scale), label + ": hands remain close to their hanging forearms.");
            Assert.That(handBeyondShoulder, Is.LessThan(.12f * scale), label + ": hands must not fan away from the torso.");
        }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Model Actual, Reference;
        private readonly Component receiver;
        private readonly GameObject host;
        private float origin;
        private readonly long utc = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        private long phaseSequence;
        private long observedEpisode = -1;
        private string requestedPhase;
        private float phaseReceiptAt;
        public readonly JArray LeaseAdmissions = new();
        public float Seconds { get; private set; }
        public float Now => origin + Seconds;
        public Fixture(bool controls)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Actual = new Model(controls, true);
            host = new GameObject("Final Joy natural idle Receiver test");
            receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            Set("bundledAvatarRoot", Actual.Actor.transform);
            Actual.ExpectMaterialInitialization();
            Call("BindAvatarRoot", Actual.Actor.transform);
            Actual.InitializeRuntime();
            Actual.Deformation = Get<object>("activeArmDeformation");
            Actual.Animator.Rebind(); Actual.Animator.Update(0f); Actual.Runtime.Process();
            AvatarNaturalIdlePresentationTests.Call(Get<object>("localVisibility"), "SetVisible", true);
            // This is the real initially unclaimed/free host lane. Fabricating
            // a nonempty ticket owner without its released reset identity would
            // correctly block ALL ambient policy work, hiding it behind the
            // native fallback and making a posture-only test pass accidentally.
            Assert.That(Call("HostBackgroundWorkAuthorityReleased"), Is.EqualTo(true));
            Reference = new Model(controls, false);
            // Load the real library/scheduler before pinning the synthetic
            // monotonic origin. A cold load after origin capture can make the
            // next synthetic frame precede the real phase receipt and correctly
            // trigger the policy's clock-rollback reset.
            Assert.That(Call("EnsureSpeechPerformance"), Is.EqualTo(true));
            origin = Time.realtimeSinceStartup;
        }
        public T Get<T>(string name) => (T)receiver.GetType().GetField(name, Private).GetValue(receiver);
        private void Set(string name, object value) => receiver.GetType().GetField(name, Private).SetValue(receiver, value);
        public object Call(string name, params object[] args) => AvatarNaturalIdlePresentationTests.Call(receiver, name, args);
        public void SetPhase(string phase)
        {
            Call("SetConversationPhase", new JObject { ["phase"] = phase, ["sequence"] = ++phaseSequence }.ToString());
            // Anchor only the fixture clock AFTER the real command receipt;
            // never overwrite policy phase, timers or authored pose output.
            if (Seconds == 0f) origin = Time.realtimeSinceStartup;
            requestedPhase = phase;
            phaseReceiptAt = Now;
        }
        public void StartSpeech()
        {
            Assert.That(Call("EnsureSpeechPerformance"), Is.EqualTo(true));
            Assert.That(Call("QueueSpeechPerformanceCue", "speech", "neutral", "moderate", .65f, 1L, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4500), Is.EqualTo(true));
            Assert.That(SyncSpeech("start", 1, 0), Is.True);
        }
        public bool SyncSpeech(string state, long sequence, long position)
        {
            var packet = new JObject { ["protocolVersion"] = 1, ["playbackId"] = "natural-idle-speech", ["generation"] = 1,
                ["turnId"] = "source-turn", ["utteranceId"] = "source-utterance", ["sequence"] = sequence,
                ["state"] = state, ["positionMs"] = position, ["durationMs"] = 6000,
                ["source"] = "wav", ["authoritative"] = true };
            if (state == "start") { packet["envelope"] = JArray.FromObject(Enumerable.Repeat(.2f, 180)); packet["frameRate"] = 30; }
            bool accepted = (bool)Call("SyncSpeechPlaybackClock", packet.ToObject(A("AvatarSpeechPlaybackClockPacket")));
            if (accepted && Seconds == 0f) origin = Time.realtimeSinceStartup;
            object clock = Get<object>("speechPlaybackClock");
            clock.GetType().GetField("receivedAt", Private).SetValue(clock, Now);
            return accepted;
        }
        public void RunTo(float seconds)
        {
            while (Seconds + 1f / 60f < seconds) Frame(Seconds + 1f / 60f);
            if (seconds > Seconds) Frame(seconds);
        }
        public void Frame(float seconds)
        {
            Call("Update");
            Actual.Animator.Update(seconds - Seconds);
            Seconds = seconds;
            Call("AdvancePresentationFrame", Now, utc + (long)(seconds * 1000));
            if (requestedPhase == "listening" && Now - phaseReceiptAt >= .4f)
            {
                object policy = Get<object>("conversationMotion");
                Assert.That(P<string>(policy, "Phase"), Is.EqualTo("listening"), Diagnostic());
                Assert.That(policy.GetType().GetField("desiredPhase", Private).GetValue(policy), Is.EqualTo("listening"), Diagnostic());
            }
            Actual.Runtime.Process();
            if (Actual.Deformation != null) AvatarNaturalIdlePresentationTests.Call(Actual.Deformation, "ApplyAfterVrm");
            long episode = P<long>(Get<object>("annieMotion"), "EpisodeId");
            if (episode != observedEpisode)
            {
                observedEpisode = episode;
                LeaseAdmissions.Add(JObject.Parse(Diagnostic()));
            }
        }
        public void AssertNativePresentation(string context)
        {
            Assert.That(Call("HostBackgroundWorkAuthorityReleased"), Is.EqualTo(true), context + ": free host lane");
            Assert.That(Get<bool>("conversationHintsEnabled"), Is.True, context + ": real conversation policy enabled");
            Assert.That(P<string>(Get<object>("conversationMotion"), "ActiveId"), Is.EqualTo(NativeIdle),
                context + ": the policy itself must own the base, rather than an unrelated fallback.");
            Assert.That(P<string>(Get<object>("annieMotion"), "ActiveId"), Is.EqualTo(NativeIdle),
                context + ": the real player must have admitted the policy's native base.");
            AnimatorStateInfo state = Actual.Animator.GetCurrentAnimatorStateInfo(0);
            Assert.That(state.IsName("Base Layer." + NativeIdle), Is.True, context);
            Assert.That(Actual.Animator.IsInTransition(0), Is.False, context);
            Assert.That(Get<object>("normalizedPoseEntry"), Is.Null, context + ": native base must release authored FK ownership.");
            Assert.That(P<bool>(Get<object>("normalizedArmPose"), "HasOwnedWrites"), Is.False, context);
            Reference.SampleNative(state.normalizedTime);
            AssertLoweredArms(Reference, context + "/independent native reference");
            AssertLoweredArms(Actual, context + "/actual Receiver");
            foreach (HumanBodyBones id in ArmBones())
            {
                Transform actual = Actual.Raw(id), expected = Reference.Raw(id);
                Assert.That(actual, Is.Not.Null, context + "/" + id);
                Assert.That(expected, Is.Not.Null, context + "/" + id);
                Assert.That(Vector3.Distance(actual.position, expected.position), Is.LessThan(.004f),
                    context + "/" + id + ": compare final raw shoulder/elbow/wrist/finger positions.");
                if (id >= HumanBodyBones.LeftThumbProximal && id <= HumanBodyBones.RightLittleDistal)
                    Assert.That(Quaternion.Angle(actual.rotation, expected.rotation), Is.LessThan(1.3f),
                        context + "/" + id + ": previous authored fingers must not remain applied.");
            }
        }
        public string Diagnostic()
        {
            object policy = Get<object>("conversationMotion");
            object player = Get<object>("annieMotion");
            var result = new JObject { ["seconds"] = Seconds, ["now"] = Now,
                ["fixtureOrigin"] = origin, ["realClock"] = Time.realtimeSinceStartup,
                ["requestedPhase"] = requestedPhase, ["phaseReceiptAt"] = phaseReceiptAt,
                ["playerId"] = P<string>(player, "ActiveId"),
                ["playerEpisode"] = P<long>(player, "EpisodeId"),
                ["playerStartedAt"] = (float)player.GetType().GetField("startedAt", Private).GetValue(player),
                ["playerEndsAt"] = (float)player.GetType().GetField("endsAt", Private).GetValue(player),
                ["policyId"] = P<string>(policy, "ActiveId"),
                ["policyClip"] = Get<string>("conversationPolicyClip"),
                ["authorityReleased"] = (bool)Call("HostBackgroundWorkAuthorityReleased"),
                ["annieMotionBlocked"] = (bool)Call("AnnieMotionBlocked"),
                ["actionPoseHoldUntil"] = Get<float>("actionPoseHoldUntil") };
            foreach (string name in new[] { "phase", "desiredPhase", "stableSince", "nextChoiceAt",
                "nextFidgetAt", "lastNow", "activeLoop", "activeEndsAt", "suspended", "randomState" })
            {
                object value = policy.GetType().GetField(name, Private).GetValue(policy);
                result[name] = value == null ? JValue.CreateNull() : JToken.FromObject(value);
            }
            return result.ToString(Newtonsoft.Json.Formatting.None);
        }
        public void Dispose()
        {
            Object.DestroyImmediate(host);
            Actual.Dispose(); Reference.Dispose();
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    private sealed class Model : IDisposable
    {
        public readonly GameObject Actor;
        public readonly Animator Animator;
        public readonly Vrm10Instance Vrm;
        public Vrm10Runtime Runtime { get; private set; }
        public object Deformation;
        private readonly Dictionary<Renderer, Material[]> materials;
        public Model(bool controls, bool receiverWillInitialize)
        {
            Actor = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath));
            Actor.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            materials = Actor.GetComponentsInChildren<Renderer>(true).ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
            Vrm = Actor.GetComponent<Vrm10Instance>(); Vrm.enabled = false;
            typeof(Vrm10Instance).GetField("m_useControlRig", Private).SetValue(Vrm, controls);
            Animator = Actor.GetComponent<Animator>();
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(ControllerPath);
            Animator.applyRootMotion = false; Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            if (receiverWillInitialize) return;
            ExpectMaterialInitialization(); InitializeRuntime();
            Deformation = Actor.AddComponent(A("AvatarRigifyArmDeformation"));
            Assert.That(Call(Deformation, "Bind", Actor.transform), Is.EqualTo(true), "Real Joy deformation adapter must bind on the reference too.");
            Animator.Rebind(); Animator.Play("Base Layer." + NativeIdle, 0, 0f); Animator.Update(0f); Runtime.Process();
        }
        public void ExpectMaterialInitialization()
        {
            int slots = materials.Values.Sum(value => value.Count(material => material != null));
            Assert.That(slots, Is.EqualTo(17), "Reviewed Joy material inventory changed.");
            for (int i = 0; i < slots; i++) LogAssert.Expect(LogType.Error,
                "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
        }
        public void InitializeRuntime() => Runtime = Vrm.Runtime;
        public Transform Raw(HumanBodyBones id) => Vrm.Humanoid.GetBoneTransform(id);
        public void SampleNative(float phase)
        {
            if (Deformation != null) Call(Deformation, "RestoreBeforeAnimation");
            Animator.Play("Base Layer." + NativeIdle, 0, phase); Animator.Update(0f);
            Runtime.Process();
            if (Deformation != null) Call(Deformation, "ApplyAfterVrm");
        }
        public void Dispose()
        {
            var original = new HashSet<Material>(materials.Values.SelectMany(value => value));
            var created = new HashSet<Material>();
            foreach (var pair in materials) if (pair.Key != null)
            {
                foreach (Material item in pair.Key.sharedMaterials)
                    if (item != null && !original.Contains(item) && !EditorUtility.IsPersistent(item)) created.Add(item);
                pair.Key.sharedMaterials = pair.Value;
            }
            foreach (Material material in created) Object.DestroyImmediate(material);
            if (Runtime?.ControlRig != null)
            {
                Object.DestroyImmediate(Runtime.ControlRig.ControlRigAnimator.avatar);
                Transform rig = Actor.transform.Find("Runtime Control Rig");
                if (rig != null) Object.DestroyImmediate(rig.gameObject);
            }
            Object.DestroyImmediate(Actor);
        }
    }
    private static IEnumerable<HumanBodyBones> ArmBones()
    {
        foreach (HumanBodyBones id in new[] { HumanBodyBones.LeftShoulder, HumanBodyBones.RightShoulder,
            HumanBodyBones.LeftUpperArm, HumanBodyBones.RightUpperArm, HumanBodyBones.LeftLowerArm,
            HumanBodyBones.RightLowerArm, HumanBodyBones.LeftHand, HumanBodyBones.RightHand }) yield return id;
        for (int id = (int)HumanBodyBones.LeftThumbProximal; id <= (int)HumanBodyBones.RightLittleDistal; id++)
            yield return (HumanBodyBones)id;
    }
}
