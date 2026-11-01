using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarSpeechRestContinuityTests
{
    private const BindingFlags Public = BindingFlags.Public | BindingFlags.Instance;
    private static Type Scheduler => Type.GetType("Maaso.Avatar.AvatarSpeechGestureScheduler, Assembly-CSharp", true);
    private static Type Library => Type.GetType("Maaso.Avatar.OpenAnnieMotionLibrary, Assembly-CSharp", true);
    private static object Call(object target, string name, params object[] args) => target.GetType().GetMethod(name, Public).Invoke(target, args);
    private static T Field<T>(object sample, string name) => (T)sample.GetType().GetField(name, Public).GetValue(sample);
    private static bool Active(object sample) => (bool)sample.GetType().GetProperty("Active", Public).GetValue(sample);

    [TestCase(30)]
    [TestCase(60)]
    public void SyllabicEnvelopeKeepsOneRestEpisodeWithBoundedFrameWeightChanges(int fps)
    {
        // Same 30 Hz four-voiced/two-unvoiced pattern that previously produced
        // thirty Active/Empty switches in three seconds and ~.42/.50 jumps.
        float[] track = Enumerable.Range(0, 120).Select(i => i % 6 < 4 ? .2f : 0f).ToArray();
        using var f = new Fixture(track, 30f);
        int switches = 0;
        bool previousActive = false;
        float previousWeight = 0f, maximumDelta = 0f, maximumWeight = 0f;
        for (int frame = 0; frame < fps * 3; frame++)
        {
            float at = frame / (float)fps;
            object sample = f.Tick(at);
            bool active = Active(sample);
            if (active != previousActive) switches++;
            float weight = Field<float>(sample, "Weight");
            maximumDelta = Mathf.Max(maximumDelta, Mathf.Abs(weight - previousWeight));
            maximumWeight = Mathf.Max(maximumWeight, weight);
            if (at >= .25f) Assert.That(active, Is.True, "An unvoiced syllable is not a new body state at " + at);
            if (active)
            {
                Assert.That(Field<object>(sample, "Phase").ToString(), Is.EqualTo("Rest"));
                Assert.That(Field<float>(sample, "ClipSeconds"), Is.EqualTo(at).Within(.0001f), "Rest clip phase follows playback without restarting at each syllable.");
            }
            previousActive = active;
            previousWeight = weight;
        }
        TestContext.WriteLine(fps + "fps syllables: active switches=" + switches + ", max lifecycle-gain step=" + maximumDelta);
        Assert.That(switches, Is.EqualTo(1), "Acquire once, then stay in the phrase-level rest until sustained silence or explicit release.");
        Assert.That(maximumDelta, Is.LessThanOrEqualTo(1f / (fps * .18f) + .001f));
        Assert.That(maximumWeight, Is.EqualTo(1f), "Voice activity must not become a permanent dilution of the authored pose.");
    }

    [TestCase(30, .05f)]
    [TestCase(30, .10f)]
    [TestCase(30, .15f)]
    [TestCase(60, .05f)]
    [TestCase(60, .10f)]
    [TestCase(60, .15f)]
    public void BriefWordGapsDoNotReleaseAndReacquireTheTalkLayer(int fps, float gap)
    {
        float[] track = Enumerable.Range(0, 400).Select(i => i >= 100 && i < 100 + Mathf.RoundToInt(gap * 100f) ? 0f : .2f).ToArray();
        using var f = new Fixture(track, 100f);
        for (int frame = 0; frame < fps * 3; frame++)
        {
            float at = frame / (float)fps;
            object sample = f.Tick(at);
            if (at >= .25f) Assert.That(Active(sample), Is.True, "Word-gap release at " + at + " for " + gap + " seconds");
        }
    }

    [TestCase(30)]
    [TestCase(60)]
    public void SustainedSilenceFadesOnceWithin450MillisecondsInsteadOfPopping(int fps)
    {
        float[] track = Enumerable.Range(0, 400).Select(i => i < 100 ? .2f : 0f).ToArray();
        using var f = new Fixture(track, 100f);
        int switches = 0;
        bool previousActive = false;
        float releasedAt = -1f, previousWeight = 0f, maximumDelta = 0f;
        for (int frame = 0; frame < fps * 3; frame++)
        {
            float at = frame / (float)fps;
            object sample = f.Tick(at);
            bool active = Active(sample);
            if (active != previousActive)
            {
                switches++;
                if (!active) releasedAt = at;
            }
            float weight = Field<float>(sample, "Weight");
            maximumDelta = Mathf.Max(maximumDelta, Mathf.Abs(weight - previousWeight));
            if (at > 1f && at < 1.1f) Assert.That(active, Is.True, "Do not snap the arms down at the first unvoiced frame.");
            previousActive = active;
            previousWeight = weight;
        }
        TestContext.WriteLine(fps + "fps sustained silence: releasedAt=" + releasedAt + ", max weight step=" + maximumDelta);
        Assert.That(switches, Is.EqualTo(2));
        Assert.That(releasedAt, Is.InRange(1.3f, 1.45f));
        Assert.That(maximumDelta, Is.LessThanOrEqualTo(1f / (fps * .18f) + .001f), "Only lifecycle gain fades; authored joints use full pose plus source-switch inertia.");
    }

    [TestCase(false, false)]
    [TestCase(true, true)]
    public void ExplicitPauseAndTaskTakeoverStillReleaseImmediatelyDuringUnvoicedHold(bool playing, bool blocked)
    {
        float[] track = Enumerable.Range(0, 300).Select(i => i < 100 ? .2f : 0f).ToArray();
        using var f = new Fixture(track, 100f);
        for (int frame = 0; frame <= 105; frame++) f.Tick(frame / 100f);
        Assert.That(Active(f.Tick(1.06f)), Is.True, "Setup must be in the short unvoiced hold.");
        Assert.That(Active(f.Tick(1.07f, playing, blocked)), Is.False, "Audio/task ownership always overrides the phrase hold synchronously.");
        Call(f.Value, "Stop");
        Assert.That(Active(f.Tick(1.08f)), Is.False);
        Assert.That(Call(f.Value, "Start", 1L, track, 100f), Is.False, "Stop does not make a retired generation replayable.");
    }

    [Test]
    public void PhonemeLoudnessDoesNotMultiplyTheSustainedRestWeight()
    {
        float[] track = Enumerable.Range(0, 300).Select(i => i % 3 == 0 ? .08f : i % 3 == 1 ? .35f : .12f).ToArray();
        using var f = new Fixture(track, 100f);
        var weights = new List<float>();
        for (int frame = 0; frame < 180; frame++)
        {
            object sample = f.Tick(frame / 60f);
            if (frame >= 20) weights.Add(Field<float>(sample, "Weight"));
        }
        Assert.That(weights.Max() - weights.Min(), Is.LessThan(.000001f), "Sound supplies voicing/accent timing; the arms must not pulse at phoneme volume.");
    }

    [Test]
    public void SamePhraseStyleCueDoesNotRestartRestAttack()
    {
        using var f = new Fixture(Enumerable.Repeat(.2f, 300).ToArray(), 100f);
        object before = null;
        for (int frame = 0; frame <= 50; frame++) before = f.Tick(frame / 100f);
        Assert.That(Call(f.Value, "QueuePerformanceCue", 1L, 1L, "auto", "neutral", "moderate", .65f), Is.True);
        object after = f.Tick(.51f);
        Assert.That(Active(after), Is.True);
        Assert.That(Field<float>(after, "Weight"), Is.EqualTo(Field<float>(before, "Weight")).Within(.000001f));
    }

    private sealed class Fixture : IDisposable
    {
        public readonly object Value;
        private readonly ScriptableObject library;
        public Fixture(float[] track, float frameRate)
        {
            library = ScriptableObject.CreateInstance(Library);
            // Isolate rest gating from acoustic accent selection. Existing
            // scheduler tests separately assert exact prep/hold/stroke targets.
            JsonUtility.FromJsonOverwrite("{\"Entries\":[{\"Id\":\"talk_test_loop\",\"UpperBody\":true,\"Loop\":true," +
                "\"Duration\":5,\"Layer\":\"talk\",\"Energy\":\"animated\"}]}", library);
            Value = Activator.CreateInstance(Scheduler);
            Call(Value, "Initialize", library, 0);
            Assert.That(Call(Value, "Start", 1L, track, frameRate), Is.True);
        }
        public object Tick(float at, bool playing = true, bool blocked = false) => Call(Value, "Tick", 1L, at, playing, blocked);
        public void Dispose() => Object.DestroyImmediate(library);
    }
}
