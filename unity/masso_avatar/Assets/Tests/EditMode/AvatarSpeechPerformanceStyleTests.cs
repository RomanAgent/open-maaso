using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarSpeechPerformanceStyleTests
{
    private const BindingFlags Public = BindingFlags.Public | BindingFlags.Instance;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] args) => value.GetType().GetMethod(method, Public).Invoke(value, args);
    private static T Property<T>(object value, string name) => (T)value.GetType().GetProperty(name, Public).GetValue(value);
    private static T Field<T>(object value, string name) => (T)value.GetType().GetField(name, Public).GetValue(value);
    private static string Id(object sample) => Field<object>(sample, "Entry") is { } entry ? Field<string>(entry, "Id") : null;
    private static object Tick(object scheduler, float at, long generation = 1, bool playing = true, bool blocked = false) =>
        Call(scheduler, "Tick", generation, at, playing, blocked);
    private static bool Cue(object scheduler, long generation = 1, long sequence = 1, string id = "auto",
        string emotion = "neutral", string energy = "moderate", float intensity = .65f) =>
        (bool)Call(scheduler, "QueuePerformanceCue", generation, sequence, id, emotion, energy, intensity);

    [Test]
    public void PerformanceCueIsStrictlyBoundedAndFencedToActualPlayback()
    {
        using var f = new Fixture();
        Assert.That(Cue(f.Scheduler), Is.False, "A cue cannot start audio or claim an unproved generation.");
        Call(f.Scheduler, "Start", 1L, new float[600], 100f);
        Assert.That(Cue(f.Scheduler, id: "annie_semantic", emotion: "happy", energy: "high", intensity: .8f), Is.True);
        Assert.That(Cue(f.Scheduler, sequence: 1), Is.False);
        Assert.That(Cue(f.Scheduler, generation: 0, sequence: 2), Is.False);
        Assert.That(Cue(f.Scheduler, sequence: 2, id: "walk_to_desk"), Is.False);
        Assert.That(Cue(f.Scheduler, sequence: 2, energy: "unbounded"), Is.False);
        Assert.That(Cue(f.Scheduler, sequence: 2, emotion: "raw-bone-angle"), Is.False);
        Assert.That(Cue(f.Scheduler, sequence: 2, intensity: float.NaN), Is.False);
        Assert.That(Cue(f.Scheduler, sequence: 2, intensity: 1.01f), Is.False);
        Assert.That(Cue(f.Scheduler, sequence: 9007199254740992L), Is.False);
        Assert.That(Property<long>(f.Scheduler, "CueSequence"), Is.EqualTo(1), "Rejected packets cannot consume a valid cue sequence.");
        for (int frame = 0; frame < 600; frame++) Assert.That(Property<bool>(Tick(f.Scheduler, frame / 100f), "Active"), Is.False,
            "Even a high-energy semantic cue cannot manufacture motion on silence.");
        Call(f.Scheduler, "Stop");
        Assert.That(Cue(f.Scheduler, sequence: 3), Is.False);
        Call(f.Scheduler, "Start", 2L, Track(6, 1f), 100f);
        Assert.That(Property<string>(f.Scheduler, "Energy"), Is.EqualTo("moderate"));
        Assert.That(Property<string>(f.Scheduler, "Emotion"), Is.EqualTo("neutral"));
        Assert.That(Cue(f.Scheduler, generation: 1, sequence: 4), Is.False);
    }

    [Test]
    public void SemanticCueHasPriorityWithoutInterruptingAnOngoingStrokeOrBypassingCadence()
    {
        using var f = new Fixture();
        Call(f.Scheduler, "Start", 1L, Track(8, 1f, 4.5f), 100f);
        for (int frame = 0; frame <= 110; frame++) Tick(f.Scheduler, frame / 100f);
        Assert.That(Cue(f.Scheduler, id: "annie_semantic"), Is.True);
        Assert.That(Id(Tick(f.Scheduler, 1.11f)), Is.EqualTo("annie_test"), "The semantic cue must not snap an existing accent into a different pose.");
        var strokes = new List<(string id, float at)>();
        for (int frame = 112; frame < 700; frame++)
        {
            object sample = Tick(f.Scheduler, frame / 100f);
            if (Field<int>(sample, "StrokeIndex") >= 0) strokes.Add((Id(sample), frame / 100f));
        }
        Assert.That(strokes, Has.Count.EqualTo(1));
        Assert.That(strokes[0].id, Is.EqualTo("annie_semantic"));
        Assert.That(strokes[0].at, Is.EqualTo(4.5f).Within(.011f));
    }

    [Test]
    public void ReleasingCueLeaseRetiresItsStyleAndSemanticButKeepsStaleFenceAndAccentBudget()
    {
        using var f = new Fixture();
        Call(f.Scheduler, "Start", 1L, Track(8, 1f, 4.5f), 100f);
        Assert.That(Cue(f.Scheduler, id: "annie_semantic", emotion: "happy", energy: "high"), Is.True);
        for (int frame = 0; frame <= 110; frame++) Tick(f.Scheduler, frame / 100f);
        Assert.That(Cue(f.Scheduler, sequence: 2, id: "annie_semantic", energy: "high"), Is.True);
        Call(f.Scheduler, "ClearPerformanceCue");
        Assert.That(Property<long>(f.Scheduler, "Generation"), Is.EqualTo(1));
        Assert.That(Property<long>(f.Scheduler, "CueSequence"), Is.EqualTo(2));
        Assert.That(Property<string>(f.Scheduler, "Energy"), Is.EqualTo("moderate"));
        Assert.That(Property<string>(f.Scheduler, "Emotion"), Is.EqualTo("neutral"));
        Assert.That(Cue(f.Scheduler, sequence: 2, id: "annie_semantic"), Is.False);
        for (int frame = 111; frame < 700; frame++)
            Assert.That(Id(Tick(f.Scheduler, frame / 100f)), Is.Not.EqualTo("annie_semantic"));
    }

    [Test]
    public void EveryOfficialSemanticGestureCanUseItsAuthoredStages()
    {
        object library = Resources.Load("OpenAnnieMotionLibrary", A("OpenAnnieMotionLibrary"));
        object[] entries = ((Array)library.GetType().GetField("Entries").GetValue(library)).Cast<object>()
            .Where(e => Field<string>(e, "Layer") == "gesture").ToArray();
        Assert.That(entries, Has.Length.EqualTo(32));
        foreach (object entry in entries)
        {
            object scheduler = Activator.CreateInstance(A("AvatarSpeechGestureScheduler"));
            Call(scheduler, "Initialize", library, 17);
            Call(scheduler, "Start", 1L, Track(6, 1.2f, 2f, 2.6f), 100f);
            string id = Field<string>(entry, "Id");
            Assert.That(Cue(scheduler, id: id), Is.True, id);
            bool sawStroke = false;
            for (int frame = 0; frame < 350; frame++)
            {
                object sample = Tick(scheduler, frame / 100f);
                if (Id(sample) != id || Field<int>(sample, "StrokeIndex") < 0) continue;
                sawStroke = true;
                Assert.That(Field<float>(sample, "Weight"), Is.InRange(.01f, 1f), id);
                Assert.That(Field<float>(sample, "StrokeOffsetSeconds"), Is.InRange(0f, .011f), id);
            }
            Assert.That(sawStroke, Is.True, id + " must actually reach its acoustic stroke, not merely parse successfully.");
        }
    }

    [Test]
    public void ModerateAutomaticSpeechIncludesBothHandsWithoutContinuousBeatNoise()
    {
        using var f = new Fixture(official: true);
        Call(f.Scheduler, "Start", 1L, Track(30, Enumerable.Range(1, 115).Select(i => i * .25f).ToArray()), 100f);
        var phrases = new List<float>();
        var hands = new HashSet<string>();
        for (int frame = 0; frame < 3000; frame++)
        {
            object sample = Tick(f.Scheduler, frame / 100f);
            if (Field<int>(sample, "StrokeIndex") != 0) continue;
            phrases.Add(frame / 100f);
            hands.Add(Field<string>(Field<object>(sample, "Entry"), "Hands"));
        }
        Assert.That(hands, Does.Contain("both"));
        Assert.That(phrases.Count, Is.InRange(3, 10));
        for (int index = 1; index < phrases.Count; index++)
            Assert.That(phrases[index] - phrases[index - 1], Is.GreaterThanOrEqualTo(3.19f));
    }

    [Test]
    public void EnergyAndModelProfileChangeCadenceWithoutDilutingAuthoredPose()
    {
        var results = new Dictionary<string, (List<float> phrases, float weight, float interval)>();
        foreach (string level in new[] { "calm", "moderate", "high" })
        {
            using var f = new Fixture();
            Call(f.Scheduler, "Start", 1L, Track(30, Enumerable.Range(1, 115).Select(i => i * .25f).ToArray()), 100f);
            Assert.That(Cue(f.Scheduler, emotion: "happy", energy: level, intensity: 1f), Is.True);
            var phrases = new List<float>();
            float weight = 0f;
            for (int frame = 0; frame < 3000; frame++)
            {
                object sample = Tick(f.Scheduler, frame / 100f);
                if (Field<int>(sample, "StrokeIndex") != 0) continue;
                phrases.Add(frame / 100f);
                weight = Mathf.Max(weight, Field<float>(sample, "Weight"));
            }
            float interval = Property<float>(f.Scheduler, "CurrentAccentIntervalSeconds");
            for (int index = 1; index < phrases.Count; index++)
                Assert.That(phrases[index] - phrases[index - 1], Is.GreaterThanOrEqualTo(interval - .011f), level);
            results[level] = (phrases, weight, interval);
        }
        foreach (var result in results)
            Assert.That(result.Value.weight, Is.EqualTo(1f), result.Key + " must preserve the authored stroke, including fingers.");
        Assert.That(results["high"].phrases.Count, Is.GreaterThanOrEqualTo(results["calm"].phrases.Count));
        Assert.That(results["high"].interval, Is.GreaterThanOrEqualTo(2.4f));
        using var restrained = new Fixture();
        Assert.That(Call(restrained.Scheduler, "SetProfile", "restrained"), Is.True);
        Call(restrained.Scheduler, "Start", 1L, Track(6, 1f), 100f);
        Cue(restrained.Scheduler, energy: "high");
        Assert.That(Property<float>(restrained.Scheduler, "CurrentAccentIntervalSeconds"), Is.GreaterThan(results["high"].interval));
        Assert.That(Call(restrained.Scheduler, "SetProfile", "user_supplied_bone_control"), Is.False);
        Assert.That(Property<string>(restrained.Scheduler, "Profile"), Is.EqualTo("restrained"));
    }

    [Test]
    public void StyleSelectsMidTalkPostureAndQuietEmotionDoesNotImplyExcitementFromLoudness()
    {
        using var f = new Fixture(official: true);
        Call(f.Scheduler, "SetProfile", "cartoony");
        Call(f.Scheduler, "Start", 1L, Enumerable.Repeat(.35f, 600).ToArray(), 100f);
        Assert.That(Cue(f.Scheduler, emotion: "happy", energy: "high"), Is.True);
        Tick(f.Scheduler, 0f);
        object high = Tick(f.Scheduler, .2f);
        Assert.That(Field<string>(Field<object>(high, "Entry"), "Energy"), Is.EqualTo("excited"));
        Assert.That(Cue(f.Scheduler, sequence: 2, emotion: "comforting", energy: "high"), Is.True);
        Tick(f.Scheduler, .21f);
        object quiet = Tick(f.Scheduler, .4f);
        Assert.That(Field<string>(Field<object>(quiet, "Entry"), "Energy"), Is.EqualTo("calm"));
        Assert.That(Property<float>(f.Scheduler, "CurrentAccentIntervalSeconds"), Is.GreaterThanOrEqualTo(3.8f));
        Assert.That(Field<float>(quiet, "Weight"), Is.EqualTo(1f));
        Assert.That(Field<float>(high, "Weight"), Is.EqualTo(1f), "Energy selects an authored source; it must not dilute the current hand posture.");
    }

    [TestCase(false, false)]
    [TestCase(true, true)]
    public void TaskTakeoverAndPauseRetireQueuedOldSemanticCue(bool playing, bool blocked)
    {
        using var f = new Fixture();
        Call(f.Scheduler, "Start", 1L, Track(6, 1.2f), 100f);
        Assert.That(Cue(f.Scheduler, id: "annie_semantic"), Is.True);
        Tick(f.Scheduler, 0f, playing: playing, blocked: blocked);
        bool sawAuto = false;
        for (int frame = 1; frame < 250; frame++)
        {
            object sample = Tick(f.Scheduler, frame / 100f);
            Assert.That(Id(sample), Is.Not.EqualTo("annie_semantic"), "An old point/contact must not execute after takeover ends.");
            sawAuto |= Id(sample) == "annie_test";
        }
        Assert.That(sawAuto, Is.True, "Ordinary speech may resume after takeover without replaying old semantics.");
        Assert.That(Cue(f.Scheduler, sequence: 1, id: "annie_semantic"), Is.False);
    }

    [TestCase("realistic", .2f)]
    [TestCase("restrained", 1f)]
    [TestCase("cartoony", .8f)]
    public void ContactGestureKeepsItsAuthoredReachAtStrokeRegardlessOfStyleIntensity(string profile, float intensity)
    {
        using var f = new Fixture(official: true);
        Call(f.Scheduler, "SetProfile", profile);
        Call(f.Scheduler, "Start", 1L, Track(6, 1f), 100f);
        Assert.That(Cue(f.Scheduler, id: "annie_g_chest_r", energy: "calm", intensity: intensity), Is.True);
        bool contact = false;
        for (int frame = 0; frame < 250; frame++)
        {
            object sample = Tick(f.Scheduler, frame / 100f);
            if (Field<int>(sample, "StrokeIndex") < 0) continue;
            contact = true;
            Assert.That(Id(sample), Is.EqualTo("annie_g_chest_r"));
            Assert.That(Field<float>(sample, "Weight"), Is.EqualTo(1f));
        }
        Assert.That(contact, Is.True);
    }

    [TestCase("realistic", "calm", 0f)]
    [TestCase("realistic", "moderate", .65f)]
    [TestCase("realistic", "high", 1f)]
    [TestCase("restrained", "calm", .2f)]
    [TestCase("restrained", "moderate", 1f)]
    [TestCase("restrained", "high", .65f)]
    [TestCase("cartoony", "calm", 1f)]
    [TestCase("cartoony", "moderate", .2f)]
    [TestCase("cartoony", "high", .8f)]
    public void NoncontactGestureAlsoPreservesFullAuthoredStrokeAcrossProfiles(string profile, string energy, float intensity)
    {
        using var f = new Fixture(official: true);
        Call(f.Scheduler, "SetProfile", profile);
        Call(f.Scheduler, "Start", 1L, Track(6, 1f), 100f);
        Assert.That(Cue(f.Scheduler, id: "annie_g_beat_r", energy: energy, intensity: intensity), Is.True);
        bool sawStroke = false;
        for (int frame = 0; frame < 250; frame++)
        {
            object sample = Tick(f.Scheduler, frame / 100f);
            if (Field<int>(sample, "StrokeIndex") < 0) continue;
            sawStroke = true;
            Assert.That(Id(sample), Is.EqualTo("annie_g_beat_r"));
            Assert.That(Field<float>(sample, "Weight"), Is.EqualTo(1f));
        }
        Assert.That(sawStroke, Is.True);
    }

    [Test]
    public void AnimatorUsesExactContactClipPoseAndRejectsUnboundedSamples()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        try
        {
            Animator animator = avatar.GetComponentInChildren<Animator>(true);
            animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            animator.applyRootMotion = false;
            animator.Rebind(); animator.Update(0f);
            object library = Resources.Load("OpenAnnieMotionLibrary", A("OpenAnnieMotionLibrary"));
            object entry = ((Array)library.GetType().GetField("Entries").GetValue(library)).Cast<object>()
                .Single(e => Field<string>(e, "Id") == "annie_g_chest_r");
            int layer = animator.GetLayerIndex("Annie Upper Body");
            int state = Animator.StringToHash("Annie Upper Body.annie_g_chest_r");
            animator.Play(state, layer, .62f / Field<float>(entry, "Duration"));
            animator.SetLayerWeight(layer, 1f);
            animator.Update(0f);
            Vector3 expectedHand = animator.GetBoneTransform(HumanBodyBones.RightHand).position;
            Vector3 root = avatar.transform.position;
            animator.Rebind(); animator.Update(0f);
            object adapter = Activator.CreateInstance(A("AvatarSpeechGestureAnimator"));
            Assert.That(Call(adapter, "Apply", animator, Sample(entry, .62f, 1f), false), Is.True);
            animator.Update(0f);
            Assert.That(Vector3.Distance(animator.GetBoneTransform(HumanBodyBones.RightHand).position, expectedHand), Is.LessThan(.00001f),
                "Style must not shift the hand by scaling an authored contact pose or its speed.");
            Assert.That(avatar.transform.position, Is.EqualTo(root));
            Assert.That(animator.speed, Is.EqualTo(1f));
            Assert.That(Call(adapter, "Apply", animator, Sample(entry, float.NaN, 1f), false), Is.False);
            Assert.That(animator.GetLayerWeight(layer), Is.Zero);
            Assert.That(Call(adapter, "Apply", animator, Sample(entry, .62f, 1.1f), false), Is.False);
        }
        finally { Object.DestroyImmediate(avatar); }
    }

    private static object Sample(object entry, float seconds, float weight) => Activator.CreateInstance(
        A("AvatarSpeechGestureScheduler").GetNestedType("Sample"), entry, seconds, weight,
        Enum.Parse(A("AvatarSpeechGestureScheduler").GetNestedType("GesturePhase"), "Stroke"), -1, 0f);

    private static float[] Track(int seconds, params float[] onsets)
    {
        float[] track = new float[seconds * 100];
        foreach (float onset in onsets)
        {
            int at = Mathf.RoundToInt(onset * 100);
            for (int index = 0; index < 10 && at + index < track.Length; index++)
                track[at + index] = .35f * (1f - index / 10f);
        }
        return track;
    }

    private sealed class Fixture : IDisposable
    {
        public readonly object Scheduler;
        private readonly ScriptableObject owned;
        public Fixture(bool official = false)
        {
            object library;
            if (official) library = Resources.Load("OpenAnnieMotionLibrary", A("OpenAnnieMotionLibrary"));
            else
            {
                owned = ScriptableObject.CreateInstance(A("OpenAnnieMotionLibrary"));
                JsonUtility.FromJsonOverwrite("{\"Entries\":[" +
                    "{\"Id\":\"annie_test\",\"UpperBody\":true,\"Duration\":1.2,\"Category\":\"beat\",\"Layer\":\"gesture\",\"Energy\":\"calm\",\"Hands\":\"right\",\"PreparationEnd\":0.28,\"Stroke\":0.4,\"RetractionStart\":0.7}," +
                    "{\"Id\":\"annie_semantic\",\"UpperBody\":true,\"Duration\":1.2,\"Category\":\"iconic\",\"Layer\":\"gesture\",\"Energy\":\"animated\",\"Hands\":\"both\",\"PreparationEnd\":0.28,\"Stroke\":0.4,\"RetractionStart\":0.7}," +
                    "{\"Id\":\"annie_talk_calm_1\",\"UpperBody\":true,\"Loop\":true,\"Duration\":5,\"Layer\":\"talk\",\"Energy\":\"calm\"}]}", owned);
                library = owned;
            }
            Scheduler = Activator.CreateInstance(A("AvatarSpeechGestureScheduler"));
            Call(Scheduler, "Initialize", library, 0);
        }
        public void Dispose() { if (owned != null) Object.DestroyImmediate(owned); }
    }
}
