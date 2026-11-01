using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarSpeechGestureSchedulerTests
{
    private const BindingFlags Public = BindingFlags.Public | BindingFlags.Instance;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object target, string method, params object[] args) => target.GetType().GetMethod(method, Public).Invoke(target, args);
    private static T Field<T>(object target, string name) => (T)target.GetType().GetField(name, Public).GetValue(target);
    private static T Property<T>(object target, string name) => (T)target.GetType().GetProperty(name, Public).GetValue(target);

    [Test]
    public void All32GestureStageRecordsAndEightTalkRestsAreAvailable()
    {
        object scheduler = Activator.CreateInstance(A("AvatarSpeechGestureScheduler"));
        Call(scheduler, "Initialize", Resources.Load("OpenAnnieMotionLibrary", A("OpenAnnieMotionLibrary")), 17);
        Assert.That(Property<int>(scheduler, "AvailableGestureCount"), Is.EqualTo(32));
        Assert.That(Property<int>(scheduler, "AvailableRestCount"), Is.EqualTo(8));
        Assert.That(Property<int>(scheduler, "AvailableAutomaticGestureCount"), Is.EqualTo(10));
    }

    [Test]
    public void SilenceAndUnprovedSessionNeverProduceAStroke()
    {
        using var f = new Fixture();
        Assert.That(Call(f.Scheduler, "Start", 4L, new float[600], 100f), Is.True);
        for (int i = 0; i < 600; i++)
        {
            object sample = Call(f.Scheduler, "Tick", 4L, i / 100f, true, false);
            Assert.That(Property<bool>(sample, "Active"), Is.False);
        }
        Assert.That(Property<bool>(Call(f.Scheduler, "Tick", 3L, 1f, true, false), "Active"), Is.False);
    }

    [Test]
    public void PreparationHoldStrokeAndRetractionFollowThePlaybackCursor()
    {
        using var f = new Fixture();
        Call(f.Scheduler, "Start", 1L, Track(6, 1f), 100f);
        var phases = new HashSet<string>();
        var strokeTimes = new List<float>();
        float holdStarted = -1f, holdEnded = -1f;
        for (int i = 0; i < 210; i++)
        {
            float at = i / 100f;
            object sample = Call(f.Scheduler, "Tick", 1L, at, true, false);
            string phase = Field<object>(sample, "Phase").ToString();
            phases.Add(phase);
            if (phase == "Hold") { if (holdStarted < 0f) holdStarted = at; holdEnded = at; }
            if (Field<int>(sample, "StrokeIndex") >= 0)
            {
                strokeTimes.Add(at);
                Assert.That(Field<float>(sample, "StrokeOffsetSeconds"), Is.InRange(0f, .011f));
            }
        }
        Assert.That(phases, Is.SupersetOf(new[] { "Preparation", "Hold", "Stroke", "Retraction" }));
        Assert.That(holdEnded - holdStarted, Is.LessThanOrEqualTo(.601f));
        Assert.That(strokeTimes, Has.Count.EqualTo(1));
        Assert.That(strokeTimes[0], Is.EqualTo(1f).Within(.011f));
    }

    [Test]
    public void MultipleStrokeMetadataAlignsEachAccentAndMissingAccentRetracts()
    {
        using var f = new Fixture(multiple: true);
        Call(f.Scheduler, "Start", 1L, Track(6, .9f, 1.4f, 1.8f), 100f);
        var strokes = new List<(int index, float at)>();
        for (int i = 0; i < 250; i++)
        {
            object sample = Call(f.Scheduler, "Tick", 1L, i / 100f, true, false);
            int index = Field<int>(sample, "StrokeIndex");
            if (index >= 0) strokes.Add((index, i / 100f));
        }
        Assert.That(strokes.Select(x => x.index), Is.EqualTo(new[] { 0, 1, 2 }));
        Assert.That(strokes.Select(x => x.at), Is.EqualTo(new[] { .9f, 1.4f, 1.8f }).Within(.011f));

        using var fresh = new Fixture(multiple: true);
        Call(fresh.Scheduler, "Start", 1L, Track(6, .9f), 100f);
        var next = new List<int>();
        bool retracted = false;
        for (int i = 0; i < 250; i++)
        {
            object sample = Call(fresh.Scheduler, "Tick", 1L, i / 100f, true, false);
            if (Field<int>(sample, "StrokeIndex") >= 0) next.Add(Field<int>(sample, "StrokeIndex"));
            retracted |= Field<object>(sample, "Phase").ToString() == "Retraction";
        }
        Assert.That(next, Is.EqualTo(new[] { 0 }));
        Assert.That(retracted, Is.True);
    }

    [TestCase(false, false)]
    [TestCase(true, true)]
    public void PauseTaskOrBackgroundDoesNotReplayMissedAccent(bool playing, bool blocked)
    {
        using var f = new Fixture();
        Call(f.Scheduler, "Start", 1L, Track(6, 1f, 4.5f), 100f);
        for (int i = 0; i < 60; i++) Call(f.Scheduler, "Tick", 1L, i / 100f, true, false);
        Assert.That(Property<bool>(Call(f.Scheduler, "Tick", 1L, .6f, playing, blocked), "Active"), Is.False);
        object resumed = Call(f.Scheduler, "Tick", 1L, 1.1f, true, false);
        Assert.That(Field<int>(resumed, "StrokeIndex"), Is.LessThan(0));
        Assert.That(Field<object>(resumed, "Phase").ToString(), Is.Not.EqualTo("Stroke"));
    }

    [Test]
    public void SeekStopAndStaleGenerationCannotContinueOldMovement()
    {
        using var f = new Fixture();
        Call(f.Scheduler, "Start", 7L, Track(6, 1f), 100f);
        Call(f.Scheduler, "Tick", 7L, 0f, true, false);
        object skipped = Call(f.Scheduler, "Tick", 7L, 2f, true, false);
        Assert.That(Property<bool>(skipped, "Active"), Is.False);
        Assert.That(Call(f.Scheduler, "Start", 6L, Track(6, 1f), 100f), Is.False);
        Assert.That(Call(f.Scheduler, "Start", 7L, Track(6, 1f), 100f), Is.False);
        Assert.That(Call(f.Scheduler, "Start", 8L, Track(6, 1f), 100f), Is.True);
        Assert.That(Property<bool>(Call(f.Scheduler, "Tick", 7L, .5f, true, false), "Active"), Is.False);
        Call(f.Scheduler, "Stop");
        Assert.That(Property<bool>(Call(f.Scheduler, "Tick", 8L, .6f, true, false), "Active"), Is.False);
    }

    [Test]
    public void DenseEnvelopeDoesNotTurnIntoMechanicalContinuousBeats()
    {
        using var f = new Fixture();
        float[] track = Track(30, Enumerable.Range(1, 100).Select(i => i * .28f).ToArray());
        Call(f.Scheduler, "Start", 1L, track, 100f);
        var strokes = new List<float>();
        for (int i = 0; i < track.Length; i++)
        {
            object sample = Call(f.Scheduler, "Tick", 1L, i / 100f, true, false);
            if (Field<int>(sample, "StrokeIndex") >= 0) strokes.Add(i / 100f);
        }
        Assert.That(strokes.Count, Is.InRange(2, 10));
        for (int i = 1; i < strokes.Count; i++)
            Assert.That(strokes[i] - strokes[i - 1], Is.GreaterThanOrEqualTo(3.19f));
    }

    [Test]
    public void ConsecutiveAudioChunksShareTheSameAccentDensityBudget()
    {
        using var f = new Fixture();
        var accents = new List<float>();
        for (int chunk = 0; chunk < 8; chunk++)
        {
            Call(f.Scheduler, "Start", (long)chunk + 1, Track(2, 1f), 100f);
            for (int i = 0; i < 160; i++)
            {
                object sample = Call(f.Scheduler, "Tick", (long)chunk + 1, i / 100f, true, false);
                if (Field<int>(sample, "StrokeIndex") >= 0) accents.Add(chunk * 1.6f + i / 100f);
            }
        }
        Assert.That(accents.Count, Is.InRange(2, 4));
        for (int i = 1; i < accents.Count; i++)
            Assert.That(accents[i] - accents[i - 1], Is.GreaterThanOrEqualTo(3.19f));
    }

    [Test]
    public void TalkRestIsBoundedAndEnvelopeInputIsCopiedAndSanitized()
    {
        using var f = new Fixture();
        float[] track = Enumerable.Repeat(.15f, 600).ToArray();
        track[10] = float.NaN; track[20] = float.PositiveInfinity;
        Call(f.Scheduler, "Start", 1L, track, 100f);
        Array.Clear(track, 0, track.Length);
        Call(f.Scheduler, "Tick", 1L, 0f, true, false);
        object sample = Call(f.Scheduler, "Tick", 1L, .15f, true, false);
        Assert.That(Field<object>(sample, "Phase").ToString(), Is.EqualTo("Rest"));
        Assert.That(Field<float>(sample, "Weight"), Is.EqualTo(.15f / .18f).Within(.0001f), "The copied voice drives lifecycle attack, not a style-scaled arm pose.");
        Assert.That(Call(f.Scheduler, "QueueGesture", "missing"), Is.False);
    }

    [Test]
    public void ThirtyAndSixtyFpsUseTheSameAcousticTargets()
    {
        foreach (int fps in new[] { 30, 60 })
        {
            using var f = new Fixture();
            Call(f.Scheduler, "Start", 1L, Track(8, 1f, 4.5f), 100f);
            var offsets = new List<float>();
            for (int i = 0; i < 8 * fps; i++)
            {
                object sample = Call(f.Scheduler, "Tick", 1L, (float)i / fps, true, false);
                if (Field<int>(sample, "StrokeIndex") >= 0) offsets.Add(Field<float>(sample, "StrokeOffsetSeconds"));
            }
            Assert.That(offsets.Count, Is.EqualTo(2));
            Assert.That(offsets.All(offset => offset <= 1f / fps + .001f), Is.True);
        }
    }

    [Test]
    public void AnimatorAdapterReleasesOnlyItsOwnUpperLayerWithoutMovingRoot()
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
            Vector3 position = avatar.transform.position;
            Quaternion rotation = avatar.transform.rotation;
            int layer = animator.GetLayerIndex("Annie Upper Body");
            object adapter = Activator.CreateInstance(A("AvatarSpeechGestureAnimator"));
            object library = Resources.Load("OpenAnnieMotionLibrary", A("OpenAnnieMotionLibrary"));
            object entry = ((Array)library.GetType().GetField("Entries").GetValue(library)).Cast<object>()
                .First(e => Field<string>(e, "Id") == "annie_g_beat_r");
            Type phaseType = A("AvatarSpeechGestureScheduler").GetNestedType("GesturePhase");
            object sample = Activator.CreateInstance(A("AvatarSpeechGestureScheduler").GetNestedType("Sample"),
                entry, .42f, .65f, Enum.Parse(phaseType, "Stroke"), -1, 0f);
            Assert.That(Call(adapter, "Apply", animator, sample, false), Is.True);
            animator.Update(0f);
            Assert.That(animator.GetLayerWeight(layer), Is.EqualTo(1f), "Lifecycle gain must not blend authored arms into a different idle.");
            Assert.That(Property<bool>(adapter, "UsesDirectSource"), Is.False);
            Assert.That(avatar.transform.position, Is.EqualTo(position));
            Assert.That(Quaternion.Angle(avatar.transform.rotation, rotation), Is.LessThan(.001f));
            Assert.That(Call(adapter, "ApplyDirectSource", animator, sample, false), Is.True);
            Assert.That(animator.GetLayerWeight(layer), Is.Zero, "A direct source owner must not double-blend with the native speech layer.");
            Assert.That(Property<bool>(adapter, "UsesDirectSource"), Is.True);
            Assert.That(Field<object>(Property<object>(adapter, "CurrentSample"), "Entry"), Is.SameAs(entry));
            int explicitState = Animator.StringToHash("Annie Upper Body.annie_g_offer_r");
            animator.CrossFadeInFixedTime(explicitState, .12f, layer, 0f);
            animator.Update(.01f);
            animator.SetLayerWeight(layer, .9f);
            Call(adapter, "Release");
            Assert.That(animator.GetLayerWeight(layer), Is.EqualTo(.9f), "A new explicit action keeps its layer.");
            Assert.That(Property<string>(adapter, "ActiveId"), Is.Null);
            Assert.That(Property<bool>(adapter, "UsesDirectSource"), Is.False);
        }
        finally { Object.DestroyImmediate(avatar); }
    }

    private static float[] Track(int seconds, params float[] onsets)
    {
        float[] track = new float[seconds * 100];
        foreach (float onset in onsets)
        {
            int at = Mathf.RoundToInt(onset * 100);
            for (int j = 0; j < 10 && at + j < track.Length; j++) track[at + j] = .35f * (1f - j / 10f);
        }
        return track;
    }

    private sealed class Fixture : IDisposable
    {
        public readonly object Scheduler;
        private readonly ScriptableObject library;
        public Fixture(bool multiple = false)
        {
            library = ScriptableObject.CreateInstance(A("OpenAnnieMotionLibrary"));
            string strokes = multiple ? ",\"Strokes\":[0.3,0.64,0.98]" : "";
            JsonUtility.FromJsonOverwrite("{\"Entries\":[{\"Id\":\"annie_test\",\"UpperBody\":true,\"Duration\":" +
                (multiple ? "1.5" : "1.2") + ",\"Category\":\"beat\",\"Layer\":\"gesture\",\"Energy\":\"calm\",\"PreparationEnd\":" +
                (multiple ? "0.18" : "0.28") + ",\"Stroke\":" + (multiple ? "0.3" : "0.4") +
                ",\"RetractionStart\":" + (multiple ? "1.08" : "0.7") + strokes + "}," +
                "{\"Id\":\"annie_talk_calm_1\",\"UpperBody\":true,\"Loop\":true,\"Duration\":5,\"Layer\":\"talk\",\"Energy\":\"calm\"}]}", library);
            Scheduler = Activator.CreateInstance(A("AvatarSpeechGestureScheduler"));
            Call(Scheduler, "Initialize", library, 0);
        }
        public void Dispose() => Object.DestroyImmediate(library);
    }
}
