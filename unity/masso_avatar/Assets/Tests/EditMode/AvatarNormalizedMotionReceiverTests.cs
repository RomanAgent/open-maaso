using System;
using System.Collections.Generic;
using System.IO;
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

/// <summary>Exercises the real Receiver selection/evaluation boundary rather
/// than invoking the normalized sampler in isolation.</summary>
public sealed class AvatarNormalizedMotionReceiverTests
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private const string Source = "Assets/MaasoAvatar/Editor/OpenAnnieSource/";
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object value, string name, params object[] args) =>
        value.GetType().GetMethod(name, Private | BindingFlags.Public).Invoke(value, args);
    private static T P<T>(object value, string name) => (T)value.GetType().GetProperty(name).GetValue(value);
    private static T F<T>(object value, string name) => (T)value.GetType().GetField(name).GetValue(value);
    private static long Utc => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    [TestCase(false)]
    [TestCase(true)]
    public void ActualJoyBindAndSettledSpeechPreserveOriginalArmsAndFingers(bool controls)
    {
        using var f = new Fixture(controls);
        f.StartSpeech();
        f.Settle();
        object speech = f.Get<object>("speechGestureAnimator");
        object sample = P<object>(speech, "CurrentSample");
        Assert.That(P<bool>(speech, "UsesDirectSource"), Is.True);
        Assert.That(P<bool>(f.Get<object>("normalizedArmPose"), "UsesControlRig"), Is.EqualTo(controls));
        Assert.That(f.Animator.GetLayerWeight(f.Animator.GetLayerIndex("Annie Upper Body")), Is.Zero,
            "The native layer cannot already blend/dilute the direct source.");
        Assert.That(P<bool>(f.Get<object>("upperBodyInertia"), "Transitioning"), Is.False);
        Assert.That(P<bool>(f.Get<object>("freeGestureCollision"), "HasOwnedWrites"), Is.False);
        Assert.That(P<bool>(f.Get<object>("conversationalMicroMotion"), "HasOwnedWrites"), Is.False);
        f.AssertOriginal(F<object>(sample, "Entry"), F<float>(sample, "ClipSeconds"));
        Assert.That(f.Actor.transform.position, Is.EqualTo(Vector3.zero));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ActualExplicitBodyUsesItsEvaluatedAnimatorClockForOriginalPose(bool controls)
    {
        using var f = new Fixture(controls);
        f.Call("ApplyPrimitive", "wave", .8f);
        f.Settle();
        object entry = f.Get<object>("normalizedPoseEntry");
        Assert.That(entry, Is.Not.Null);
        Assert.That(F<string>(entry, "Id"), Is.EqualTo("annie_wave"));
        Assert.That(P<bool>(f.Get<object>("normalizedArmPose"), "HasOwnedWrites"), Is.True);
        int layer = F<bool>(entry, "UpperBody") ? f.Animator.GetLayerIndex("Annie Upper Body") : 0;
        AnimatorStateInfo state = f.Animator.GetCurrentAnimatorStateInfo(layer);
        int expected = Animator.StringToHash("annie_wave");
        if (f.Animator.IsInTransition(layer) && f.Animator.GetNextAnimatorStateInfo(layer).shortNameHash == expected)
            state = f.Animator.GetNextAnimatorStateInfo(layer);
        Assert.That(state.shortNameHash, Is.EqualTo(expected), "Use the evaluated body state, not a synthetic replay cursor.");
        float seconds = (F<bool>(entry, "Loop") ? Mathf.Repeat(state.normalizedTime, 1f) :
            Mathf.Clamp01(state.normalizedTime)) * F<float>(entry, "Duration");
        Assert.That(seconds, Is.GreaterThan(.35f));
        f.AssertOriginal(entry, seconds);
    }

    [Test]
    public void SameWaveRestartSelectedAfterAnimatorEvaluationWaitsForItsRealNewPhase()
    {
        using var f = new Fixture(true);
        f.Call("ApplyPrimitive", "wave", .8f); f.Settle();
        object original = f.Get<object>("normalizedPoseEntry");
        long priorEpisode = P<long>(f.Get<object>("annieMotion"), "EpisodeId");
        Vector3[] prior = ArmJoints().Select(id => f.Bone(id).position).ToArray();
        var trace = new JArray();
        float maximum = 0f;
        for (int frame = 37; frame <= 65; frame++)
        {
            // Native messages/policy decisions may select a state after the
            // Animator has already evaluated this frame. An identical state
            // hash still refers to its outgoing phase at that exact boundary.
            f.Frame(frame / 60f, frame == 37 ? (Action)(() => f.Call("ApplyPrimitive", "wave", .8f)) : null);
            Vector3[] next = ArmJoints().Select(id => f.Bone(id).position).ToArray();
            float[] steps = next.Select((value, i) => Vector3.Distance(value, prior[i])).ToArray();
            maximum = Mathf.Max(maximum, steps.Max());
            var joints = new JArray();
            int index = 0;
            foreach (HumanBodyBones id in ArmJoints())
            {
                Transform bone = f.Bone(id), raw = f.RawBone(id);
                joints.Add(new JObject { ["bone"] = id.ToString(), ["step"] = steps[index++],
                    ["world"] = V(bone.position), ["localRotation"] = Q(bone.localRotation),
                    ["rawWorld"] = V(raw.position), ["rawLocalRotation"] = Q(raw.localRotation) });
            }
            var offsets = new JArray();
            object inertia = f.Get<object>("upperBodyInertia");
            foreach (object state in (System.Collections.IEnumerable)inertia.GetType().GetField("bones", Private).GetValue(inertia))
            {
                Transform bone = F<Transform>(state, "Transform");
                offsets.Add(new JObject { ["bone"] = bone.name, ["source"] = Q(F<Quaternion>(state, "Source")),
                    ["output"] = Q(F<Quaternion>(state, "Output")), ["previousSource"] = Q(F<Quaternion>(state, "PreviousSource")),
                    ["offset"] = V(F<Vector3>(state, "Offset")), ["offsetVelocity"] = V(F<Vector3>(state, "OffsetVelocity")),
                    ["outputVelocity"] = V(F<Vector3>(state, "OutputVelocity")) });
            }
            trace.Add(new JObject { ["frame"] = frame, ["seconds"] = frame / 60f,
                ["selectedSeconds"] = f.Get<float>("normalizedPoseSeconds"),
                ["episode"] = f.Get<long>("normalizedPoseEpisode"),
                ["transition"] = P<bool>(inertia, "Transitioning"),
                ["currentStateTime"] = f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime,
                ["nextStateTime"] = f.Animator.GetNextAnimatorStateInfo(0).normalizedTime,
                ["nativeTransition"] = f.Animator.IsInTransition(0),
                ["root"] = V(f.Actor.transform.position), ["hips"] = V(f.Bone(HumanBodyBones.Hips).position),
                ["joints"] = joints, ["inertia"] = offsets });
            prior = next;
        }
        string tracePath = Path.Combine(Path.GetTempPath(), "maaso-wave-restart-trace.json");
        File.WriteAllText(tracePath, trace.ToString());
        TestContext.WriteLine("WaveRestartTracePath=" + tracePath);
        Assert.That(P<long>(f.Get<object>("annieMotion"), "EpisodeId"), Is.GreaterThan(priorEpisode));
        Assert.That(f.Get<object>("normalizedPoseEntry"), Is.SameAs(original));
        TestContext.WriteLine("Repeated same-ID wave selected after evaluation; max joint step meters=" + maximum);
        Assert.That(maximum, Is.LessThan(.06f), "A restarted episode must not consume its transition using the old phase.");
    }

    [Test]
    public void NextSpeechEpochCanSelectSameInstalledTalkSourceWithoutRevivingItsOldCursor()
    {
        using var f = new Fixture(true);
        f.StartSpeech(); f.Settle();
        object original = f.Get<object>("normalizedPoseEntry");
        long priorEpoch = P<long>(f.Get<object>("speechPlaybackClock"), "Epoch");
        object scheduler = f.Get<object>("speechGestures");
        FieldInfo selector = scheduler.GetType().GetField("restSelection", Private);
        // Deterministically choose the SAME eligible installed rest on the next
        // start, rather than accidentally testing an ordinary different-ID path.
        selector.SetValue(scheduler, (int)selector.GetValue(scheduler) - 1);
        Assert.That(f.Sync("start", 1, 0, "source-audio-next", 2), Is.True);
        f.RebaseReceipt(37f / 60f);
        Vector3[] prior = ArmJoints().Select(id => f.Bone(id).position).ToArray();
        float maximum = 0f;
        for (int frame = 37; frame <= 65; frame++)
        {
            f.Frame(frame / 60f);
            Vector3[] next = ArmJoints().Select(id => f.Bone(id).position).ToArray();
            maximum = Mathf.Max(maximum, next.Select((value, i) => Vector3.Distance(value, prior[i])).Max());
            prior = next;
        }
        object sample = P<object>(f.Get<object>("speechGestureAnimator"), "CurrentSample");
        Assert.That(F<object>(sample, "Entry"), Is.SameAs(original));
        Assert.That(F<float>(sample, "ClipSeconds"), Is.LessThan(.5f), "Use the new chunk cursor, not the retired .6s cursor.");
        long epoch = P<long>(f.Get<object>("speechPlaybackClock"), "Epoch");
        Assert.That(epoch, Is.GreaterThan(priorEpoch));
        Assert.That(f.Get<long>("normalizedPoseEpisode"), Is.EqualTo(epoch));
        Assert.That(f.Get<bool>("normalizedPoseSpeech"), Is.True);
        Assert.That(maximum, Is.LessThan(.06f));
    }

    [Test]
    public void OrdinaryReleaseIsContinuousButLocomotionAndModelReplacementImmediatelyRetireSource()
    {
        using var f = new Fixture(true);
        f.StartSpeech(); f.Settle();
        object retiredSpeech = f.Get<object>("normalizedPoseEntry");
        Transform hand = f.Bone(HumanBodyBones.LeftHand);
        Quaternion shown = hand.localRotation;
        Assert.That(f.Sync("stop", 2, 600), Is.True);
        f.Call("ClearSpeechPerformanceCue");
        f.Frame(37f / 60f);
        Assert.That(P<bool>(f.Get<object>("speechGestureAnimator"), "UsesDirectSource"), Is.False);
        object nextSource = f.Get<object>("normalizedPoseEntry");
        Assert.That(nextSource, Is.Not.SameAs(retiredSpeech), "Stopped audio cannot retain its former source pose owner.");
        if (nextSource != null)
        {
            Assert.That(F<string>(nextSource, "Id"), Is.EqualTo(f.Get<string>("conversationPolicyClip")),
                "A surviving direct source must be the independently active base policy, not stale speech.");
            Assert.That(new[] { "idle", "listen" }.Contains(F<string>(nextSource, "Category")), Is.True);
        }
        Assert.That(P<bool>(f.Get<object>("upperBodyInertia"), "Transitioning"), Is.True);
        Assert.That(Quaternion.Angle(hand.localRotation, shown), Is.LessThan(.1f),
            "An ordinary source exit must start at the last presented hand pose.");

        // A real Receiver task entry must clear the transition and the cue;
        // removing the gate cannot revive the old speech source.
        f.Call("SetWorldLocomotion", true);
        f.Frame(38f / 60f);
        Assert.That(P<bool>(f.Get<object>("normalizedArmPose"), "HasOwnedWrites"), Is.False);
        Assert.That(P<bool>(f.Get<object>("upperBodyInertia"), "Transitioning"), Is.False);
        Quaternion task = Quaternion.Euler(13f, 19f, -11f);
        hand.localRotation = task;
        Assert.That(f.Call("AdvanceNormalizedArmPose"), Is.EqualTo(false));
        Assert.That(Quaternion.Angle(hand.localRotation, task), Is.LessThan(.01f));
        f.Call("SetWorldLocomotion", false);
        Assert.That(f.Call("AdvanceNormalizedArmPose"), Is.EqualTo(false));

        GameObject replacement = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        try
        {
            // Keep a real humanoid rig but remove its VRM wrapper to exercise
            // model replacement onto the native animation fallback.
            Object.DestroyImmediate(replacement.GetComponent<Vrm10Instance>());
            replacement.GetComponent<Animator>().runtimeAnimatorController =
                AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            f.Call("BindAvatarRoot", replacement.transform);
            Assert.That(P<bool>(f.Get<object>("normalizedArmPose"), "Bound"), Is.False,
                "A non-VRM replacement must explicitly return to the native fallback.");
            Assert.That(P<bool>(f.Get<object>("speechGestureAnimator"), "UsesDirectSource"), Is.False);
            Assert.That(f.Get<object>("normalizedPoseEntry"), Is.Null);
            Assert.That(f.Call("AdvanceNormalizedArmPose"), Is.EqualTo(false));
            Assert.That(Quaternion.Angle(hand.localRotation, task), Is.LessThan(.01f),
                "Rebinding cannot restore stale writes into the detached rig.");
        }
        finally { Object.DestroyImmediate(replacement); }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Actor;
        public readonly Animator Animator;
        private readonly Component receiver;
        private readonly GameObject host;
        private readonly Vrm10Instance vrm;
        private readonly Vrm10Runtime runtime;
        private readonly bool controls;
        private readonly Dictionary<Renderer, Material[]> materials;
        private readonly Dictionary<HumanBodyBones, (Quaternion local, Quaternion global)> rest = new();
        private readonly Dictionary<HumanBodyBones, Quaternion> observed = new();
        private float origin, previous;
        private readonly long utc = Utc;
        public Fixture(bool useControlRig)
        {
            controls = useControlRig;
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Actor = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Actor.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            materials = Actor.GetComponentsInChildren<Renderer>(true).ToDictionary(r => r, r => r.sharedMaterials);
            vrm = Actor.GetComponent<Vrm10Instance>(); vrm.enabled = false;
            typeof(Vrm10Instance).GetField("m_useControlRig", Private).SetValue(vrm, controls);
            Animator = Actor.GetComponent<Animator>();
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.applyRootMotion = false; Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            host = new GameObject("Actual normalized source Receiver test");
            receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            Set("bundledAvatarRoot", Actor.transform);
            for (int i = 0; i < 17; i++) LogAssert.Expect(LogType.Error,
                "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
            Call("BindAvatarRoot", Actor.transform);
            runtime = vrm.Runtime;
            foreach (HumanBodyBones id in ArmBones())
            {
                Transform bone = Bone(id); Assert.That(bone, Is.Not.Null, id.ToString());
                rest.Add(id, (bone.localRotation, bone.rotation));
            }
            Animator.Rebind(); Animator.Update(0f); runtime.Process();
            AvatarNormalizedMotionReceiverTests.Call(Get<object>("localVisibility"), "SetVisible", true);
            Set("avatarArbiterOwnerToken", new string('A', 43));
            Set("avatarArbiterAccountGeneration", 7L);
            Set("avatarArbiterRendererGeneration", 1L);
            Set("avatarArbiterRendererGenerationHighWater", 1L);
            origin = Time.realtimeSinceStartup;
        }
        public T Get<T>(string name) => (T)receiver.GetType().GetField(name, Private).GetValue(receiver);
        private void Set(string name, object value) => receiver.GetType().GetField(name, Private).SetValue(receiver, value);
        public object Call(string name, params object[] args) => AvatarNormalizedMotionReceiverTests.Call(receiver, name, args);
        public Transform Bone(HumanBodyBones id) => controls ? runtime.ControlRig.GetBoneTransform(id) :
            vrm.TryGetBoneTransform(id, out Transform value) ? value : null;
        public Transform RawBone(HumanBodyBones id) => vrm.Humanoid.GetBoneTransform(id);
        public void StartSpeech()
        {
            Assert.That(Call("EnsureSpeechPerformance"), Is.EqualTo(true));
            Assert.That(Call("QueueSpeechPerformanceCue", "speech", "neutral", "moderate", .65f, 1L, Utc + 4500), Is.EqualTo(true));
            Assert.That(Sync("start", 1, 0), Is.True);
            origin = Time.realtimeSinceStartup;
        }
        public bool Sync(string state, long sequence, long position, string id = "source-audio", long generation = 1)
        {
            var packet = new JObject { ["protocolVersion"] = 1, ["playbackId"] = id, ["generation"] = generation,
                ["turnId"] = "source-turn", ["utteranceId"] = "source-utterance", ["sequence"] = sequence,
                ["state"] = state, ["positionMs"] = position, ["durationMs"] = 6000,
                ["source"] = "wav", ["authoritative"] = true };
            if (state == "start") { packet["envelope"] = JArray.FromObject(Enumerable.Repeat(.2f, 180)); packet["frameRate"] = 30; }
            return (bool)Call("SyncSpeechPlaybackClock", packet.ToObject(A("AvatarSpeechPlaybackClockPacket")));
        }
        public void RebaseReceipt(float seconds) => Get<object>("speechPlaybackClock").GetType().GetField("receivedAt", Private)
            .SetValue(Get<object>("speechPlaybackClock"), origin + seconds);
        public void Settle() { for (int i = 0; i <= 36; i++) Frame(i / 60f); }
        public void Frame(float seconds, Action afterAnimator = null)
        {
            Call("Update");
            Animator.Update(seconds - previous); previous = seconds;
            afterAnimator?.Invoke();
            Call("AdvancePresentationFrame", origin + seconds, utc + (long)(seconds * 1000));
            // Observe normalized FK before UniVRM maps it into raw skin bones.
            // The later Rigify skin helper deliberately changes raw upper-arm
            // roll without changing this authored control pose.
            foreach (HumanBodyBones id in ArmBones()) observed[id] = Bone(id).localRotation;
            runtime.Process();
            object deformation = Get<object>("activeArmDeformation");
            if (deformation != null) AvatarNormalizedMotionReceiverTests.Call(deformation, "ApplyAfterVrm");
        }
        public void AssertOriginal(object entry, float seconds)
        {
            Assert.That(entry, Is.Not.Null);
            string id = F<string>(entry, "Id");
            JObject data = JObject.Parse(File.ReadAllText(Source + id.Substring(6) + ".json"));
            JObject hands = (JObject)JObject.Parse(File.ReadAllText(Source + "pack.json"))["hands"];
            int frames = (int)data["frames"]; bool loop = (bool)data["loop"];
            float max = 0f; string worst = null;
            foreach (HumanBodyBones bone in ArmBones())
            {
                string key = char.ToLowerInvariant(bone.ToString()[0]) + bone.ToString().Substring(1);
                if (key.Contains("ThumbProximal")) key = key.Replace("ThumbProximal", "ThumbMetacarpal");
                else if (key.Contains("ThumbIntermediate")) key = key.Replace("ThumbIntermediate", "ThumbProximal");
                JToken track = data["bones"]?[key] ?? hands[key];
                Quaternion q = OriginalSample(track, frames, loop, seconds);
                Quaternion expected = controls ? q : rest[bone].local * (Quaternion.Inverse(rest[bone].global) * q * rest[bone].global);
                float error = Distance(expected, observed[bone]);
                if (error > max) { max = error; worst = bone.ToString(); }
            }
            TestContext.WriteLine("Receiver source=" + id + "; controlRig=" + controls + "; time=" + seconds +
                "; arm/finger bones=" + observed.Count + "; max quaternion component error=" + max + "; worst=" + worst);
            Assert.That(max, Is.LessThan(.00002f), id + "/" + worst + " must retain full source gain after the actual Receiver frame.");
        }
        public void Dispose()
        {
            Object.DestroyImmediate(host);
            var created = new HashSet<Material>();
            var original = new HashSet<Material>(materials.Values.SelectMany(value => value));
            foreach (var pair in materials) if (pair.Key != null)
            { foreach (Material item in pair.Key.sharedMaterials) if (item != null && !original.Contains(item)) created.Add(item); pair.Key.sharedMaterials = pair.Value; }
            foreach (Material item in created) if (!EditorUtility.IsPersistent(item)) Object.DestroyImmediate(item);
            if (runtime.ControlRig != null)
            {
                Object.DestroyImmediate(runtime.ControlRig.ControlRigAnimator.avatar);
                Transform rig = Actor.transform.Find("Runtime Control Rig");
                if (rig != null) Object.DestroyImmediate(rig.gameObject);
            }
            Object.DestroyImmediate(Actor);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
    private static IEnumerable<HumanBodyBones> ArmJoints() => new[] { HumanBodyBones.LeftUpperArm,
        HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand, HumanBodyBones.RightUpperArm,
        HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand };
    private static JArray V(Vector3 value) => new(value.x, value.y, value.z);
    private static JArray Q(Quaternion value) => new(value.x, value.y, value.z, value.w);
    private static IEnumerable<HumanBodyBones> ArmBones()
    {
        foreach (HumanBodyBones id in new[] { HumanBodyBones.LeftShoulder, HumanBodyBones.RightShoulder,
            HumanBodyBones.LeftUpperArm, HumanBodyBones.RightUpperArm, HumanBodyBones.LeftLowerArm,
            HumanBodyBones.RightLowerArm, HumanBodyBones.LeftHand, HumanBodyBones.RightHand }) yield return id;
        for (int id = (int)HumanBodyBones.LeftThumbProximal; id <= (int)HumanBodyBones.RightLittleDistal; id++)
            yield return (HumanBodyBones)id;
    }
    private static Quaternion OriginalSample(JToken token, int frames, bool loop, float seconds)
    {
        if (token == null) return Quaternion.identity;
        float[] values = token.ToObject<float[]>();
        Quaternion At(int i) => new Quaternion(values[i * 4], -values[i * 4 + 1], -values[i * 4 + 2], values[i * 4 + 3]).normalized;
        if (values.Length == 4) return At(0);
        double cursor = (double)seconds * 30d;
        if (loop) cursor = ((cursor % frames) + frames) % frames;
        else cursor = Math.Max(0d, Math.Min(frames - 1d, cursor));
        int a = (int)Math.Floor(cursor), b = loop ? (a + 1) % frames : Math.Min(a + 1, frames - 1);
        return Quaternion.SlerpUnclamped(At(a), At(b), (float)(cursor - a)).normalized;
    }
    private static float Distance(Quaternion a, Quaternion b)
    {
        a = a.normalized; b = b.normalized; float sign = Quaternion.Dot(a, b) < 0f ? -1f : 1f;
        return Mathf.Max(Mathf.Abs(a.x - sign * b.x), Mathf.Abs(a.y - sign * b.y),
            Mathf.Abs(a.z - sign * b.z), Mathf.Abs(a.w - sign * b.w));
    }
}
