using System;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

/// <summary>Continuous real production-stage regression: the old acoustic-only replay
/// omitted model binding, micro-motion, collision, VRM and post-VRM Rigify skin inputs.</summary>
public sealed class AvatarContinuousArmPipelineTests
{
    [TestCase("default_idle")]
    [TestCase("annie_idle_c")]
    [TestCase("speech_release")]
    [TestCase("runtime_default_idle")]
    [TestCase("runtime_annie_idle_c")]
    [TestCase("runtime_speech_release")]
    public void FullReceiverAndDeformationDoNotIntroduceAbruptArmCorrectionsBetweenFrames(string scenario)
    {
        string output = Path.Combine(Path.GetTempPath(), "maaso-continuous-arm-tests", "joy" + "-" + scenario);
        JObject source = Replay(false, true, scenario, output);
        JObject off = Replay(false, false, scenario, output);
        JObject on = Replay(true, false, scenario, output);
        foreach (JObject result in new[] { source, off, on })
        {
            Assert.That((int)result["rejectedPlaybackPackets"], Is.Zero, result.ToString());
            Assert.That((int)result["metrics"]["nonFiniteSamples"], Is.Zero);
            Assert.That((float)result["rootTravelMeters"], Is.LessThan(.0001f));
            Assert.That((float)result["rootTurnDegrees"], Is.LessThan(.01f));
            Assert.That((bool)result["modelProbeCalibrated"], Is.True, (string)result["probeCalibration"]);
            Assert.That((bool)result["vrmProcessApplied"], Is.True);
            Assert.That((bool)result["rigifyApplied"], Is.True);
            Assert.That((bool)result["normalizedControlRig"], Is.EqualTo(scenario.StartsWith("runtime_", StringComparison.Ordinal)));
            Assert.That((int)result["frames"], Is.EqualTo(481));
        }
        Assert.That((bool)on["completeProductionFrameEntry"], Is.True,
            "Use the actual complete Receiver frame hook; do not replace it with another acoustic-only test path.");
        Assert.That((int)off["correctionFrames"], Is.Zero);
        Assert.That((int)source["correctionFrames"], Is.Zero);
        float rawSource = (float)source["metrics"]["maximumJointStepMeters"];
        float guardOff = (float)off["metrics"]["maximumOverlayResidualStepMeters"];
        float guardOn = (float)on["metrics"]["maximumOverlayResidualStepMeters"];
        TestContext.WriteLine("Source max joint step=" + rawSource + "m; overlays guard-off=" + guardOff +
            "m; guard-on=" + guardOn + "m; toggles=" + on["correctionToggleCount"] +
            "; strict source hash match=" + ((string)on["sourceInputSha256"] == (string)off["sourceInputSha256"]));
        Assert.That((float)on["metrics"]["maximumJointStepMeters"], Is.LessThan(.06f),
            "A complete 60fps conversational frame cannot teleport an elbow/wrist by 6cm: " + on["metrics"]);
        // A LARGE source/output residual can be successful inertia: at an
        // authored layer release the source may jump 78mm while the output moves
        // 0.1mm. Compare incremental guard-on minus guard-off residual at the
        // SAME frame/bone, and only when both source inputs match.
        var comparison = CompareMatchedFrameCorrections(on, off);
        Assert.That((int)comparison["matchedBoneFramePairs"], Is.GreaterThan(60), comparison.ToString());
        Assert.That((float)comparison["maximumAdditionalGuardResidualStepMeters"], Is.LessThanOrEqualTo(.02f),
            "The guard must not add an abrupt correction beyond the matched source/inertia/micro frame: " + comparison);
        Assert.That((int)on["correctionToggleCount"], Is.LessThanOrEqualTo(12),
            "Eight seconds of bounded idle/speech cannot oscillate arm correction on and off every few frames.");
    }

    private static JObject CompareMatchedFrameCorrections(JObject on, JObject off)
    {
        JArray a = JArray.Parse(File.ReadAllText((string)on["timelineFile"]));
        JArray b = JArray.Parse(File.ReadAllText((string)off["timelineFile"]));
        Assert.That(a.Count, Is.EqualTo(b.Count));
        int matched = 0, excluded = 0; float maximum = 0f; JObject at = null;
        Vector3 Point(JToken value) => new((float)value[0], (float)value[1], (float)value[2]);
        for (int frame = 1; frame < a.Count; frame++)
        {
            if ((float)a[frame]["seconds"] < .3f) continue;
            for (int bone = 0; bone < 6; bone++)
            {
                Vector3 sourceA = Point(a[frame]["stageSource"]["positions"][bone]), sourceB = Point(b[frame]["stageSource"]["positions"][bone]);
                Vector3 previousA = Point(a[frame - 1]["stageSource"]["positions"][bone]), previousB = Point(b[frame - 1]["stageSource"]["positions"][bone]);
                if (Vector3.Distance(sourceA, sourceB) > .002f || Vector3.Distance(previousA, previousB) > .002f)
                { excluded++; continue; }
                Vector3 residualA = Point(a[frame]["stageRenderedRaw"]["positions"][bone]) - sourceA;
                Vector3 residualB = Point(b[frame]["stageRenderedRaw"]["positions"][bone]) - sourceB;
                Vector3 oldA = Point(a[frame - 1]["stageRenderedRaw"]["positions"][bone]) - previousA;
                Vector3 oldB = Point(b[frame - 1]["stageRenderedRaw"]["positions"][bone]) - previousB;
                float additional = ((residualA - oldA) - (residualB - oldB)).magnitude;
                matched++;
                if (additional > maximum) { maximum = additional; at = new JObject { ["frame"] = frame, ["seconds"] = a[frame]["seconds"], ["boneIndex"] = bone }; }
            }
        }
        return new JObject { ["matchedBoneFramePairs"] = matched, ["excludedDifferentSourcePairs"] = excluded,
            ["maximumAdditionalGuardResidualStepMeters"] = maximum, ["maximumAt"] = at };
    }

    private static JObject Replay(bool guard, bool source, string scenario, string output)
    {
        // The actual Joy BindAvatarRoot path initializes exactly the reviewed
        // material slots. Do not blanket-ignore any unrelated Unity errors.
        for (int slot = 0; slot < 17; slot++) LogAssert.Expect(LogType.Error,
            "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
        Type replay = AppDomain.CurrentDomain.GetAssemblies().Select(assembly => assembly.GetType("Maaso.Avatar.Editor.MaasoContinuousArmReplay"))
            .FirstOrDefault(type => type != null);
        Assert.That(replay, Is.Not.Null);
        return (JObject)replay.GetMethod("RunCase", BindingFlags.Public | BindingFlags.Static)
            .Invoke(null, new object[] { false, guard, source, 60, scenario, output, false });
    }
}
