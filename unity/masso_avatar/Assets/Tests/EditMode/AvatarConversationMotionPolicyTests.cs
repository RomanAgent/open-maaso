using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;

public sealed class AvatarConversationMotionPolicyTests
{
    private static readonly Type Policy = Type.GetType("Maaso.Avatar.AvatarConversationMotionPolicy, Assembly-CSharp", true);
    private static object New(int seed = 1729) => Activator.CreateInstance(Policy, seed);
    private static object Call(object value, string method, params object[] args) => Policy.GetMethod(method).Invoke(value, args);
    private static T Field<T>(object value, string name) => (T)value.GetType().GetField(name).GetValue(value);
    private static object Advance(object policy, float at, bool blocked = false, bool busy = false) => Call(policy, "Advance", at, blocked, busy);
    private static void Played(object policy, object decision, float now, float duration = 4f, bool loop = true) =>
        Call(policy, "NotifyPlayed", Field<string>(decision, "ClipId"), now, duration, loop);

    [Test]
    public void ShortSpeakingGapKeepsListenAndDoesNotRestartItsLoop()
    {
        object p = New();
        Call(p, "SetPhase", "listening", 0f);
        Assert.That(Advance(p, .2f), Is.Null);
        object first = Advance(p, .4f);
        Assert.That(Field<string>(first, "ClipId"), Is.EqualTo("idle_shrug"));
        Played(p, first, .4f);
        Call(p, "SetPhase", "speaking", 1f); Assert.That(Advance(p, 1.1f), Is.Null);
        Call(p, "SetPhase", "listening", 1.2f); Assert.That(Advance(p, 1.7f), Is.Null);
        Assert.That((string)Policy.GetProperty("ActiveId").GetValue(p), Is.EqualTo(Field<string>(first, "ClipId")));
    }

    [Test]
    public void LongSpeechResumesSameListenAtSavedPhase()
    {
        object p = New(); Call(p, "SetPhase", "listening", 0f);
        object first = Advance(p, .4f); Played(p, first, .4f, 4f);
        Call(p, "SetPhase", "speaking", 1f); Assert.That(Advance(p, 1.4f), Is.Null);
        Call(p, "SetPhase", "listening", 3f);
        object resume = Advance(p, 3.4f);
        Assert.That(Field<string>(resume, "ClipId"), Is.EqualTo(Field<string>(first, "ClipId")));
        Assert.That(Field<float>(resume, "NormalizedTime"), Is.EqualTo(.25f).Within(.001f));
    }

    [Test]
    public void RepeatedPhaseHintsDoNotResetHysteresis()
    {
        object p = New(); Call(p, "SetPhase", "listening", 0f);
        Call(p, "SetPhase", "listening", .2f);
        Assert.That(Advance(p, .36f), Is.Not.Null);
    }

    [Test]
    public void NoFidgetsDuringListeningThinkingSpeakingOrShortSilence()
    {
        foreach (string phase in new[] { "listening", "thinking", "speaking" })
        {
            object p = New(); Call(p, "SetPhase", phase, 0f);
            object first = Advance(p, .4f); if (first != null) Played(p, first, .4f);
            for (int tick = 1; tick < 200; tick++) Assert.That(Advance(p, tick), Is.Null, phase);
        }
        object idle = New(); object start = Advance(idle, .4f); Played(idle, start, .4f);
        for (int tick = 1; tick < 8; tick++) Assert.That(Advance(idle, tick), Is.Null);
    }

    [Test]
    public void TaskOwnershipResetsStableSilenceAndPreservesLoopPhase()
    {
        object p = New(); object first = Advance(p, .4f); Played(p, first, .4f);
        Assert.That(Advance(p, 7f, true), Is.Null);
        Assert.That(Advance(p, 100f, true), Is.Null);
        Assert.That(Advance(p, 101f), Is.Null);
        object resume = Advance(p, 101.4f);
        Assert.That(resume, Is.Not.Null);
        Assert.That(Field<bool>(resume, "IsFidget"), Is.False);
        Played(p, resume, 101.4f);
        Assert.That(Advance(p, 107f), Is.Null, "The task must not count as eight seconds of free idle.");
    }

    [Test]
    public void FailedClipIsNotRetriedAndAllUnavailablePoolFailsClosed()
    {
        object p = New();
        var seen = new HashSet<string>();
        for (int index = 0; index < 1; index++)
        {
            float now = 1f + index;
            object decision = Advance(p, now);
            string id = Field<string>(decision, "ClipId");
            Assert.That(seen.Add(id), Is.True);
            Call(p, "Reject", id, now);
        }
        Assert.That(Advance(p, 5f), Is.Null);
    }

    [Test]
    public void SeedProducesSameBoundedFidgetSequenceAndNoFastRepeats()
    {
        object a = New(99), b = New(99);
        float lastFidget = -100f;
        int fidgets = 0;
        for (int tick = 0; tick <= 2400; tick++)
        {
            float now = tick * .1f;
            object da = Advance(a, now), db = Advance(b, now);
            Assert.That(db == null, Is.EqualTo(da == null));
            if (da == null) continue;
            Assert.That(Field<string>(db, "ClipId"), Is.EqualTo(Field<string>(da, "ClipId")));
            bool fidget = Field<bool>(da, "IsFidget");
            if (fidget)
            {
                Assert.That(now - lastFidget, Is.GreaterThanOrEqualTo(11.9f));
                lastFidget = now; fidgets++;
            }
            Played(a, da, now, 4f, !fidget); Played(b, db, now, 4f, !fidget);
        }
        Assert.That(fidgets, Is.InRange(2, 20));
    }

