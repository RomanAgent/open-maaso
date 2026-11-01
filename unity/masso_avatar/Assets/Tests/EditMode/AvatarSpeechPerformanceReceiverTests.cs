using System;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarSpeechPerformanceReceiverTests
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Invoke(object target, string name, params object[] args) => target.GetType()
        .GetMethod(name, Private | BindingFlags.Public).Invoke(target, args);
    private static T Property<T>(object target, string name) => (T)target.GetType().GetProperty(name).GetValue(target);

    [Test]
    public void ActualClockReceiptAloneNeverStartsMouthOrReplacesItsTimeline()
    {
        using var f = new Fixture();
        Assert.That(f.Sync(Clock(envelope: Envelope())), Is.True);
        Assert.That(f.Get<bool>("lipSyncActive"), Is.False);
        Assert.That(f.Get<float[]>("lipSyncEnvelope"), Is.Null);
        Assert.That(f.Get<float>("mouthOpen"), Is.Zero);
        Assert.That(Property<bool>(f.Clock, "Active"), Is.True);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void MatchingTimelineBindsToActualPositionRegardlessOfReceiptOrder(bool clockFirst)
    {
        using var f = new Fixture();
        float[] envelope = Envelope();
        if (clockFirst) f.Sync(Clock(position: 1000, envelope: envelope));
        f.Lip(envelope);
        if (!clockFirst) f.Sync(Clock(position: 1000, envelope: envelope));
        Assert.That(f.Get<bool>("speechMouthBound"), Is.True);
        f.Set("lipSyncStartedAt", Time.realtimeSinceStartup - 20f);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<bool>("lipSyncActive"), Is.True);
        Assert.That(f.Get<float>("mouthOpen"), Is.GreaterThan(.7f),
            "The known sound cursor is around frame 30, rather than the obsolete enqueue wall time.");
    }

    [Test]
    public void MismatchedEnvelopeDoesNotHijackAnExistingMouthTimeline()
    {
        using var f = new Fixture();
        float[] envelope = Envelope();
        f.Lip(envelope);
        f.Sync(Clock(position: 1000, envelope: Enumerable.Repeat(.4f, 180).ToArray()));
        Assert.That(f.Get<bool>("speechMouthBound"), Is.False);
        f.Set("lipSyncStartedAt", Time.realtimeSinceStartup);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<float>("mouthOpen"), Is.LessThan(.5f),
            "An unrelated clock cannot skip this mouth track to another position.");
    }

    [Test]
    public void PausePreservesTrackClosesMouthAndResumeUsesNonzeroActualPosition()
    {
        using var f = new Fixture();
        float[] envelope = Envelope();
        f.Lip(envelope); f.Sync(Clock(position: 1000, envelope: envelope));
        Assert.That(f.Sync(Clock("pause", sequence: 2, position: 1100)), Is.True);
        Assert.That(f.Get<bool>("lipSyncActive"), Is.False);
        Assert.That(f.Get<float>("mouthOpen"), Is.Zero);
        Assert.That(f.Get<float[]>("lipSyncEnvelope"), Is.SameAs(envelope));
        Assert.That(f.Get<bool>("speechMouthBound"), Is.True);
        f.Set("lipSyncStartedAt", Time.realtimeSinceStartup - 20f);
        Assert.That(f.Sync(Clock("resume", sequence: 3, position: 1500)), Is.True);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<bool>("lipSyncActive"), Is.True);
        Assert.That(f.Get<float>("mouthOpen"), Is.GreaterThan(.7f));
        Assert.That(f.Sync(Clock("stop", sequence: 4, position: 1600)), Is.True);
        Assert.That(f.Get<float[]>("lipSyncEnvelope"), Is.Null);
        Assert.That(f.Get<bool>("speechMouthBound"), Is.False);
        Assert.That(f.Get<float>("mouthOpen"), Is.Zero);
    }

    [Test]
    public void WavPauseStopAndScalarEventsPreserveVisemesUntilActualNonzeroResume()
    {
        using var f = new Fixture();
        float[] envelope = Envelope();
        f.Visemes(envelope);
        Array cues = f.Get<Array>("lipSyncVisemeCues");
        Assert.That(f.Sync(Clock(position: 1000, envelope: envelope)), Is.True);
        Assert.That(f.Sync(Clock("pause", sequence: 2, position: 1100)), Is.True);
        // SpeakingStatus(false) and LipAmplitude(0) follow the pause clock in
        // the existing WAV event bridge. A late scalar must not reopen it.
        f.Call("StopLipSync");
        foreach (float scalar in new[] { 0f, .9f })
        {
            f.Call("SetMouthOpen", scalar);
            Assert.That(f.Get<float>("mouthOpen"), Is.Zero);
            Assert.That(f.Get<float>("mouthVisemeIh"), Is.Zero);
            Assert.That(f.Get<bool>("lipSyncActive"), Is.False);
            Assert.That(f.Get<bool>("lipSyncUsesVisemeTimeline"), Is.True);
            Assert.That(f.Get<float[]>("lipSyncEnvelope"), Is.SameAs(envelope));
            Assert.That(f.Get<Array>("lipSyncVisemeCues"), Is.SameAs(cues));
        }
        f.Set("lipSyncStartedAt", Time.realtimeSinceStartup - 25f);
        Assert.That(f.Sync(Clock("resume", sequence: 3, position: 1500)), Is.True);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<bool>("lipSyncActive"), Is.True);
        Assert.That(f.Get<float>("mouthVisemeIh"), Is.GreaterThan(.7f),
            "Frame 45 resumes its saved /ih/ cue rather than restarting at frame zero's /aa/.");
        Assert.That(f.Get<float>("mouthVisemeAa"), Is.Zero);
        Assert.That(f.Get<Array>("lipSyncVisemeCues"), Is.SameAs(cues));
    }

    [Test]
    public void NonAuthoritativeMatchingStartUsesImmediateLocalMouthAndResumeExcludesPausedTime()
    {
        using var f = new Fixture();
        float[] envelope = Envelope();
        f.Lip(envelope);
        JObject start = Clock(envelope: envelope); start["authoritative"] = false;
        Assert.That(f.Sync(start), Is.True);
        Assert.That(f.Get<bool>("speechMouthBound"), Is.True,
            "Track identity proof is separate from having the first native playback cursor.");
        Assert.That(Property<bool>(f.Clock, "Authoritative"), Is.False);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<float>("mouthOpen"), Is.GreaterThan(.2f),
            "The first sound frame cannot wait for the first 250ms native receipt.");
        f.Set("lipSyncStartedAt", Time.realtimeSinceStartup - 1.2f);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<float>("mouthOpen"), Is.GreaterThan(.7f));
        JObject pause = Clock("pause", sequence: 2, position: 1200); pause["authoritative"] = false;
        Assert.That(f.Sync(pause), Is.True);
        f.Call("StopLipSync"); f.Call("SetMouthOpen", 0f);
        Assert.That(f.Get<float[]>("lipSyncEnvelope"), Is.SameAs(envelope));
        // Model a long paused wall-clock gap without waiting or changing Unity's
        // clock: resume must replace this obsolete local anchor from its cursor.
        f.Set("lipSyncStartedAt", Time.realtimeSinceStartup - 25f);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<float>("mouthOpen"), Is.Zero);
        JObject resume = Clock("resume", sequence: 3, position: 1500); resume["authoritative"] = false;
        Assert.That(f.Sync(resume), Is.True);
        f.Call("UpdateLipSync");
        Assert.That(f.Get<bool>("lipSyncActive"), Is.True);
        Assert.That(f.Get<float>("mouthOpen"), Is.GreaterThan(.7f));
        float localPosition = Time.realtimeSinceStartup - f.Get<float>("lipSyncStartedAt");
        Assert.That(localPosition, Is.InRange(1.5f, 1.6f),
            "Nonauthoritative fallback resumes from 1.5s, excluding the paused wall time.");
    }

    [Test]
    public void LateStopOrWrongIdentityCannotClearTheCurrentAudioMouth()
    {
        using var f = new Fixture();
        float[] envelope = Envelope();
        f.Lip(envelope); f.Sync(Clock(envelope: envelope));
        Assert.That(f.Sync(Clock(id: "audio-b", generation: 9, envelope: envelope)), Is.True);
        Assert.That(f.Sync(Clock("stop", sequence: 99)), Is.False);
        JObject wrongTurn = Clock("stop", id: "audio-b", generation: 9, sequence: 2);
        wrongTurn["turnId"] = "other-turn";
        Assert.That(f.Sync(wrongTurn), Is.False);
        Assert.That(Property<string>(f.Clock, "PlaybackId"), Is.EqualTo("audio-b"));
        Assert.That(f.Get<bool>("lipSyncActive"), Is.True);
        Assert.That(f.Get<float[]>("lipSyncEnvelope"), Is.SameAs(envelope));
    }

    [Test]
    public void TicketedMouthAcceptsClockButRawClockAndPhaseCannotBypassTheOwner()
    {
        using var f = new Fixture();
        f.Set("avatarArbiterOwnerToken", new string('A', 43));
        f.Set("avatarArbiterAccountGeneration", 7L);
        f.Set("avatarArbiterRendererGeneration", 1L);
        f.Set("avatarArbiterRendererGenerationHighWater", 1L);
        f.Dispatch("syncSpeechPlaybackClock", Clock(envelope: Envelope()));
        f.Dispatch("setConversationPhase", new JObject { ["phase"] = "listening", ["sequence"] = 1 });
        Assert.That(Property<bool>(f.Clock, "Active"), Is.False);
        Assert.That(f.Get<bool>("conversationHintsEnabled"), Is.False);
        string rendererPayload = new JObject { ["channel"] = "mouth", ["playbackClock"] = Clock(envelope: Envelope()) }
            .ToString(Formatting.None);
        f.Call("DispatchAvatarArbiterCommand", Arbiter(rendererPayload, 1));
        Assert.That(Property<bool>(f.Clock, "Active"), Is.True);
        Assert.That(f.Get<bool>("lipSyncActive"), Is.False);
        f.Dispatch("syncSpeechPlaybackClock", Clock("stop", sequence: 2));
        Assert.That(Property<bool>(f.Clock, "Active"), Is.True);
        f.Call("AdvanceSpeechPerformance", Time.realtimeSinceStartup + .2f);
        Assert.That(Property<string>(f.Get<object>("speechGestureAnimator"), "ActiveId"), Is.Null,
            "A mouth ticket is not a body-gesture lease under enforce authority.");
    }

    [Test]
    public void CanonicalMouthClockRequiresStrictNestedPayload()
    {
        Type receiver = A("UnityAvatarCommandReceiver");
        Type payload = receiver.GetNestedType("AvatarArbiterRendererPayload", BindingFlags.NonPublic);
        MethodInfo validate = receiver.GetMethod("ValidateAvatarArbiterRendererPayload", BindingFlags.Static | BindingFlags.NonPublic);
        string nested = Clock(envelope: Envelope()).ToString(Formatting.None);
        string valid = "{\"channel\":\"mouth\",\"playbackClock\":" + nested + "}";
        object value = JsonUtility.FromJson(valid, payload);
        Assert.That(validate.Invoke(null, new[] { value, valid }), Is.EqualTo(true));
        foreach (string invalid in new[]
        {
            valid.Insert(1, "\"extra\":1,"),
            valid.Insert(1, "\"channel\":\"mouth\","),
            valid.Replace("\"protocolVersion\":1", "\"protocolVersion\":\"1\""),
            valid.Replace("\"generation\":8", "\"generation\":\"8\""),
            valid.Replace("\"state\":\"start\"", "\"state\":\"start\",\"unknown\":true"),
            valid.Replace("\"state\":\"start\"", "\"state\":\"start\",\"state\":\"pause\""),
            valid.Replace("\"authoritative\":true", "\"authoritative\":1"),
        }) Assert.That(validate.Invoke(null, new[] { value, invalid }), Is.EqualTo(false), invalid);
    }

    [TestCase("worldLocomotionActive")]
    [TestCase("avatarLeasedToWorld")]
    [TestCase("bodyPoseTransitionActive")]
    [TestCase("hostBackgroundWorkPaused")]
    [TestCase("hidden")]
    [TestCase("explicit")]
    public void RealOwnershipAndExplicitBodyHoldStopAmbientSpeechLayer(string owner)
    {
        using var f = new Fixture();
        f.Sync(Clock(envelope: Enumerable.Repeat(.2f, 180).ToArray()));
        float now = Time.realtimeSinceStartup;
        f.Call("AdvanceSpeechPerformance", now);
        f.Call("AdvanceSpeechPerformance", now + .2f);
        f.Animator.Update(0f);
        string activeId = Property<string>(f.Get<object>("speechGestureAnimator"), "ActiveId");
        object library = f.Get<object>("performanceLibrary");
        object entry = ((Array)library.GetType().GetField("Entries").GetValue(library)).Cast<object>()
            .SingleOrDefault(candidate => (string)candidate.GetType().GetField("Id").GetValue(candidate) == activeId);
        Assert.That(entry, Is.Not.Null, "Speech must own an actual installed talk-loop entry before testing its interruption.");
        Assert.That(entry.GetType().GetField("Layer").GetValue(entry), Is.EqualTo("talk"));
        Assert.That(entry.GetType().GetField("Loop").GetValue(entry), Is.EqualTo(true));
        Assert.That(entry.GetType().GetField("UpperBody").GetValue(entry), Is.EqualTo(true));
        Assert.That(new[] { "calm", "animated", "excited" }.Contains((string)entry.GetType().GetField("Energy").GetValue(entry)), Is.True);
        if (owner == "hidden") Invoke(f.Get<object>("localVisibility"), "SetVisible", false);
        else if (owner == "explicit") f.Call("ApplyPrimitive", "wave", .8f);
        else f.Set(owner, true);
        Assert.That(f.Sync(Clock("update", sequence: 2, position: 300)), Is.True);
        float blockedAt = Time.realtimeSinceStartup;
        Assert.That(Invoke(f.Clock, "IsPlaying", blockedAt), Is.EqualTo(true));
        f.Call("AdvanceSpeechPerformance", blockedAt);
        Assert.That(Property<string>(f.Get<object>("speechGestureAnimator"), "ActiveId"), Is.Null);
    }

    [TestCase("phone")]
    [TestCase("desk")]
    public void ActualPhoneAndDeskControllersTakePriorityOverSpeechGestures(string task)
    {
        using var f = new Fixture();
        f.Sync(Clock(envelope: Enumerable.Repeat(.2f, 180).ToArray()));
        float now = Time.realtimeSinceStartup;
        f.Call("AdvanceSpeechPerformance", now);
        f.Call("AdvanceSpeechPerformance", now + .2f);
        f.Animator.Update(0f);
        string activeId = Property<string>(f.Get<object>("speechGestureAnimator"), "ActiveId");
        object library = f.Get<object>("performanceLibrary");
        object entry = ((Array)library.GetType().GetField("Entries").GetValue(library)).Cast<object>()
            .SingleOrDefault(candidate => (string)candidate.GetType().GetField("Id").GetValue(candidate) == activeId);
        Assert.That(entry, Is.Not.Null, "Speech must own an actual installed talk-loop entry before the phone/desk takes over.");
        Assert.That(entry.GetType().GetField("Layer").GetValue(entry), Is.EqualTo("talk"));
        Assert.That(entry.GetType().GetField("Loop").GetValue(entry), Is.EqualTo(true));
        Assert.That(entry.GetType().GetField("UpperBody").GetValue(entry), Is.EqualTo(true));
        Assert.That(new[] { "calm", "animated", "excited" }.Contains((string)entry.GetType().GetField("Energy").GetValue(entry)), Is.True);
        if (task == "phone")
        {
            object command = JsonUtility.FromJson(new JObject
            {
                ["requestId"] = "speech-test-phone", ["interactionId"] = "phone-query",
                ["phase"] = "reading", ["sequence"] = 1,
                ["expiresAtMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 5000,
            }.ToString(Formatting.None), A("AvatarPhoneCommand"));
            f.Call("SetPhoneInteraction", command);
            Assert.That(Property<bool>(f.Get<object>("phoneInteraction"), "OwnsHands"), Is.True);
        }
        else
        {
            Assert.That(f.BeginDeskSession(), Is.True);
            Assert.That(Property<bool>(f.Get<object>("furniturePose"), "Active"), Is.True);
        }
        Vector3 position = f.Avatar.transform.position;
        Assert.That(f.Sync(Clock("update", sequence: 2, position: 300)), Is.True);
        float blockedAt = Time.realtimeSinceStartup;
        Assert.That(Invoke(f.Clock, "IsPlaying", blockedAt), Is.EqualTo(true));
        f.Call("AdvanceSpeechPerformance", blockedAt);
        Assert.That(Property<string>(f.Get<object>("speechGestureAnimator"), "ActiveId"), Is.Null);
        Assert.That(f.Avatar.transform.position, Is.EqualTo(position));
    }

    [Test]
    public void PhaseHintsAreStrictOrderedAndReachListeningAndIdleAnimatorStates()
    {
        using var f = new Fixture();
        f.Call("SetConversationPhase", "{\"phase\":\"listening\",\"sequence\":1}");
        // The first accepted hint can load the native motion pack. Measure the
        // hysteresis from its receipt rather than from before that work.
        float now = Time.realtimeSinceStartup;
        f.Call("AdvanceSpeechPerformance", now + .36f);
        string listen = Property<string>(f.Get<object>("annieMotion"), "ActiveId");
        Assert.That(listen, Is.EqualTo("idle_shrug"));
        f.Animator.Update(.2f);
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).IsName("Base Layer." + listen) ||
            (f.Animator.IsInTransition(0) && f.Animator.GetNextAnimatorStateInfo(0).IsName("Base Layer." + listen)), Is.True);
        foreach (string invalid in new[]
        {
            "{\"phase\":\"stopped\",\"sequence\":1}",
            "{\"phase\":\"stopped\",\"sequence\":0}",
            "{\"phase\":\"stopped\",\"sequence\":2.0}",
            "{\"phase\":\"stopped\",\"sequence\":\"2\"}",
            "{\"phase\":\"stopped\",\"sequence\":2,\"extra\":true}",
            "{\"phase\":\"stopped\",\"phase\":\"thinking\",\"sequence\":2}",
            "{\"phase\":\"invalid\",\"sequence\":2}",
        }) f.Call("SetConversationPhase", invalid);
        Assert.That(f.Get<long>("conversationPhaseSequence"), Is.EqualTo(1));
        f.Call("AdvanceSpeechPerformance", now + .5f);
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo(listen));
        f.Call("SetConversationPhase", "{\"phase\":\"stopped\",\"sequence\":2}");
        f.Call("AdvanceSpeechPerformance", now + .9f);
        string idle = Property<string>(f.Get<object>("annieMotion"), "ActiveId");
        Assert.That(idle, Is.EqualTo("idle_shrug"));
        Assert.That(f.Get<long>("conversationPhaseSequence"), Is.EqualTo(2));
    }

    [TestCase("annie_idle_c", false)]
    [TestCase("annie_idle_c", true)]
    [TestCase("annie_fidget_clasp", false)]
    [TestCase("annie_fidget_clasp", true)]
    public void ActualTtsStartImmediatelyReleasesPolicyInterludeRegardlessOfAssetCategory(string expected, bool phaseFirst)
    {
        using var f = new Fixture();
        Assert.That(f.Call("EnsureSpeechPerformance"), Is.True);
        f.Set("conversationHintsEnabled", true);
        object policy = f.Get<object>("conversationMotion");
        object decision = null;
        for (float at = .4f; at < 600f; at += 1f)
        {
            object next = Invoke(policy, "Advance", at, false, false);
            if (next == null) continue;
            string id = (string)next.GetType().GetField("ClipId").GetValue(next);
            if (id == expected) { decision = next; break; }
            bool fidget = (bool)next.GetType().GetField("IsFidget").GetValue(next);
            Invoke(policy, "NotifyPlayed", id, at, 4f, !fidget);
        }
        Assert.That(decision, Is.Not.Null, "Acquire the interlude through the real policy before testing TTS takeover.");
        float now = Time.realtimeSinceStartup;
        // Rebase the synthetic search clock to the actual native receipt clock;
        // only time origins change, never the admitted pose or its ownership.
        policy.GetType().GetField("lastNow", Private).SetValue(policy, now);
        Invoke(policy, "NotifyPlayed", expected, now, 6f, expected == "annie_idle_c");
        Assert.That(decision.GetType().GetField("IsFidget").GetValue(decision), Is.EqualTo(true));
        object player = f.Get<object>("annieMotion");
        Assert.That(Invoke(player, "TryPlayAtPhase", f.Animator, expected, now, false, 0f, 0f), Is.True);
        f.Set("conversationPolicyClip", expected);
        f.Animator.Update(.2f);
        if (phaseFirst)
        {
            f.Call("SetConversationPhase", "{\"phase\":\"speaking\",\"sequence\":1}");
            // Elapse presentation hysteresis without waiting or rolling back
            // the monotonic clock. The real phase command remains authoritative.
            policy.GetType().GetField("desiredSince", Private).SetValue(policy, Time.realtimeSinceStartup - .4f);
            f.Call("AdvanceSpeechPerformance", Time.realtimeSinceStartup);
            Assert.That(Property<string>(policy, "ActiveId"), Is.Null);
            Assert.That(Property<string>(player, "ActiveId"), Is.EqualTo(expected),
                "A phase hint can retire policy bookkeeping before the player is released.");
        }

        Assert.That(f.Sync(Clock(envelope: Envelope())), Is.True);
        Assert.That(Property<string>(player, "ActiveId"), Is.Null,
            "A looping idle used as an interlude must release as promptly as a fidget asset.");
        f.Animator.Update(.3f);
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).IsName("Base Layer.idle_shrug"), Is.True);
    }

    [Test]
    public void ResetRetiresCurrentClockAndReleasesAmbientSpeechState()
    {
        using var f = new Fixture();
        f.Lip(Envelope()); f.Sync(Clock(envelope: Envelope()));
        f.Call("SetConversationPhase", "{\"phase\":\"listening\",\"sequence\":3}");
        f.Call("ResetSpeechPerformance");
        Assert.That(Property<bool>(f.Clock, "Active"), Is.False);
        Assert.That(f.Get<bool>("speechMouthBound"), Is.False);
        Assert.That(f.Get<bool>("conversationHintsEnabled"), Is.False);
        Assert.That(f.Get<long>("speechGestureEpoch"), Is.EqualTo(-1));
        Assert.That(Property<string>(f.Get<object>("speechGestureAnimator"), "ActiveId"), Is.Null);
        Assert.That(f.Sync(Clock(generation: 9, envelope: Envelope())), Is.False,
            "A known retired playback ID is not revived by a later generation.");
    }

    private static float[] Envelope()
    {
        float[] result = Enumerable.Repeat(.1f, 180).ToArray();
        for (int i = 25; i < 80; i++) result[i] = .85f;
        return result;
    }

    private static JObject Clock(string state = "start", string id = "audio-a", long generation = 8,
        long sequence = 1, long position = 0, float[] envelope = null)
    {
        var json = new JObject
        {
            ["protocolVersion"] = 1, ["playbackId"] = id, ["generation"] = generation,
            ["turnId"] = "turn-1", ["utteranceId"] = "utterance-1", ["sequence"] = sequence,
            ["state"] = state, ["positionMs"] = position, ["durationMs"] = 6000,
            ["source"] = "wav", ["authoritative"] = true,
        };
        if (envelope != null) { json["envelope"] = JArray.FromObject(envelope); json["frameRate"] = 30; }
        return json;
    }

    private static string Arbiter(string payload, long ticket)
    {
        using var sha = SHA256.Create();
        string digest = string.Concat(sha.ComputeHash(Encoding.UTF8.GetBytes(payload)).Select(x => x.ToString("x2")));
        return new JObject
        {
            ["protocolVersion"] = 1, ["requestId"] = "speech-ticket-" + ticket, ["ticket"] = ticket,
            ["rendererId"] = "renderer-instance-1", ["ownerToken"] = new string('A', 43),
            ["commitToken"] = new string('C', 43), ["accountGeneration"] = 7, ["rendererGeneration"] = 1,
            ["channel"] = "mouth", ["fingerprint"] = "0123456789abcdef", ["payloadJson"] = payload,
            ["payloadSha256"] = digest, ["deadlineEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000,
            ["clearsChannel"] = false,
        }.ToString(Formatting.None);
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Avatar;
        public readonly Animator Animator;
        private readonly GameObject host;
        private GameObject room;
        private readonly Component receiver;
        public object Clock => Get<object>("speechPlaybackClock");
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator = Avatar.GetComponentInChildren<Animator>(true);
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.applyRootMotion = false; Animator.Rebind(); Animator.Update(0f);
            host = new GameObject("Speech performance receiver test");
            receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            Set("avatarRoot", Avatar.transform); Set("animator", Animator);
            Invoke(Get<object>("localVisibility"), "SetVisible", true);
        }
        public T Get<T>(string name) => (T)receiver.GetType().GetField(name, Private).GetValue(receiver);
        public void Set(string name, object value) => receiver.GetType().GetField(name, Private).SetValue(receiver, value);
        public object Call(string name, params object[] args) => Invoke(receiver, name, args);
        public bool Sync(JObject packet)
        {
            object value = packet.ToObject(A("AvatarSpeechPlaybackClockPacket"));
            return (bool)Call("SyncSpeechPlaybackClock", value);
        }
        public void Lip(float[] envelope)
        {
            Type commandType = receiver.GetType().GetNestedType("LipSyncCommand", BindingFlags.NonPublic);
            object command = Activator.CreateInstance(commandType);
            commandType.GetField("envelope").SetValue(command, envelope);
            commandType.GetField("frameRate").SetValue(command, 30);
            Call("StartLipSync", command);
        }
        public void Visemes(float[] envelope)
        {
            Type commandType = receiver.GetType().GetNestedType("LipSyncCommand", BindingFlags.NonPublic);
            object command = JsonUtility.FromJson(new JObject
            {
                ["format"] = "vrm_viseme_v2", ["envelope"] = JArray.FromObject(envelope), ["frameRate"] = 30,
                ["cues"] = new JArray(new JObject { ["frame"] = 0, ["viseme"] = "aa" },
                    new JObject { ["frame"] = 30, ["viseme"] = "ih" },
                    new JObject { ["frame"] = 80, ["viseme"] = "ou" }),
            }.ToString(Formatting.None), commandType);
            // Preserve the same array object to verify pause does not erase it.
            commandType.GetField("envelope").SetValue(command, envelope);
            Call("StartVisemeTimeline", command);
        }
        public void Dispatch(string method, JObject json) => Call("Dispatch", new JObject
        { ["method"] = method, ["json"] = json.ToString(Formatting.None) }.ToString(Formatting.None));
        public bool BeginDeskSession()
        {
            room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
            Component rig = room.GetComponentInChildren(A("AvatarFurnitureRig"));
            Assert.That(rig, Is.Not.Null, "Desk ownership uses the actual authored coastal room anchors.");
            return (bool)Invoke(Get<object>("furniturePose"), "BeginWorkSession", new string('d', 64),
                Avatar.transform, Animator, rig, Time.realtimeSinceStartup,
                (Action<string>)(_ => {}), (Action<bool>)(active => Call("SetWorldLocomotion", active)));
        }
        public void Dispose()
        {
            Invoke(Get<object>("furniturePose"), "Reset", false);
            Object.DestroyImmediate(host);
            Object.DestroyImmediate(Avatar);
            if (room != null) Object.DestroyImmediate(room);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}
