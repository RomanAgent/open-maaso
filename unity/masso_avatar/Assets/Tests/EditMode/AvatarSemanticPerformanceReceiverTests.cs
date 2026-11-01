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

public sealed class AvatarSemanticPerformanceReceiverTests
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Invoke(object target, string name, params object[] args) => target.GetType().GetMethod(name, Private | BindingFlags.Public).Invoke(target, args);
    private static T Property<T>(object value, string name) => (T)value.GetType().GetProperty(name).GetValue(value);
    private static long Utc => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    [TestCase("speech")]
    [TestCase("explain")]
    [TestCase("palms_open")]
    [TestCase("point_small")]
    [TestCase("chest")]
    public void CanonicalSemanticBodyTicketQueuesStyleWithoutStartingAClipOrAnExplicitHold(string gesture)
    {
        using var f = new Fixture(); f.Enforce();
        string body = Cue(gesture, "gentle", "curious", .55f).ToString(Formatting.None);
        Assert.That(Validate(body), Is.True);
        f.Ticket(body, 1);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(true));
        Assert.That(f.Get<string>("performanceCueGesture"), Is.EqualTo(gesture));
        Assert.That(f.Get<string>("performanceCueEnergy"), Is.EqualTo("gentle"));
        Assert.That(f.Get<string>("performanceCueEmotion"), Is.EqualTo("curious"));
        Assert.That(f.Get<float>("performanceCueIntensity"), Is.EqualTo(.55f));
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.Zero, "A speech cue is not a whole-body action hold.");
        Assert.That(f.SpeechClip, Is.Null);
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.Null);
        f.Advance();
        Assert.That(f.SpeechClip, Is.Null, "A semantic cue cannot fabricate playback before actual audio exists.");
    }

    [Test]
    public void CanonicalPerformanceWireRequiresItsExactLeaseExpiryAndRejectsInvalidOrMixedMetadata()
    {
        string valid = Cue().ToString(Formatting.None);
        Assert.That(Validate(valid), Is.True);
        foreach (JObject invalid in new[] {
            Cue("annie_g_offer_r"), Cue("work_desk"), Cue(energy: "animated"), Cue(energy: "calm"),
            Cue(emotion: "invented"), Cue(intensity: -1f), Cue(intensity: 1.1f) })
            Assert.That(Validate(invalid.ToString(Formatting.None)), Is.False, invalid.ToString(Formatting.None));
        JObject mixed = Cue(); mixed["workSessionId"] = new string('d', 64); mixed["workPhase"] = "start";
        JObject extra = Cue(); extra["durationMs"] = 1000;
        JObject wrong = Cue(); wrong["intensity"] = "0.5";
        JObject missingExpiry = Cue(); missingExpiry.Remove("leaseExpiresAtEpochMs");
        JObject stringExpiry = Cue(); stringExpiry["leaseExpiresAtEpochMs"] = (Utc + 3500).ToString();
        JObject expired = Cue(); expired["leaseExpiresAtEpochMs"] = Utc - 1;
        JObject excessive = Cue(); excessive["leaseExpiresAtEpochMs"] = Utc + 60000;
        foreach (string invalid in new[] { mixed.ToString(Formatting.None), extra.ToString(Formatting.None), wrong.ToString(Formatting.None),
            missingExpiry.ToString(Formatting.None), stringExpiry.ToString(Formatting.None), expired.ToString(Formatting.None), excessive.ToString(Formatting.None),
            valid.Insert(1, "\"energy\":\"high\","), valid.Insert(1, "\"leaseExpiresAtEpochMs\":" + (Utc + 3500) + ","),
            valid.Replace("\"intensity\":0.65", "\"intensity\":null") })
            Assert.That(Validate(invalid), Is.False, invalid);
    }

    [Test]
    public void OnlyAnAdmittedBodyCueEnablesTheAcousticLayerUnderEnforceAndStyleWaitsForRealAudio()
    {
        using var f = new Fixture(); f.Enforce();
        Assert.That(f.Sync(Clock()), Is.True); f.Advance();
        Assert.That(f.SpeechClip, Is.Null, "The mouth clock alone is not a body lease.");
        f.Ticket(Cue("speech", "high", "excited", .8f).ToString(Formatting.None), 1);
        // The first probe stepped 150ms ahead. Supply a new authoritative
        // cursor receipt rather than rewinding the scheduler to wall time.
        Assert.That(f.Sync(Clock("update", sequence: 2, position: 300)), Is.True);
        f.Advance();
        Assert.That(f.SpeechClip, Does.StartWith("annie_talk_"));
        Assert.That(Property<string>(f.Get<object>("speechGestures"), "Energy"), Is.EqualTo("high"));
        Assert.That(Property<string>(f.Get<object>("speechGestures"), "Emotion"), Is.EqualTo("excited"));
        Assert.That(f.Get<long>("performanceCueAppliedEpoch"), Is.EqualTo(f.Get<long>("speechGestureEpoch")));
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.Zero);
    }

    [Test]
    public void SameTurnChunksRetainStyleButDoNotReplayTheSemanticGestureAndAnotherTurnRetiresIt()
    {
        using var f = new Fixture(); f.Enforce();
        Assert.That(f.Queue("point_small", "curious", "gentle", .45f, 1, Utc + 4000), Is.True);
        Assert.That(f.Sync(Clock()), Is.True); f.Advance();
        long firstEpoch = f.Get<long>("performanceCueAppliedEpoch");
        Assert.That(firstEpoch, Is.GreaterThanOrEqualTo(0));
        Assert.That(f.Get<string>("performanceCueTurnId"), Is.EqualTo("turn-1"));
        Assert.That(f.Get<bool>("performanceCueSemanticConsumed"), Is.True);
        Assert.That(Property<string>(f.Get<object>("speechGestures"), "Energy"), Is.EqualTo("calm"));
        Assert.That(f.Sync(Clock("stop", sequence: 2)), Is.True);
        Assert.That(f.Sync(Clock(id: "audio-b", generation: 9, utterance: "utterance-2")), Is.True); f.Advance();
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(true));
        Assert.That(f.Get<long>("performanceCueAppliedEpoch"), Is.GreaterThan(firstEpoch));
        Assert.That(f.Get<bool>("performanceCueSemanticConsumed"), Is.True);
        Assert.That(Property<string>(f.Get<object>("speechGestures"), "Emotion"), Is.EqualTo("curious"));
        Assert.That(Property<string>(f.Get<object>("speechGestures"), "Energy"), Is.EqualTo("calm"));
        Assert.That(f.Sync(Clock(id: "audio-c", generation: 10, turn: "turn-2", utterance: "utterance-3")), Is.True);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        f.Advance(); Assert.That(f.SpeechClip, Is.Null, "The next turn's mouth cannot inherit an expired body authorization.");
    }

    [TestCase("explain")]
    [TestCase("palms_open")]
    public void ReplacingAnAdmittedSpeakingCueKeepsTheInFlightStroke(string nextGesture)
    {
        using var f = new Fixture(); f.Enforce();
        f.Ticket(Cue("explain", "gentle").ToString(Formatting.None), 1);
        JObject clock = Clock();
        float[] track = Enumerable.Repeat(.2f, 600).ToArray();
        for (int i = 100; i < 108; i++) track[i] = .8f;
        clock["envelope"] = JArray.FromObject(track); clock["frameRate"] = 100;
        Assert.That(f.Sync(clock), Is.True);
        f.Call("AdvanceSpeechPerformance", Time.realtimeSinceStartup);
        object scheduler = f.Get<object>("speechGestures");
        long epoch = f.Get<long>("speechGestureEpoch");
        // Supply controlled audio positions after the real receiver admission.
        // Wall-clock sleeps and speculative native-clock prediction are not
        // involved in testing whether a cue mutation restarts an active stroke.
        object before = null;
        for (int frame = 1; frame <= 110; frame++)
            before = Invoke(scheduler, "Tick", epoch, frame / 100f, true, false);
        object entry = before.GetType().GetField("Entry").GetValue(before);
        Assert.That(entry.GetType().GetField("Id").GetValue(entry), Is.EqualTo("annie_g_offer_r"));
        Assert.That(before.GetType().GetField("Phase").GetValue(before).ToString(), Is.EqualTo("Stroke"));
        float seconds = (float)before.GetType().GetField("ClipSeconds").GetValue(before);

        f.Ticket(Cue(nextGesture, "high", "excited", .8f).ToString(Formatting.None), 2);
        f.Call("ApplyPendingSpeechPerformanceCue");
        object after = Invoke(scheduler, "Tick", epoch, 1.11f, true, false);
        Assert.That(after.GetType().GetField("Entry").GetValue(after), Is.SameAs(entry),
            "A fresh valid speaking cue must queue its next gesture, not retract the already raised arm.");
        Assert.That((float)after.GetType().GetField("ClipSeconds").GetValue(after),
            Is.EqualTo(seconds + .01f).Within(.001f), "The active clip cursor must not restart at a cue boundary.");
        Assert.That(Property<long>(scheduler, "CueSequence"), Is.EqualTo(2));
        Assert.That(Property<string>(scheduler, "Energy"), Is.EqualTo("high"));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void SpeakingCueRenewalPreservesRestAttackOnlyWhileItsOldLeaseIsLive(bool expired)
    {
        using var f = new Fixture(); f.Enforce();
        f.Ticket(Cue().ToString(Formatting.None), 1);
        Assert.That(f.Sync(Clock()), Is.True);
        f.Call("AdvanceSpeechPerformance", Time.realtimeSinceStartup);
        object scheduler = f.Get<object>("speechGestures");
        long epoch = f.Get<long>("speechGestureEpoch");
        object before = null;
        for (int frame = 1; frame <= 50; frame++)
            before = Invoke(scheduler, "Tick", epoch, frame / 100f, true, false);
        Assert.That((float)before.GetType().GetField("Weight").GetValue(before), Is.EqualTo(1f));
        if (expired) f.Set("performanceCueDeadlineMs", Utc - 1);

        f.Ticket(Cue().ToString(Formatting.None), 2);
        f.Call("ApplyPendingSpeechPerformanceCue");
        object after = Invoke(scheduler, "Tick", epoch, .51f, true, false);
        float weight = (float)after.GetType().GetField("Weight").GetValue(after);
        if (expired)
            Assert.That(weight, Is.LessThan(.2f), "An expired lease must still release before a newly authorized episode.");
        else
            Assert.That(weight, Is.EqualTo(1f), "Renewing a live body cue must not restart the phrase's rest attack.");
        Assert.That(Property<long>(scheduler, "CueSequence"), Is.EqualTo(2));
    }

    [Test]
    public void CueExpiryIsBoundedAndCannotBecomeAQueuedReplayAfterTaskOrClockPause()
    {
        using var f = new Fixture(); f.Enforce();
        Assert.That(f.Queue("speech", "neutral", "moderate", .5f, 1, Utc - 1), Is.False);
        long before = Utc;
        Assert.That(f.Queue("speech", "neutral", "moderate", .5f, 2, before + 60000), Is.True);
        Assert.That(f.Get<long>("performanceCueDeadlineMs"), Is.LessThanOrEqualTo(Utc + 5000));
        f.Set("performanceCueDeadlineMs", Utc - 1);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        Assert.That(f.Queue("speech", "neutral", "moderate", .5f, 3, Utc + 4000), Is.True);
        f.Sync(Clock()); f.Advance();
        Assert.That(f.Sync(Clock("pause", sequence: 2, position: 200)), Is.True);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        Assert.That(f.Sync(Clock("resume", sequence: 3, position: 300)), Is.True); f.Advance();
        Assert.That(f.SpeechClip, Is.Null, "Resuming audio is not permission to revive a retired body cue.");
    }

    [TestCase("worldLocomotionActive")]
    [TestCase("avatarLeasedToWorld")]
    [TestCase("bodyPoseTransitionActive")]
    [TestCase("hostBackgroundWorkPaused")]
    [TestCase("hidden")]
    public void TaskAndPresentationTakeoverRetireTheCueAndUnblockingNeverReplaysIt(string gate)
    {
        using var f = new Fixture(); f.Enforce();
        f.Queue("explain", "neutral", "moderate", .6f, 1, Utc + 4000); f.Sync(Clock()); f.Advance();
        Assert.That(f.SpeechClip, Is.Not.Null);
        if (gate == "hidden") Invoke(f.Get<object>("localVisibility"), "SetVisible", false); else f.Set(gate, true);
        f.Advance();
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false)); Assert.That(f.SpeechClip, Is.Null);
        if (gate == "hidden") Invoke(f.Get<object>("localVisibility"), "SetVisible", true); else f.Set(gate, false);
        f.Advance(); Assert.That(f.SpeechClip, Is.Null);
    }

    [Test]
    public void SoftBodyClearCannotResetAnActiveDeskOrANewerExplicitBodyAction()
    {
        using var f = new Fixture(); f.Enforce();
        f.Ticket(Cue().ToString(Formatting.None), 1);
        Assert.That(f.BeginDesk(), Is.True);
        string session = Property<string>(f.Get<object>("furniturePose"), "WorkSessionId");
        f.Ticket("{\"channel\":\"bodyGesture\",\"clear\":true}", 2, true);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        Assert.That(Property<bool>(f.Get<object>("furniturePose"), "Active"), Is.True);
        Assert.That(Property<string>(f.Get<object>("furniturePose"), "WorkSessionId"), Is.EqualTo(session));
        Invoke(f.Get<object>("furniturePose"), "Reset", false);
        f.Set("worldLocomotionActive", false); f.Set("bodyPoseTransitionActive", false);
        f.Ticket(Cue().ToString(Formatting.None), 3);
        f.Call("ApplyPrimitive", "wave", .8f);
        float hold = f.Get<float>("actionPoseHoldUntil"); string body = Property<string>(f.Get<object>("annieMotion"), "ActiveId");
        Assert.That(hold, Is.GreaterThan(Time.realtimeSinceStartup)); Assert.That(body, Is.Not.Null);
        f.Ticket("{\"channel\":\"bodyGesture\",\"clear\":true}", 4, true);
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.EqualTo(hold));
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo(body));
    }

    [TestCase(1f)]
    [TestCase(0f)]
    public void LegacyDramaticAmplitudeDoesNotOverrideTheBoundedSemanticIntensity(float intensity)
    {
        using var f = new Fixture();
        f.LegacyPrimitive("explain", 1.15f, intensity);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(true));
        Assert.That(f.Get<float>("performanceCueIntensity"), Is.EqualTo(intensity),
            "Legacy dramatic amplitude and semantic speech intensity have different ranges; zero is intentional.");
        Assert.That(f.Get<string>("performanceCueEnergy"), Is.EqualTo("high"));
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.Zero);
    }

    [Test]
    public void CanonicalFullBodyStyleKeepsExplicitWaveSemanticsInsteadOfQueuingSpeech()
    {
        using var f = new Fixture(); f.Enforce();
        string body = Cue("wave", "high", "happy", .9f).ToString(Formatting.None);
        Assert.That(Validate(body), Is.True);
        f.Ticket(body, 1);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.GreaterThan(Time.realtimeSinceStartup));
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo("annie_wave"));
    }

    [Test]
    public void GazeKeepsArmClearanceAvailableWhileTheReceiverReleasesHeadMicroMotion()
    {
        using var f = new Fixture();
        object micro = f.Get<object>("conversationalMicroMotion"), guard = f.Get<object>("freeGestureCollision");
        Invoke(micro, "Bind", f.Animator);
        Assert.That(Invoke(guard, "Bind", f.Avatar.transform, f.Animator), Is.EqualTo(true),
            Property<string>(guard, "BindingDiagnostic"));
        float now = Time.realtimeSinceStartup;
        Invoke(micro, "SetPhase", "listening", now - .8f); Invoke(micro, "Apply", now, true);
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.True);
        f.Set("gazeActive", true);
        f.Call("AdvancePresentationFrame", now, Utc);
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.False,
            "Actual receiver orchestration must pass a stricter head-micro gate while gaze is active.");
        Assert.That(Property<bool>(guard, "HasOwnedWrites"), Is.False,
            "An authored idle/listen cycle must not acquire free-speech collision IK.");

        Assert.That(f.Call("EnsureSpeechPerformance"), Is.EqualTo(true));
        object library = f.Get<object>("performanceLibrary"), gestureAnimator = f.Get<object>("speechGestureAnimator");
        var args = new object[] { "annie_g_offer_r", null };
        Assert.That(Invoke(library, "TryGet", args), Is.EqualTo(true));
        object entry = args[1];
        Assert.That((bool)entry.GetType().GetField("Contact").GetValue(entry), Is.False);
        Type scheduler = A("AvatarSpeechGestureScheduler");
        object stroke = Enum.Parse(scheduler.GetNestedType("GesturePhase", BindingFlags.Public), "Stroke");
        object sample = Activator.CreateInstance(scheduler.GetNestedType("Sample", BindingFlags.Public),
            new object[] { entry, .7f, .65f, stroke, 0, 0f });
        Assert.That(Invoke(gestureAnimator, "Apply", f.Animator, sample, false), Is.EqualTo(true));
        f.Animator.Update(0f);
        Transform upper = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm), lower = f.Animator.GetBoneTransform(HumanBodyBones.LeftLowerArm), hand = f.Animator.GetBoneTransform(HumanBodyBones.LeftHand);
        Vector3 target = Vector3.Lerp(Property<Vector3>(guard, "TorsoStart"), Property<Vector3>(guard, "TorsoEnd"), .7f);
        Assert.That(A("AvatarArmIk").GetMethod("Apply").Invoke(null,
            new object[] { upper, lower, hand, target, -f.Avatar.transform.right, 180f }), Is.EqualTo(true));
        float before = (float)Invoke(guard, "ArmClearance", true);
        Assert.That(before, Is.LessThan(-.01f));
        Assert.That(f.Call("FreeConversationMotionAllowed", now), Is.EqualTo(true),
            "Gaze ownership must not disable clearance for an active non-contact speech pose.");
        for (int frame = 1; frame <= 36; frame++)
        {
            f.Call("Update");
            f.Call("AdvancePresentationFrame", now + frame / 60f, Utc + (long)(frame * 1000f / 60f));
            Assert.That(f.SpeechClip, Is.EqualTo("annie_g_offer_r"), "The clearance guard must not stop/restart speech.");
        }
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.False);
        Assert.That(Property<int>(guard, "CorrectedArms"), Is.GreaterThanOrEqualTo(1));
        Assert.That((float)Invoke(guard, "ArmClearance", true), Is.GreaterThan(before + .005f));
    }

    [Test]
    public void SoftBodyAcknowledgementAndClearDoNotCancelAnOpportunisticEntrance()
    {
        using var f = new Fixture(); f.Enforce(); f.BeginPresence();
        object presence = f.Get<object>("presenceTransition");
        Assert.That(Property<bool>(presence, "OwnsPresentation"), Is.True);
        Vector3 position = f.Avatar.transform.position;
        f.Ticket(Cue().ToString(Formatting.None), 1);
        Assert.That(Property<bool>(presence, "OwnsPresentation"), Is.True);
        Assert.That(f.Avatar.transform.position, Is.EqualTo(position));
        Assert.That(f.Get<long>("avatarArbiterRendererGenerationHighWater"), Is.EqualTo(1L));
        f.Ticket("{\"channel\":\"bodyGesture\",\"clear\":true}", 2, true);
        Assert.That(Property<bool>(presence, "OwnsPresentation"), Is.True);
        Assert.That(f.Avatar.transform.position, Is.EqualTo(position));
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.Zero);
    }

    [Test]
    public void AdmittedListeningEpisodeReachesItsNativeLoopAndBoundedBackchannelUnderEnforce()
    {
        using var f = new Fixture(); f.Enforce();
        f.Call("Dispatch", "{\"method\":\"setConversationPhase\",\"json\":\"{\\\"phase\\\":\\\"listening\\\",\\\"sequence\\\":1}\"}");
        Assert.That(f.Get<bool>("conversationHintsEnabled"), Is.False, "A raw phase hint must remain blocked under the ticketed owner.");
        object micro = f.Get<object>("conversationalMicroMotion"); Invoke(micro, "Bind", f.Animator);
        string listen = Cue("listen", "gentle", "curious", .4f).ToString(Formatting.None);
        Assert.That(Validate(listen), Is.True); f.Ticket(listen, 1);
        float now = Time.realtimeSinceStartup;
        f.Call("AdvanceSpeechPerformance", now + .36f); f.Animator.Update(.2f);
        string clip = Property<string>(f.Get<object>("annieMotion"), "ActiveId");
        Assert.That(clip, Is.EqualTo("idle_shrug"));
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).IsName("Base Layer." + clip) ||
            f.Animator.GetNextAnimatorStateInfo(0).IsName("Base Layer." + clip), Is.True);
        bool allowed = (bool)f.Call("FreeConversationMotionAllowed", now + .55f);
        Assert.That(allowed, Is.True);
        Invoke(micro, "Apply", now + .55f, allowed);
        Assert.That(Property<bool>(micro, "BackchannelActive"), Is.True);
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.True);
        Assert.That(f.SpeechClip, Is.Null, "A listening lease cannot fabricate an acoustic speech layer.");
    }

    [Test]
    public void ListeningBodyClearRetiresOnlyItsLoopAndAFreshEpisodeCanStartBeforeANewerExplicitWave()
    {
        using var f = new Fixture(); f.Enforce();
        object micro = f.Get<object>("conversationalMicroMotion"); Invoke(micro, "Bind", f.Animator);
        f.Ticket(Cue("listen").ToString(Formatting.None), 1);
        f.Call("AdvanceSpeechPerformance", Time.realtimeSinceStartup + .36f);
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo("idle_shrug"));
        f.Ticket("{\"channel\":\"bodyGesture\",\"clear\":true}", 2, true);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.Null);
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.False);
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.Zero);
        // Reacquire before the stopped-phase hysteresis can run: the retired
        // policy's activeId must not masquerade as a still-playing Animator loop.
        f.Ticket(Cue("listen").ToString(Formatting.None), 3);
        // Resume is observed on the next real frame before its bounded
        // hysteresis elapses; a first coarse tick at +.36 starts that clock late.
        float resumedAt = Time.realtimeSinceStartup;
        f.Call("AdvanceSpeechPerformance", resumedAt);
        f.Call("AdvanceSpeechPerformance", resumedAt + .36f);
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo("idle_shrug"));
        f.Call("ApplyPrimitive", "wave", .8f);
        string wave = Property<string>(f.Get<object>("annieMotion"), "ActiveId"); float hold = f.Get<float>("actionPoseHoldUntil");
        Assert.That(wave, Is.EqualTo("annie_wave"));
        f.Ticket("{\"channel\":\"bodyGesture\",\"clear\":true}", 4, true);
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo(wave));
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.EqualTo(hold));
    }

    [TestCase("expiry")]
    [TestCase("task")]
    [TestCase("audio")]
    public void ExpiryTaskOrActualTtsStartCannotInheritOrReplayAnOldListeningLease(string reason)
    {
        using var f = new Fixture(); f.Enforce();
        object micro = f.Get<object>("conversationalMicroMotion"); Invoke(micro, "Bind", f.Animator);
        f.Ticket(Cue("listen").ToString(Formatting.None), 1);
        f.Call("AdvanceSpeechPerformance", Time.realtimeSinceStartup + .36f);
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo("idle_shrug"));
        if (reason == "expiry") { f.Set("performanceCueDeadlineMs", Utc - 1); Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false)); }
        else if (reason == "task") { f.Set("worldLocomotionActive", true); f.Advance(); f.Set("worldLocomotionActive", false); }
        else Assert.That(f.Sync(Clock()), Is.True);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.False);
        f.Advance();
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.Null);
        Assert.That(f.SpeechClip, Is.Null, "The listening body lease is not a speaking lease for a new TTS start.");
    }

    [Test]
    public void SpeechResetReleasesWritesButKeepsBoundMicroMotionAndClearanceReadyForTheNextListeningEpisode()
    {
        using var f = new Fixture(); f.Enforce();
        object micro = f.Get<object>("conversationalMicroMotion"), guard = f.Get<object>("freeGestureCollision");
        Invoke(micro, "Bind", f.Animator);
        Assert.That(Invoke(guard, "Bind", f.Avatar.transform, f.Animator), Is.EqualTo(true), Property<string>(guard, "BindingDiagnostic"));
        int count = Property<int>(micro, "BoneCount"); Assert.That(count, Is.GreaterThanOrEqualTo(3));
        f.Ticket(Cue("listen").ToString(Formatting.None), 1);
        float now = Time.realtimeSinceStartup;
        f.Call("AdvanceSpeechPerformance", now + .36f); Invoke(micro, "Apply", now + .55f, true);
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.True);
        f.Call("ResetSpeechPerformance");
        Assert.That(Property<int>(micro, "BoneCount"), Is.EqualTo(count), "An audio/turn reset is not a model replacement.");
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.False);
        Assert.That(Property<bool>(guard, "Bound"), Is.True);
        Assert.That(Property<bool>(guard, "HasOwnedWrites"), Is.False);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(false));
        // No Bind call is allowed here: the existing active model must still
        // accept its next legitimate listening episode after turn cleanup.
        f.Ticket(Cue("listen").ToString(Formatting.None), 2);
        now = Time.realtimeSinceStartup;
        f.Call("AdvanceSpeechPerformance", now + .36f);
        Assert.That(Property<string>(f.Get<object>("annieMotion"), "ActiveId"), Is.EqualTo("idle_shrug"));
        bool allowed = (bool)f.Call("FreeConversationMotionAllowed", now + .55f);
        Invoke(micro, "Apply", now + .55f, allowed);
        Assert.That(Property<bool>(micro, "BackchannelActive"), Is.True);
        Assert.That(Property<bool>(micro, "HasOwnedWrites"), Is.True);
    }

    [Test]
    public void AuthoredChestContactKeepsItsFullPoseWhileNonContactSpeechRetainsFreeArmClearance()
    {
        using var f = new Fixture();
        Assert.That(f.Call("EnsureSpeechPerformance"), Is.EqualTo(true));
        object library = f.Get<object>("performanceLibrary"), gestureAnimator = f.Get<object>("speechGestureAnimator");
        Type scheduler = A("AvatarSpeechGestureScheduler");
        Type sampleType = scheduler.GetNestedType("Sample", BindingFlags.Public);
        object stroke = Enum.Parse(scheduler.GetNestedType("GesturePhase", BindingFlags.Public), "Stroke");
        void ApplyActual(string id, bool contact)
        {
            var args = new object[] { id, null };
            Assert.That(Invoke(library, "TryGet", args), Is.EqualTo(true));
            object entry = args[1]; Assert.That((bool)entry.GetType().GetField("Contact").GetValue(entry), Is.EqualTo(contact));
            object sample = Activator.CreateInstance(sampleType, new object[] { entry, .7f, 1f, stroke, 0, 0f });
            Assert.That(Invoke(gestureAnimator, "Apply", f.Animator, sample, false), Is.EqualTo(true));
            f.Animator.Update(0f);
            Assert.That(Property<string>(gestureAnimator, "ActiveId"), Is.EqualTo(id));
        }
        ApplyActual("annie_g_chest_r", true);
        Assert.That(f.Call("FreeConversationMotionAllowed", Time.realtimeSinceStartup), Is.EqualTo(false),
            "The general torso guard must not pull a deliberately authored chest touch away from its contact.");
        ApplyActual("annie_g_offer_r", false);
        Assert.That(f.Call("FreeConversationMotionAllowed", Time.realtimeSinceStartup), Is.EqualTo(true));
        f.Set("worldLocomotionActive", true);
        Assert.That(f.Call("FreeConversationMotionAllowed", Time.realtimeSinceStartup), Is.EqualTo(false));
        f.Set("worldLocomotionActive", false); f.Call("ApplyPrimitive", "wave", .8f);
        Assert.That(f.Call("FreeConversationMotionAllowed", Time.realtimeSinceStartup), Is.EqualTo(false),
            "Removing the contact exception cannot bypass explicit action ownership.");
    }

    [Test]
    public void RendererDeliveryWindowDoesNotShortenTheSelectedBodyLease()
    {
        using var f = new Fixture(); f.Enforce();
        JObject body = Cue("speech", "gentle", "neutral", .5f);
        long leaseExpiry = (long)body["leaseExpiresAtEpochMs"];
        f.Ticket(body.ToString(Formatting.None), 1);
        Assert.That(f.Call("HasSpeechPerformanceCue"), Is.EqualTo(true));
        long queuedExpiry = f.Get<long>("performanceCueDeadlineMs");
        Assert.That(queuedExpiry, Is.GreaterThan(f.LastDeliveryDeadlineMs + 2000),
            "The 500ms transport delivery window must not truncate a 3.5s selected body lease.");
        Assert.That(queuedExpiry, Is.LessThanOrEqualTo(leaseExpiry), "The renderer cannot extend the admitted lease.");
        Assert.That(queuedExpiry, Is.EqualTo(leaseExpiry));
    }

    private static JObject Cue(string gesture = "speech", string energy = "moderate", string emotion = "neutral", float intensity = .65f) =>
        new() { ["channel"] = "bodyGesture", ["gesture"] = gesture, ["energy"] = energy, ["intensity"] = intensity, ["emotion"] = emotion, ["leaseExpiresAtEpochMs"] = Utc + 3500 };
    private static bool Validate(string json)
    {
        Type type = A("UnityAvatarCommandReceiver");
        Type payload = type.GetNestedType("AvatarArbiterRendererPayload", BindingFlags.NonPublic);
        object parsed = JsonUtility.FromJson(json, payload);
        return (bool)type.GetMethod("ValidateAvatarArbiterRendererPayload", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new[] { parsed, json });
    }
    private static JObject Clock(string state = "start", string id = "audio-a", long generation = 8, long sequence = 1,
        long position = 0, string turn = "turn-1", string utterance = "utterance-1")
    {
        var json = new JObject { ["protocolVersion"] = 1, ["playbackId"] = id, ["generation"] = generation,
            ["turnId"] = turn, ["utteranceId"] = utterance, ["sequence"] = sequence, ["state"] = state,
            ["positionMs"] = position, ["durationMs"] = 6000, ["source"] = "wav", ["authoritative"] = true };
        if (state == "start") { json["envelope"] = JArray.FromObject(Enumerable.Repeat(.2f, 180).ToArray()); json["frameRate"] = 30; }
        return json;
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Avatar;
        public readonly Animator Animator;
        private readonly GameObject host;
        private GameObject room, cameraObject;
        private readonly Component receiver;
        public string SpeechClip => Property<string>(Get<object>("speechGestureAnimator"), "ActiveId");
        public long LastDeliveryDeadlineMs { get; private set; }
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator = Avatar.GetComponentInChildren<Animator>(true);
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.applyRootMotion = false; Animator.Rebind(); Animator.Update(0f);
            host = new GameObject("Semantic speech receiver test"); receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            Set("avatarRoot", Avatar.transform); Set("animator", Animator); Invoke(Get<object>("localVisibility"), "SetVisible", true);
        }
        public T Get<T>(string name) => (T)receiver.GetType().GetField(name, Private).GetValue(receiver);
        public void Set(string name, object value) => receiver.GetType().GetField(name, Private).SetValue(receiver, value);
        public object Call(string name, params object[] args) => Invoke(receiver, name, args);
        public void Enforce()
        { Set("avatarArbiterOwnerToken", new string('A', 43)); Set("avatarArbiterAccountGeneration", 7L); Set("avatarArbiterRendererGeneration", 1L); Set("avatarArbiterRendererGenerationHighWater", 1L); }
        public bool Queue(string gesture, string emotion, string energy, float intensity, long sequence, long deadline) =>
            (bool)Call("QueueSpeechPerformanceCue", gesture, emotion, energy, intensity, sequence, deadline);
        public bool Sync(JObject json) => (bool)Call("SyncSpeechPlaybackClock", json.ToObject(A("AvatarSpeechPlaybackClockPacket")));
        public void Advance()
        { float now = Time.realtimeSinceStartup; Call("AdvanceSpeechPerformance", now); Call("AdvanceSpeechPerformance", now + .15f); Animator.Update(0f); }
        public void Ticket(string payload, long ticket, bool clear = false)
        {
            using var sha = SHA256.Create(); string digest = string.Concat(sha.ComputeHash(Encoding.UTF8.GetBytes(payload)).Select(b => b.ToString("x2")));
            string channel = (string)JObject.Parse(payload)["channel"];
            LastDeliveryDeadlineMs = Utc + 500;
            Call("DispatchAvatarArbiterCommand", new JObject { ["protocolVersion"] = 1, ["requestId"] = "semantic-ticket-" + ticket,
                ["ticket"] = ticket, ["rendererId"] = "renderer-instance-1", ["ownerToken"] = new string('A', 43), ["commitToken"] = new string('C', 43),
                ["accountGeneration"] = 7, ["rendererGeneration"] = 1, ["channel"] = channel, ["fingerprint"] = clear ? string.Empty : "0123456789abcdef",
                ["payloadJson"] = payload, ["payloadSha256"] = digest, ["deadlineEpochMs"] = LastDeliveryDeadlineMs, ["clearsChannel"] = clear }.ToString(Formatting.None));
        }
        public void LegacyPrimitive(string gesture, float amplitude, float intensity)
        {
            Type command = receiver.GetType().GetNestedType("PrimitiveCommand", BindingFlags.NonPublic);
            object value = JsonUtility.FromJson(new JObject { ["type"] = gesture,
                ["options"] = new JObject { ["amplitude"] = amplitude, ["intensity"] = intensity,
                    ["energy"] = "high", ["emotion"] = "excited", ["durationMs"] = 1200 } }.ToString(Formatting.None), command);
            Call("PlayPrimitive", value);
        }
        public void BeginPresence()
        {
            cameraObject = new GameObject("Semantic cue entrance camera"); cameraObject.AddComponent<Camera>();
            Component framing = cameraObject.AddComponent(A("FrontFullBodyCamera"));
            framing.GetType().GetProperty("TargetRoot").SetValue(framing, Avatar.transform);
            cameraObject.transform.position = new Vector3(0f, 1f, 3.5f); cameraObject.transform.LookAt(new Vector3(0f, .9f, 0f));
            float now = Time.realtimeSinceStartup; long utc = Utc;
            foreach (string phase in new[] { "prepare", "enter" })
            {
                object command = new JObject { ["requestId"] = "semantic-presence-" + phase, ["transitionId"] = "semantic-entrance",
                    ["phase"] = phase, ["edge"] = "right", ["durationMs"] = 1000, ["doNotInterrupt"] = true,
                    ["sequence"] = phase == "prepare" ? 1 : 2, ["expiresAtMs"] = utc + 4000 }.ToObject(A("AvatarPresenceCommand"));
                // Production lazily constructs the presence controller here.
                // Do not dereference the optional controller before this path.
                Call("TransitionPresence", command);
            }
            Invoke(Get<object>("presenceTransition"), "Advance", now + .3f, utc + 300);
        }
        public bool BeginDesk()
        {
            room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap")); Component rig = room.GetComponentInChildren(A("AvatarFurnitureRig"));
            Assert.That(rig, Is.Not.Null);
            return (bool)Invoke(Get<object>("furniturePose"), "BeginWorkSession", new string('d', 64), Avatar.transform, Animator, rig,
                Time.realtimeSinceStartup, (Action<string>)(_ => { }), (Action<bool>)(active => Call("SetWorldLocomotion", active)));
        }
        public void Dispose()
        { Invoke(Get<object>("furniturePose"), "Reset", false); Object.DestroyImmediate(host); Object.DestroyImmediate(Avatar); if (room != null) Object.DestroyImmediate(room); if (cameraObject != null) Object.DestroyImmediate(cameraObject); EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single); }
    }
}
