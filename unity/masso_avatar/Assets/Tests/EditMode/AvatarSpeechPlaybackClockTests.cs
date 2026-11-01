using System;
using System.Collections.Generic;
using System.Reflection;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NUnit.Framework;

public sealed class AvatarSpeechPlaybackClockTests
{
    private static Type RuntimeType(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static readonly Type PacketType = RuntimeType("AvatarSpeechPlaybackClockPacket");
    private static object Clock() => Activator.CreateInstance(RuntimeType("AvatarSpeechPlaybackClock"));
    private static object Call(object target, string method, params object[] args) => target.GetType()
        .GetMethod(method, BindingFlags.Public | BindingFlags.Instance).Invoke(target, args);
    private static T Property<T>(object target, string name) => (T)target.GetType().GetProperty(name).GetValue(target);
    private static bool Parse(string json, out object packet)
    {
        object[] args = { json, null };
        bool result = (bool)PacketType.GetMethod("TryParse").Invoke(null, args);
        packet = args[1];
        return result;
    }

    private static JObject Json(string state = "start", string id = "audio-a", long generation = 8, long sequence = 1,
        long position = 0, long duration = 0) => new()
    {
        ["protocolVersion"] = 1, ["playbackId"] = id, ["generation"] = generation,
        ["turnId"] = "turn-1", ["utteranceId"] = "utterance-1", ["sequence"] = sequence,
        ["state"] = state, ["positionMs"] = position, ["durationMs"] = duration,
        ["source"] = "wav", ["authoritative"] = true,
    };
    private static object Packet(JObject json)
    {
        Assert.That(Parse(json.ToString(Formatting.None), out object packet), Is.True,
            "Test packet must satisfy the wire protocol before state-machine checks.");
        return packet;
    }
    private static bool Apply(object clock, JObject json, float now) => (bool)Call(clock, "Apply", Packet(json), now);
    private static bool Playing(object clock, float now) => (bool)Call(clock, "IsPlaying", now);
    private static float Position(object clock, float now) => (float)Call(clock, "Position", now);

    [Test]
    public void ParserRejectsDuplicateUnknownAndTrailingPayload()
    {
        string valid = Json().ToString(Formatting.None);
        Assert.That(Parse(valid, out _), Is.True);
        foreach (string invalid in new[]
        {
            valid.Insert(1, "\"state\":\"start\","),
            valid.Insert(1, "\"unrecognized\":true,"),
            valid + "{}", valid + " true", "[]", "null", "```json\n" + valid + "\n```",
        }) Assert.That(Parse(invalid, out _), Is.False, invalid);
    }

    [Test]
    public void ParserRequiresEveryIdentityFieldAndExactJsonTypes()
    {
        foreach (string required in new[] { "protocolVersion", "playbackId", "generation", "turnId", "utteranceId",
            "sequence", "state", "positionMs", "source", "authoritative" })
        {
            JObject missing = Json(); missing.Remove(required);
            Assert.That(Parse(missing.ToString(Formatting.None), out _), Is.False, required);
            JObject nulled = Json(); nulled[required] = JValue.CreateNull();
            Assert.That(Parse(nulled.ToString(Formatting.None), out _), Is.False, required + " null");
        }
        var invalidValues = new Dictionary<string, JToken[]>
        {
            ["generation"] = new JToken[] { "8", 8.0, true },
            ["sequence"] = new JToken[] { "1", 1.5, false },
            ["protocolVersion"] = new JToken[] { "1", 1.0 },
            ["positionMs"] = new JToken[] { "0", .5 },
            ["durationMs"] = new JToken[] { "10", 10.0 },
            ["frameRate"] = new JToken[] { "30", 30.0 },
            ["authoritative"] = new JToken[] { "true", 1 },
            ["playbackId"] = new JToken[] { 1, true },
            ["state"] = new JToken[] { 1, new JArray("start") },
        };
        foreach (var field in invalidValues)
            foreach (JToken value in field.Value)
            {
                JObject invalid = Json(); invalid[field.Key] = value;
                Assert.That(Parse(invalid.ToString(Formatting.None), out _), Is.False, field.Key + " " + value);
            }
    }

    [Test]
    public void ParserBoundsIdsNumbersStatesAndSourceAuthority()
    {
        var invalid = new Dictionary<string, JToken[]>
        {
            ["playbackId"] = new JToken[] { "", new string('x', 161), "bad\nidentity" },
            ["turnId"] = new JToken[] { "", new string('x', 161), "\t" },
            ["utteranceId"] = new JToken[] { "", new string('x', 161), "\0" },
            ["protocolVersion"] = new JToken[] { 0, 2 },
            ["generation"] = new JToken[] { -1L, 9007199254740992L },
            ["sequence"] = new JToken[] { 0L, -1L, 9007199254740992L },
            ["positionMs"] = new JToken[] { -1L, 86400001L },
            ["durationMs"] = new JToken[] { -1L, 86400001L },
            ["state"] = new JToken[] { "playing", "START", "enqueue" },
            ["source"] = new JToken[] { "network", "WAV" },
        };
        foreach (var field in invalid)
            foreach (JToken value in field.Value)
            {
                JObject json = Json(); json[field.Key] = value;
                Assert.That(Parse(json.ToString(Formatting.None), out _), Is.False, field.Key + " " + value);
            }
        JObject beyondEnd = Json(position: 4001, duration: 2000);
        Assert.That(Parse(beyondEnd.ToString(Formatting.None), out _), Is.False);
        JObject system = Json(); system["source"] = "system";
        Assert.That(Parse(system.ToString(Formatting.None), out _), Is.False);
        system["authoritative"] = false;
        Assert.That(Parse(system.ToString(Formatting.None), out _), Is.True);
    }

    [Test]
    public void EnvelopeIsStartOnlyFiniteBoundedAndHasValidFrameRate()
    {
        JObject valid = Json(); valid["envelope"] = new JArray(0, .2, 1); valid["frameRate"] = 30;
        Assert.That(Parse(valid.ToString(Formatting.None), out _), Is.True);
        foreach (JToken envelope in new JToken[]
        {
            new JArray(), new JArray(-.01), new JArray(1.01), new JArray("0.2"),
            new JArray(true), JValue.CreateNull(), new JObject(),
        })
        {
            JObject json = (JObject)valid.DeepClone(); json["envelope"] = envelope;
            Assert.That(Parse(json.ToString(Formatting.None), out _), Is.False);
        }
        foreach (int fps in new[] { 0, -1, 121 })
        {
            JObject json = (JObject)valid.DeepClone(); json["frameRate"] = fps;
            Assert.That(Parse(json.ToString(Formatting.None), out _), Is.False);
        }
        foreach (string state in new[] { "pause", "resume", "update", "stop" })
        {
            JObject json = (JObject)valid.DeepClone(); json["state"] = state;
            Assert.That(Parse(json.ToString(Formatting.None), out _), Is.False);
        }
        var samples = new JArray(); for (int i = 0; i < 7200; i++) samples.Add(.1f);
        JObject boundary = (JObject)valid.DeepClone(); boundary["envelope"] = samples;
        Assert.That(Parse(boundary.ToString(Formatting.None), out _), Is.True);
        samples.Add(.1f);
        Assert.That(Parse(boundary.ToString(Formatting.None), out _), Is.False);
        Assert.That(Parse(valid.ToString(Formatting.None).Replace("0.2", "NaN"), out _), Is.False);
        Assert.That(Parse(valid.ToString(Formatting.None).Replace("0.2", "Infinity"), out _), Is.False);
    }

    [Test]
    public void UpdatesRequireMatchingIdentityAndIncreasingSequence()
    {
        object clock = Clock();
        Assert.That(Apply(clock, Json(), 10f), Is.True);
        Assert.That(Apply(clock, Json("update", sequence: 2, position: 400), 10.4f), Is.True);
        Assert.That(Apply(clock, Json("update", sequence: 2, position: 500), 10.5f), Is.False);
        foreach (string mismatch in new[] { "playbackId", "generation", "turnId", "utteranceId", "source" })
        {
            JObject invalid = Json("update", sequence: 3, position: 500);
            invalid[mismatch] = mismatch == "generation" ? new JValue(9) : new JValue(mismatch == "source" ? "pcm" : "other");
            Assert.That(Apply(clock, invalid, 10.5f), Is.False, mismatch);
        }
        Assert.That(Position(clock, 10.4f), Is.EqualTo(.4f).Within(.001f));
        Assert.That(Apply(clock, Json("resume", sequence: 3, position: 550), 10.55f), Is.True);
    }

    [Test]
    public void GenerationWatermarkRetiresOldIdsButAllowsAnotherChunkAtSameGeneration()
    {
        object clock = Clock();
        Assert.That(Apply(clock, Json(), 0f), Is.True);
        long first = Property<long>(clock, "Epoch");
        Assert.That(Apply(clock, Json(id: "lower", generation: 7), .1f), Is.False);
        Assert.That(Apply(clock, Json(id: "audio-a", generation: 9, sequence: 2), .1f), Is.False);
        Assert.That(Apply(clock, Json(id: "audio-b", generation: 8), .2f), Is.True);
        Assert.That(Property<long>(clock, "Epoch"), Is.EqualTo(first + 1));
        Assert.That(Apply(clock, Json("update", id: "audio-a", sequence: 9), .3f), Is.False);
        Assert.That(Apply(clock, Json(id: "audio-a", generation: 9), .3f), Is.False);
        Assert.That(Property<string>(clock, "PlaybackId"), Is.EqualTo("audio-b"));
    }

    [Test]
    public void PauseFreezesUntilResumeWhichUsesTheActualReceiptPosition()
    {
        object clock = Clock();
        Assert.That(Apply(clock, Json(position: 1000, duration: 10000), 100f), Is.True);
        Assert.That(Position(clock, 100.1f), Is.EqualTo(1.1f).Within(.001f));
        Assert.That(Apply(clock, Json("pause", sequence: 2, position: 1200, duration: 10000), 100.2f), Is.True);
        Assert.That(Property<bool>(clock, "Paused"), Is.True);
        Assert.That(Playing(clock, 101f), Is.False);
        Assert.That(Position(clock, 500f), Is.EqualTo(1.2f).Within(.001f));
        // A queued update cannot silently undo a user's pause. Only an explicit
        // resume/actual-start receipt may re-enable extrapolation and gestures.
        Apply(clock, Json("update", sequence: 3, position: 1400, duration: 10000), 100.3f);
        Assert.That(Playing(clock, 100.31f), Is.False);
        Assert.That(Position(clock, 100.31f), Is.EqualTo(1.4f).Within(.001f));
        Assert.That(Position(clock, 500f), Is.EqualTo(1.4f).Within(.001f),
            "A newer native receipt may calibrate the cursor, but pause never extrapolates it.");
        Assert.That(Apply(clock, Json("resume", sequence: 4, position: 1600, duration: 10000), 101f), Is.True);
        Assert.That(Property<bool>(clock, "Paused"), Is.False);
        Assert.That(Playing(clock, 101.3f), Is.True);
        Assert.That(Position(clock, 101.3f), Is.EqualTo(1.9f).Within(.001f));
    }

    [Test]
    public void SparseReceiptsExtrapolateOnlyForPoint65SecondsThenStopGestures()
    {
        object clock = Clock();
        Apply(clock, Json(position: 1000), 0f);
        Assert.That(Playing(clock, .649f), Is.True);
        Assert.That(Playing(clock, .651f), Is.False);
        Assert.That(Position(clock, 5f), Is.EqualTo(1.65f).Within(.0001f));
        Assert.That(Playing(clock, -.1f), Is.False);
        Assert.That(Position(clock, -.1f), Is.EqualTo(1f).Within(.0001f));
        Assert.That(Apply(clock, Json("update", sequence: 2, position: 2100), 5f), Is.True);
        Assert.That(Playing(clock, 5f), Is.True);
        Assert.That(Position(clock, 5f), Is.EqualTo(2.1f).Within(.0001f));
    }

    [Test]
    public void SmallNativeCursorCorrectionsStayContinuousMonotonicAndSettleWithoutRepeatingAccent()
    {
        foreach (int measuredMs in new[] { 1170, 1125, 1330 })
        {
            object clock = Clock();
            Apply(clock, Json(position: 1000), 0f);
            const float receivedAt = .25f, window = .25f;
            float before = Position(clock, receivedAt);
            Assert.That(Apply(clock, Json("update", sequence: 2, position: measuredMs), receivedAt), Is.True);
            Assert.That(Position(clock, receivedAt), Is.EqualTo(before).Within(.00001f),
                "A sub-125ms native correction starts at the currently displayed cursor.");
            float previous = before;
            const float accent = 1.2775f;
            int crossings = 0;
            for (int step = 1; step <= 250; step++)
            {
                float at = receivedAt + step / 1000f;
                float cursor = Position(clock, at);
                Assert.That(cursor, Is.GreaterThanOrEqualTo(previous - .000001f),
                    "The cursor must not move backward and cross a stroke a second time: " + measuredMs);
                if (previous < accent && cursor >= accent) crossings++;
                previous = cursor;
            }
            Assert.That(Position(clock, receivedAt + window), Is.EqualTo(measuredMs / 1000f + window).Within(.00001f));
            Assert.That(crossings, Is.EqualTo(1), "The same acoustic marker is crossed exactly once.");
        }
    }

    [Test]
    public void RepeatedActualCursorReceiptsFreezeBufferingUntilActualPlaybackAdvances()
    {
        object clock = Clock();
        Apply(clock, Json(), 0f);
        long epoch = Property<long>(clock, "Epoch");
        for (int receipt = 1; receipt <= 6; receipt++)
        {
            float at = receipt * .2f;
            Assert.That(Apply(clock, Json("update", sequence: receipt + 1, position: 0), at), Is.True);
            Assert.That(Playing(clock, at), Is.False,
                "Receiving packets is not proof that the audio device advanced during buffering.");
            Assert.That(Position(clock, at + .1f), Is.Zero);
            Assert.That(Property<long>(clock, "Epoch"), Is.EqualTo(epoch));
        }
        Assert.That(Apply(clock, Json("update", sequence: 8, position: 20), 1.4f), Is.True);
        Assert.That(Playing(clock, 1.4f), Is.True);
        Assert.That(Position(clock, 1.4f), Is.EqualTo(.02f).Within(.00001f));
        Assert.That(Position(clock, 1.5f), Is.EqualTo(.12f).Within(.00001f));
        Assert.That(Apply(clock, Json("update", sequence: 9, position: 20), 1.6f), Is.True);
        Assert.That(Playing(clock, 1.6f), Is.False);
        Assert.That(Position(clock, 2f), Is.EqualTo(.02f).Within(.00001f));
    }

    [Test]
    public void OmittedDurationOnUpdatePreservesTheKnownAudioEnd()
    {
        object clock = Clock();
        Apply(clock, Json(position: 900, duration: 1000), 0f);
        JObject update = Json("update", sequence: 2, position: 950);
        update.Remove("durationMs");
        Assert.That(Apply(clock, update, .1f), Is.True);
        Assert.That(Position(clock, 1f), Is.EqualTo(1f).Within(.0001f));
    }

    [Test]
    public void EnvelopeBindingCopiesPacketAndRejectsNanOrMismatchedTracks()
    {
        object clock = Clock();
        JObject json = Json(); json["envelope"] = new JArray(0f, .2f, .8f); json["frameRate"] = 30;
        object packet = Packet(json);
        Assert.That(Call(clock, "Apply", packet, 0f), Is.True);
        ((float[])PacketType.GetField("envelope").GetValue(packet))[1] = .7f;
        Assert.That(Call(clock, "MatchesEnvelope", new[] { 0f, .2f, .8f }, 30), Is.True);
        Assert.That(Call(clock, "MatchesEnvelope", new[] { 0f, .2f, .8f }, 60), Is.False);
        Assert.That(Call(clock, "MatchesEnvelope", new[] { 0f, .2f }, 30), Is.False);
        Assert.That(Call(clock, "MatchesEnvelope", new[] { 0f, .3f, .8f }, 30), Is.False);
        Assert.That(Call(clock, "MatchesEnvelope", new[] { 0f, float.NaN, .8f }, 30), Is.False);
        Assert.That(Call(clock, "MatchesEnvelope", new[] { 0f, float.PositiveInfinity, .8f }, 30), Is.False);
    }

    [Test]
    public void SystemTtsWithoutPlaybackProofCannotAnimateAsAuthoritativeAudio()
    {
        object clock = Clock();
        JObject json = Json(); json["source"] = "system"; json["authoritative"] = false;
        Assert.That(Apply(clock, json, 0f), Is.True);
        Assert.That(Playing(clock, .1f), Is.False);
        Assert.That(Position(clock, .5f), Is.Zero);
    }

    [Test]
    public void StopAndResetRetireTheCurrentIdentityAndDoNotReenterIt()
    {
        object clock = Clock();
        Apply(clock, Json(), 0f);
        Assert.That(Apply(clock, Json("stop", sequence: 2, position: 500), .5f), Is.True);
        Assert.That(Property<bool>(clock, "Active"), Is.False);
        Assert.That(Playing(clock, .51f), Is.False);
        Assert.That(Apply(clock, Json(id: "audio-a", generation: 9), .6f), Is.False);
        Assert.That(Apply(clock, Json(id: "audio-b", generation: 9), .7f), Is.True);
        long epoch = Property<long>(clock, "Epoch");
        Call(clock, "Reset", false);
        Assert.That(Property<bool>(clock, "Active"), Is.False);
        Assert.That(Property<float[]>(clock, "Envelope"), Is.Null);
        Assert.That(Apply(clock, Json(id: "audio-b", generation: 10), .8f), Is.False);
        Assert.That(Apply(clock, Json("update", id: "audio-b", generation: 9, sequence: 3), .8f), Is.False);
        Assert.That(Apply(clock, Json(id: "audio-c", generation: 10), .9f), Is.True);
        Assert.That(Property<long>(clock, "Epoch"), Is.EqualTo(epoch + 1));
    }

    [Test]
    public void OrdinaryResetKeepsWatermarkAndExplicitOwnerResetAllowsNewCounter()
    {
        object clock = Clock();
        Apply(clock, Json(generation: 10), 0f);
        Call(clock, "Reset", false);
        Assert.That(Apply(clock, Json(id: "unseen-old", generation: 9), .1f), Is.False);
        Assert.That(Apply(clock, Json(id: "audio-b", generation: 10), .2f), Is.True);
        Call(clock, "Reset", true);
        Assert.That(Apply(clock, Json(id: "fresh-owner", generation: 0), .3f), Is.True);
        Assert.That(Apply(clock, Json(id: "audio-a", generation: 11), .4f), Is.False,
            "Explicit owner reset still does not resurrect a known retired playback identity.");
    }

    [Test]
    public void InvalidPacketOrReceiptClockDoesNotReplaceAnActiveSession()
    {
        object clock = Clock();
        Apply(clock, Json(), 0f);
        Assert.That(Call(clock, "Apply", null, .1f), Is.False);
        Assert.That(Call(clock, "Apply", Packet(Json(id: "b")), float.NaN), Is.False);
        Assert.That(Call(clock, "Apply", Packet(Json(id: "b")), float.PositiveInfinity), Is.False);
        Assert.That(Property<string>(clock, "PlaybackId"), Is.EqualTo("audio-a"));
    }
}
