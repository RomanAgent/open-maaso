using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class AvatarSmileNaturalnessTests
{
    private const BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    private static readonly ExpressionKey[] Vowels =
        { ExpressionKey.Aa, ExpressionKey.Ih, ExpressionKey.Ou, ExpressionKey.Ee, ExpressionKey.Oh };
    private static object Call(object target, string name, params object[] args) => target.GetType().GetMethods(Flags)
        .Single(m => m.Name == name && m.GetParameters().Length == args.Length).Invoke(target, args);
    private static object Field(object target, string name) => target.GetType().GetField(name, Flags).GetValue(target);
    private static void Send(Component receiver, string method, JObject value) => Call(receiver, "OnFlutterCommand",
        new JObject { ["method"] = method, ["json"] = value.ToString() }.ToString());

    [TestCase("Joy")]

    public void SourceNeutralHasNoForcedSmileAndSmileGradientsCoordinateEyes(string model)
    {
        using var f = new Fixture(model);
        f.Smile(0f);
        Assert.That(f.MouthSmile, Is.Zero);
        Assert.That(f.EyeSmile, Is.Zero);
        Assert.That(f.CheekSmile, Is.Zero);
        float previous = 0f;
        foreach (float intensity in new[] { .15f, .35f, .65f, 1f })
        {
            f.Smile(intensity);
            Assert.That(f.MouthSmile, Is.GreaterThan(previous));
            Assert.That(f.MouthSmile, Is.LessThan(65f));
            Assert.That(f.Weight(model == "Joy" ? "Smile_L" : "V_Open"), Is.Zero,
                "Duplicate smile aliases and unrequested vowels must not open the mouth.");
            if (intensity >= .65f)
            {
                Assert.That(f.EyeSmile, Is.GreaterThan(0f));
                Assert.That(f.CheekSmile, Is.GreaterThan(0f));
            }
            Assert.That(f.EyeSmile, Is.LessThanOrEqualTo(21f));
            Assert.That(f.Weight(model == "Joy" ? "blink_upper_down.L" : "Eye_Blink_L"), Is.LessThan(10f),
                "A broad smile is not a closed-eye expression.");
            previous = f.MouthSmile;
        }
        f.Smile(0f);
        Assert.That(f.MouthSmile, Is.Zero);
        Assert.That(f.EyeSmile, Is.Zero);
        Assert.That(f.CheekSmile, Is.Zero);
    }

    [TestCase("Joy", "aa")]
    [TestCase("Joy", "ih")]
    [TestCase("Joy", "ou")]
    [TestCase("Joy", "ee")]
    [TestCase("Joy", "oh")]
    [TestCase("Joy", "pp")]
    [TestCase("Joy", "ff")]







    public void SmileCoordinatesAroundEverySpeechVisemeWithoutOwningSpeech(string model, string viseme)
    {
        using var f = new Fixture(model);
        f.Timeline(viseme);
        var neutralSpeech = f.SpeechWeights();
        f.Smile(.8f);
        var smilingSpeech = f.SpeechWeights();
        foreach (var item in neutralSpeech)
            Assert.That(smilingSpeech[item.Key], Is.EqualTo(item.Value).Within(.0001f),
                model + " " + viseme + " " + item.Key + ": smile cannot alter the speech-owned articulation.");
        float spokenSmile = f.MouthSmile;
        Send(f.Receiver, "stopLipSync", new JObject());
        f.Process();
        float silentSmile = f.MouthSmile;
        Assert.That(spokenSmile, Is.LessThan(silentSmile),
            "The mouth corner yields to the speech articulation; eyes and cheeks keep the affect.");
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
        f.Smile(0f);
        Assert.That(f.MouthSmile, Is.Zero);
    }

    [TestCase("Joy")]

    public void RepeatedSpeechAndSilentFramesDoNotAccumulateSmileOrLeaveAnOpenJaw(string model)
    {
        using var f = new Fixture(model);
        for (int turn = 0; turn < 4; turn++)
        {
            f.Smile(.6f);
            float peak = f.MouthSmile;
            for (int frame = 0; frame < 20; frame++)
            {
                Call(f.Receiver, "ApplyExpression"); f.Process();
                Assert.That(f.MouthSmile, Is.EqualTo(peak).Within(.001f));
            }
            f.Timeline("aa");
            Call(f.Receiver, "ApplyLipSyncFrame", 1f); f.Process();
            foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
            Assert.That(f.MouthSmile, Is.EqualTo(peak).Within(.001f));
            f.Smile(0f);
            Send(f.Receiver, "stopLipSync", new JObject()); f.Process();
            Assert.That(f.MouthSmile, Is.Zero);
            Assert.That(f.EyeSmile, Is.Zero);
            Assert.That(f.CheekSmile, Is.Zero);
        }
    }

    [TestCase("Joy")]

    public void SmileHasAContinuousAttackAndSlowerRelease(string model)
    {
        using var f = new Fixture(model);
        f.Smile(0f);
        f.Smile(1f, settle: false);
        float start = (float)Field(f.Receiver, "expressionTransitionStartedAt");
        Call(f.Receiver, "UpdateExpressionTransition", start + .19f); f.Process();
        float halfway = f.MouthSmile;
        Assert.That(halfway, Is.GreaterThan(5f));
        // Sample beyond the onset boundary: a floating-point t just below 1
        // must not leave a future-sampled transition active before a real-clock send.
        Call(f.Receiver, "UpdateExpressionTransition", start + .5f); f.Process();
        float peak = f.MouthSmile;
        Assert.That(halfway, Is.EqualTo(peak * .5f).Within(.01f));
        f.Smile(0f, settle: false);
        start = (float)Field(f.Receiver, "expressionTransitionStartedAt");
        Call(f.Receiver, "UpdateExpressionTransition", start + .325f); f.Process();
        Assert.That(f.MouthSmile, Is.EqualTo(peak * .5f).Within(.01f));
        Call(f.Receiver, "UpdateExpressionTransition", start + .65f); f.Process();
        Assert.That(f.MouthSmile, Is.LessThan(.001f));
    }

    [TestCase("Joy")]

    public void DisablingAndRebindingClearsOwnedFaceCalibration(string model)
    {
        using var f = new Fixture(model);
        f.Smile(.8f);
        Call(f.Receiver, "OnDisable");
        Call(f.Receiver, "OnEnable");
        Call(f.Receiver, "ApplyExpression"); f.Process();
        Assert.That(f.MouthSmile, Is.Zero);
        Assert.That(f.EyeSmile, Is.Zero);
        f.Smile(.5f);
        Assert.That(f.MouthSmile, Is.GreaterThan(0f), "Re-enable must retain calibration.");
        Call(f.Receiver, "BindAvatarRoot", f.Root);
        Call(f.Receiver, "ApplyExpression"); f.Process();
        Assert.That(f.MouthSmile, Is.Zero);
        Assert.That(f.EyeSmile, Is.Zero);
    }

    [TestCase("Joy")]

    public void ThinkingAndTiredDoNotImplicitlySmileAndSurpriseCannotOpenSpeechSilence(string model)
    {
        using var f = new Fixture(model);
        f.Set(new JObject { ["thinking"] = .8f, ["tired"] = .4f, ["relaxed"] = .4f, ["eyeOpen"] = 1f });
        Assert.That(f.MouthSmile, Is.Zero);
        f.Set(new JObject { ["happy"] = .7f, ["surprised"] = .8f, ["eyeOpen"] = 1f });
        f.Timeline("pp");
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
        Call(f.Receiver, "ApplyLipSyncFrame", 1f); f.Process();
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
        Send(f.Receiver, "stopLipSync", new JObject()); f.Process();
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
    }

    [TestCase("Joy")]

    public void SeriousAffectInterruptsSmileWithoutAFullSlowRelease(string model)
    {
        using var f = new Fixture(model);
        f.Smile(.9f);
        f.Set(new JObject { ["sad"] = .6f, ["browConcern"] = .4f, ["eyeOpen"] = 1f }, settle: false);
        float start = (float)Field(f.Receiver, "expressionTransitionStartedAt");
        Call(f.Receiver, "UpdateExpressionTransition", start + .25f); f.Process();
        Assert.That(f.MouthSmile, Is.LessThan(.001f));
        Assert.That(f.EyeSmile, Is.Zero);
    }

    [TestCase("Joy")]

    public void RepeatedAffectRefreshesPreserveAttackHoldAndReleaseClock(string model)
    {
        using var f = new Fixture(model);
        f.Smile(.8f, settle: false);
        float onset = Time.realtimeSinceStartup - .12f;
        f.Receiver.GetType().GetField("expressionTransitionStartedAt", Flags).SetValue(f.Receiver, onset);
        f.Smile(.8f, settle: false);
        Assert.That((float)Field(f.Receiver, "expressionTransitionStartedAt"), Is.EqualTo(onset));
        Assert.That(f.MouthSmile, Is.GreaterThan(0f));
        Call(f.Receiver, "UpdateExpressionTransition", onset + 1f); f.Process();
        float peak = f.MouthSmile;
        f.Smile(.8f, settle: false);
        Assert.That((bool)Field(f.Receiver, "expressionTransitionActive"), Is.False,
            "A refresh at the peak does not create a new expression episode.");
        Assert.That(f.MouthSmile, Is.EqualTo(peak).Within(.001f));
        f.Smile(0f, settle: false);
        float release = Time.realtimeSinceStartup - .2f;
        f.Receiver.GetType().GetField("expressionTransitionStartedAt", Flags).SetValue(f.Receiver, release);
        f.Smile(0f, settle: false);
        Assert.That((float)Field(f.Receiver, "expressionTransitionStartedAt"), Is.EqualTo(release));
        Call(f.Receiver, "UpdateExpressionTransition", release + .7f); f.Process();
        Assert.That(f.MouthSmile, Is.Zero);
    }

    [TestCase("Joy")]

    public void SpeechClockPauseResumeStopAndNextTurnKeepTheActualMouthOwner(string model)
    {
        using var f = new Fixture(model);
        f.Set(new JObject { ["happy"] = .6f, ["surprised"] = .8f, ["eyeOpen"] = 1f });
        var start = new JObject { ["protocolVersion"] = 1, ["playbackId"] = "smile-a", ["generation"] = 1,
            ["turnId"] = "turn-a", ["utteranceId"] = "utterance-a", ["sequence"] = 1,
            ["state"] = "start", ["positionMs"] = 0, ["durationMs"] = 1000,
            ["source"] = "wav", ["authoritative"] = true, ["envelope"] = new JArray(.2f, 0f), ["frameRate"] = 30 };
        f.Clock(start); f.Timeline("aa");
        Assert.That(f.SpeechWeights().Values.Max(), Is.GreaterThan(0f));
        var pause = (JObject)start.DeepClone(); pause.Remove("envelope"); pause.Remove("frameRate");
        pause["state"] = "pause"; pause["sequence"] = 2; f.Clock(pause); f.Process();
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
        pause["state"] = "resume"; pause["sequence"] = 3; f.Clock(pause);
        Call(f.Receiver, "ApplyLipSyncFrame", 0f); f.Process();
        Assert.That(f.SpeechWeights().Values.Max(), Is.GreaterThan(0f));
        pause["state"] = "stop"; pause["sequence"] = 4; f.Clock(pause); f.Process();
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
        Send(f.Receiver, "stopLipSync", new JObject());
        start["playbackId"] = "smile-b"; start["generation"] = 2; start["turnId"] = "turn-b";
        start["utteranceId"] = "utterance-b"; f.Clock(start); f.Timeline("pp");
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
        Send(f.Receiver, "stopLipSync", new JObject()); f.Process();
        foreach (float weight in f.SpeechWeights().Values) Assert.That(weight, Is.Zero);
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Component Receiver;
        public readonly Transform Root;
        public readonly Vrm10Instance Vrm;
        public readonly SkinnedMeshRenderer Face;
        private readonly string model;
        public float MouthSmile => Weight(model == "Joy" ? "lip_smile.L" : "Mouth_Smile_L");
        public float EyeSmile => Weight(model == "Joy" ? "squint.L" : "Eye_Squint_L");
        public float CheekSmile => Weight(model == "Joy" ? "blink_lower_up.L" : "Cheek_Raise_L");
        public Fixture(string model)
        {
            this.model = model;
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            var vrm = Object.FindAnyObjectByType<Vrm10Instance>();
            int materialAccessCount = vrm.GetComponentsInChildren<Renderer>()
                .Where(r => r is SkinnedMeshRenderer || r is MeshRenderer).Sum(r => r.sharedMaterials.Length);
            for (int index = 0; index < materialAccessCount; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Receiver = Object.FindAnyObjectByType(Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true)) as Component;
            Call(Receiver, "Awake");

            Root = Receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(Receiver) as Transform;
            Vrm = Root.GetComponentInChildren<Vrm10Instance>(true);
            Face = Root.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.sharedMesh != null &&
                r.sharedMesh.GetBlendShapeIndex(model == "Joy" ? "lip_smile.L" : "Mouth_Smile_L") >= 0);
            Call(Receiver, "ApplyExpression"); Process();
        }
        public void Process()
        {
            Vrm?.Runtime.Process();
            var calibration = Field(Receiver, "facialCalibration");
            Call(calibration, "PresentSpeech");
        }
        public float Weight(string name)
        {
            int index = Face.sharedMesh.GetBlendShapeIndex(name);
            Assert.That(index, Is.GreaterThanOrEqualTo(0), name);
            return Face.GetBlendShapeWeight(index);
        }
        public void Smile(float value, bool settle = true) => Set(new JObject {
            ["happy"] = value, ["mouthSmile"] = value, ["eyeOpen"] = 1f }, settle);
        public void Set(JObject request, bool settle = true)
        {
            Send(Receiver, "setExpression", request);
            if (settle) Call(Receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
            Process();
        }
        public void Clock(JObject packet)
        {
            object parsed = packet.ToObject(Type.GetType("Maaso.Avatar.AvatarSpeechPlaybackClockPacket, Assembly-CSharp", true));
            Assert.That((bool)Call(Receiver, "SyncSpeechPlaybackClock", parsed), Is.True,
                "The production playback clock must accept the lifecycle fixture.");
        }
        public void Timeline(string viseme)
        {
            Send(Receiver, "startVisemeTimeline", new JObject {
                ["format"] = "vrm_viseme_v2", ["envelope"] = new JArray(.2f, 0f),
                ["cues"] = new JArray(new JObject { ["frame"] = 0, ["viseme"] = viseme }), ["frameRate"] = 30 });
            Process();
        }
        public Dictionary<string, float> SpeechWeights()
        {
            if (Vrm != null) return new[] { "AI", "E", "U", "O" }.ToDictionary(k => k, Weight);
            return new[] { "V_Open", "V_Wide", "V_Tight", "V_Tight_O", "V_Dental_Lip" }
                .ToDictionary(k => k, Weight);
        }
        public void Dispose() => EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
    }
}