    [Test]
    public void ResetAndClockRollbackDropPendingAndOldPhase()
    {
        object p = New(); object first = Advance(p, 1f); Assert.That(first, Is.Not.Null);
        Call(p, "Reset", 5f);
        Assert.That(Advance(p, 5.1f), Is.Null);
        Assert.That(Advance(p, 5.4f), Is.Not.Null);
        Assert.That(Advance(p, 0f), Is.Null);
        Assert.That(Advance(p, .4f), Is.Not.Null);
    }

    [Test]
    public void BoundedPlayerEndRenewsAtSavedPhaseInsteadOfGoingSilent()
    {
        object p = New(); object first = Advance(p, .4f); Played(p, first, .4f, 4f);
        Call(p, "PlaybackEnded", 30.4f);
        object renewed = Advance(p, 30.4f);
        Assert.That(Field<string>(renewed, "ClipId"), Is.EqualTo(Field<string>(first, "ClipId")));
        Assert.That(Field<float>(renewed, "NormalizedTime"), Is.EqualTo(.5f).Within(.001f));
        Assert.That(Field<bool>(renewed, "IsFidget"), Is.False);
    }

    [TestCase("idle")]
    [TestCase("listening")]
    public void EverySeedStartsAndRenewsWithNaturalHandsDownBase(string phase)
    {
        for (int seed = 1; seed <= 128; seed++)
        {
            object p = New(seed);
            Call(p, "SetPhase", phase, 0f);
            object first = Advance(p, .4f);
            string id = Field<string>(first, "ClipId");
            Assert.That(id, Is.EqualTo("idle_shrug"), "seed=" + seed);
            Assert.That(Field<bool>(first, "IsFidget"), Is.False);
            Played(p, first, .4f, 7f);
            Call(p, "PlaybackEnded", 30.4f);
            object renewed = Advance(p, 30.4f);
            Assert.That(Field<string>(renewed, "ClipId"), Is.EqualTo(id));
            Assert.That(Field<bool>(renewed, "IsFidget"), Is.False);
        }
    }

    [Test]
    public void BentArmIdlePlaysOneCycleThenReturnsToRetainedNeutralBase()
    {
        object p = New(99);
        string neutral = null;
        int bentArmEpisodes = 0;
        float playerEndsAt = float.PositiveInfinity;
        for (int tick = 4; tick <= 6000; tick++)
        {
            float now = tick * .1f;
            if (now >= playerEndsAt)
            {
                Call(p, "PlaybackEnded", now);
                playerEndsAt = float.PositiveInfinity;
            }
            object decision = Advance(p, now);
            if (decision == null) continue;
            string id = Field<string>(decision, "ClipId");
            bool fidget = Field<bool>(decision, "IsFidget");
            if (!fidget)
            {
                neutral ??= id;
                Assert.That(id, Is.EqualTo(neutral), "Interludes must not replace base-loop memory.");
            }
            float duration = id == "annie_idle_c" ? 6f : 4f;
            // The actual idle_c resource loops. Admission must nevertheless
            // remain transient without waiting for a player-end notification.
            Played(p, decision, now, duration, id == "annie_idle_c" || !fidget);
            playerEndsAt = now + (fidget ? duration : 30f);
            if (id != "annie_idle_c") continue;
            bentArmEpisodes++;
            Assert.That(fidget, Is.True);
            Assert.That(Field<float>(decision, "NormalizedTime"), Is.Zero);
            Assert.That(Advance(p, now + 5.9f), Is.Null);
            object resumed = Advance(p, now + 6.01f);
            Assert.That(Field<string>(resumed, "ClipId"), Is.EqualTo(neutral));
            Assert.That(Field<bool>(resumed, "IsFidget"), Is.False);
            Played(p, resumed, now + 6.01f);
            playerEndsAt = now + 36.01f;
            tick += 61;
        }
        Assert.That(bentArmEpisodes, Is.GreaterThan(0), "The bounded pose remains available as an occasional variation.");
    }

    [TestCase("speaking")]
    [TestCase("thinking")]
    [TestCase("listening")]
    public void ConversationChangeInterruptsBentArmInterlude(string phase)
    {
        object p = New(99);
        object interlude = null;
        float now = .4f;
        for (; now < 600f; now += 1f)
        {
            object decision = Advance(p, now);
            if (decision == null) continue;
            string id = Field<string>(decision, "ClipId");
            Played(p, decision, now, id == "annie_idle_c" ? 6f : 4f, id == "annie_idle_c" || !Field<bool>(decision, "IsFidget"));
            if (id == "annie_idle_c") { interlude = decision; break; }
        }
        Assert.That(interlude, Is.Not.Null);
        Call(p, "SetPhase", phase, now + .1f);
        object next = Advance(p, now + .5f);
        Assert.That((string)Policy.GetProperty("ActiveId").GetValue(p), Is.Null);
        if (phase == "listening")
            Assert.That(Field<string>(next, "ClipId"), Is.EqualTo("idle_shrug"));
        else Assert.That(next, Is.Null);
    }
}
