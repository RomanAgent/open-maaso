using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class AvatarVrmJawOwnershipTests
{
    [Test]
    public void ReceiverRestoresImportedJawAfterHumanoidIdleWritesItsDefaultPose()
    {
        using var f = new Fixture();
        f.Animator.Rebind();
        f.Animator.Play("idle_shrug", 0, 0f);
        f.Animator.Update(0f);
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.GreaterThan(1f),
            "This regression must reproduce the shipped Humanoid controller opening Joy's jaw.");
        f.CompleteFrame();
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.LessThan(0.05f),
            "Receiver LateUpdate must restore the imported closed-jaw pose before VRM processing.");
    }

    [Test]
    public void NeutralJawPreservesTtsMouthMotionSilentResetAndBlinkOnTheRealMesh()
    {
        using var f = new Fixture();
        f.Animator.Rebind();
        f.Animator.Play("idle_shrug", 0, 0f);
        f.Animator.Update(0f);
        f.CompleteFrame();
        Vector3[] neutral = f.BakeFace();
        f.Command("setMouthOpen", "{\"value\":0.8}");
        f.CompleteFrame();
        Assert.That(f.Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Aa], Is.EqualTo(0.8f).Within(0.001f));
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.GreaterThan(0.001f),
            "TTS must deform the rendered mouth after jaw ownership is applied.");
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.LessThan(0.05f));

        f.Command("stopLipSync", "{}");
        f.CompleteFrame();
        foreach (ExpressionKey vowel in Vowels)
        {
            Assert.That(f.Vrm.Runtime.Expression.GetWeight(vowel), Is.Zero, vowel.ToString());
            Assert.That(f.Vrm.Runtime.Expression.ActualWeights[vowel], Is.Zero, vowel.ToString());
        }
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.LessThan(0.00001f),
            "Stopping speech must return actual geometry to the same neutral mouth.");

        f.SetExpression("{\"eyeOpen\":0.01}");
        Assert.That(f.Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Blink], Is.GreaterThan(0.95f));
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.GreaterThan(0.001f),
            "Jaw ownership must not suppress the real eyelid morph.");
        f.SetExpression("{\"eyeOpen\":1}");
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.LessThan(0.00001f));
    }

    [TestCase("pp")]
    [TestCase("ff")]
    public void ConsonantCuesUseSafeVrmFallbackAndStopClosesTheRealMouth(string consonant)
    {
        using var f = new Fixture();
        f.Animator.Rebind(); f.Animator.Update(0); f.CompleteFrame();
        f.Command("startVisemeTimeline", "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.7,0.7,0,0]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"" + consonant + "\"}],\"frameRate\":1}");
        f.CompleteTimelineFrame(0);
        Assert.That(f.Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Aa],Is.Zero);
        if(consonant=="ff") Assert.That(f.Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Ee],Is.GreaterThan(.05f));
        f.Command("stopLipSync","{}"); f.CompleteFrame();
        foreach(ExpressionKey vowel in Vowels) Assert.That(f.Vrm.Runtime.Expression.ActualWeights[vowel],Is.Zero);
        Assert.That(Quaternion.Angle(f.Jaw.localRotation,f.RestRotation),Is.LessThan(.05f));
    }

    [Test]
    public void FiveVowelTimelinesProduceDistinctRealMouthGeometryAndSilentFramesRestoreIt()
    {
        using var f = new Fixture();
        f.Animator.Rebind();
        f.Animator.Play("idle_shrug", 0, 0f);
        f.Animator.Update(0f);
        f.CompleteFrame();
        Vector3[] neutral = f.BakeFace();
        var samples = new Dictionary<string, Vector3[]>();
        var vowels = new[]
        {
            ("aa", ExpressionKey.Aa), ("ee", ExpressionKey.Ee), ("ih", ExpressionKey.Ih),
            ("oh", ExpressionKey.Oh), ("ou", ExpressionKey.Ou),
        };
        foreach (var (name, key) in vowels)
        {
            f.Command("startVisemeTimeline", "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.6,0.6,0,0]," +
                "\"cues\":[{\"frame\":0,\"viseme\":\"" + name + "\"}],\"frameRate\":1}");
            f.CompleteTimelineFrame(0);
            Assert.That(f.Vrm.Runtime.Expression.ActualWeights[key], Is.GreaterThan(0.5f), name);
            foreach (ExpressionKey other in Vowels.Where(other => !other.Equals(key)))
                Assert.That(f.Vrm.Runtime.Expression.ActualWeights[other], Is.Zero,
                    name + " must not be rendered as another vowel.");
            samples[name] = f.BakeFace();
            Assert.That(MaxDelta(neutral, samples[name]), Is.GreaterThan(0.0003f),
                name + " must deform the actual imported mesh after the jaw ownership and VRM passes.");
            Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.LessThan(0.05f), name);

            // The cue is still a vowel: zero audio energy itself must close it.
            f.CompleteTimelineFrame(2);
            foreach (ExpressionKey vowel in Vowels)
            {
                Assert.That(f.Vrm.Runtime.Expression.GetWeight(vowel), Is.Zero, name + " silent input");
                Assert.That(f.Vrm.Runtime.Expression.ActualWeights[vowel], Is.Zero, name + " silent output");
            }
            Assert.That(MaxDelta(neutral, f.BakeFace()), Is.LessThan(0.00001f),
                name + " silence must return to the neutral baked geometry, not merely zero input weights.");
        }
        for (int first = 0; first < vowels.Length; first++)
            for (int second = first + 1; second < vowels.Length; second++)
            {
                string a = vowels[first].Item1, b = vowels[second].Item1;
                float distance = MaxDelta(samples[a], samples[b]);
                TestContext.WriteLine($"Joy vowel geometry {a}/{b}: maximum difference {distance:R}m");
                Assert.That(distance, Is.GreaterThan(0.0003f),
                    a + " and " + b + " cannot share the same generic open-mouth geometry.");
            }
    }

    [TestCase("silCue")]
    [TestCase("timelineEnd")]
    [TestCase("stopLipSync")]
    public void TimelineSilenceAndStopClearRenderedVowelsWithJawOwnership(string reset)
    {
        using var f = new Fixture();
        f.Animator.Rebind();
        f.Animator.Play("idle_shrug", 0, 0f);
        f.Animator.Update(0f);
        f.CompleteFrame();
        Vector3[] neutral = f.BakeFace();
        f.Command("startVisemeTimeline", "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.6,0.6,0.6,0.6]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"oh\"},{\"frame\":3,\"viseme\":\"sil\"}],\"frameRate\":1}");
        f.CompleteTimelineFrame(0);
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.GreaterThan(0.0003f));
        if (reset == "stopLipSync")
        {
            f.Command("stopLipSync", "{}");
            f.CompleteFrame();
        }
        else f.CompleteTimelineFrame(reset == "silCue" ? 3 : 4);
        foreach (ExpressionKey vowel in Vowels)
        {
            Assert.That(f.Vrm.Runtime.Expression.GetWeight(vowel), Is.Zero, vowel.ToString());
            Assert.That(f.Vrm.Runtime.Expression.ActualWeights[vowel], Is.Zero, vowel.ToString());
        }
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.LessThan(0.00001f), reset);
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.LessThan(0.05f), reset);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void MissingOrEmptyVowelBindingsLeaveTheJawUnderItsExistingOwner(bool emptyClips)
    {
        using var f = new Fixture(emptyClips ? VowelSetup.Empty : VowelSetup.Missing);
        object ownership = NewOwnership();
        Call(ownership, "Bind", f.Vrm);
        Assert.That(OwnsJaw(ownership), Is.False);
        Quaternion existing = f.RestRotation * Quaternion.Euler(12f, 4f, 0f);
        f.Jaw.localRotation = existing;
        Call(ownership, "Apply");
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, existing), Is.LessThan(0.01f));
    }

    [Test]
    public void RebindingToNoVrmReleasesThePreviouslyOwnedJaw()
    {
        using var f = new Fixture();
        object ownership = NewOwnership();
        Call(ownership, "Bind", f.Vrm);
        Assert.That(OwnsJaw(ownership), Is.True);
        Call(ownership, "Bind", new object[] { null });
        Assert.That(OwnsJaw(ownership), Is.False);
        Quaternion existing = f.RestRotation * Quaternion.Euler(8f, 3f, 0f);
        f.Jaw.localRotation = existing;
        Call(ownership, "Apply");
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, existing), Is.LessThan(0.01f));
    }

    [Test]
    public void NormalizedControlJawCannotReopenTheRawJawDuringVrmProcessing()
    {
        using var f = new Fixture(useControlRig: true);
        object ownership = NewOwnership();
        Call(ownership, "Bind", f.Vrm);
        Assert.That(OwnsJaw(ownership), Is.True);
        Assert.That(f.Vrm.Runtime.ControlRig, Is.Not.Null);
        Transform normalizedJaw = f.Vrm.Runtime.ControlRig.GetBoneTransform(HumanBodyBones.Jaw);
        Assert.That(normalizedJaw, Is.Not.Null);
        Assert.That(normalizedJaw, Is.Not.SameAs(f.Jaw));
        normalizedJaw.localRotation = Quaternion.Euler(18f, 0f, 0f);
        f.Vrm.Runtime.Process();
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.GreaterThan(5f),
            "The normalized control rig must demonstrably drive the raw jaw before ownership is applied.");
        Call(ownership, "Apply");
        Assert.That(Quaternion.Angle(normalizedJaw.localRotation, Quaternion.identity), Is.LessThan(0.01f));
        f.Vrm.Runtime.Process();
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.LessThan(0.05f),
            "The following VRM control-rig pass must preserve the imported raw jaw rotation.");
    }

    [Test]
    public void NodeDrivenVowelIsAppliedAfterTheNeutralJawOwnershipPass()
    {
        using var f = new Fixture(VowelSetup.NodeDriven);
        object ownership = NewOwnership();
        Call(ownership, "Bind", f.Vrm);
        Assert.That(OwnsJaw(ownership), Is.True,
            "A VRM with bone-driven speech needs neutral jaw ownership as well.");
        f.Jaw.localRotation = f.RestRotation * Quaternion.Euler(-15f, 0f, 0f);
        f.Vrm.Runtime.Expression.SetWeight(ExpressionKey.Aa, 0.8f);
        Call(ownership, "Apply");
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.LessThan(0.05f));
        f.Vrm.Runtime.Process();
        Quaternion spoken = Quaternion.Slerp(f.RestRotation, f.RestRotation * Fixture.SpeechRotation, 0.8f);
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, spoken), Is.LessThan(0.05f),
            "The VRM node binding must remain free to open the jaw after the neutral pass.");
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.GreaterThan(5f));
        f.Vrm.Runtime.Expression.SetWeight(ExpressionKey.Aa, 0f);
        Call(ownership, "Apply");
        f.Vrm.Runtime.Process();
        Assert.That(Quaternion.Angle(f.Jaw.localRotation, f.RestRotation), Is.LessThan(0.05f));
    }

    private static readonly ExpressionKey[] Vowels =
        { ExpressionKey.Aa, ExpressionKey.Ih, ExpressionKey.Ou, ExpressionKey.Ee, ExpressionKey.Oh };

    private static object NewOwnership() => Activator.CreateInstance(Type.GetType(
        "Maaso.Avatar.AvatarVrmJawOwnership, Maaso.VrmBridge", true));

    private static bool OwnsJaw(object ownership) => (bool)ownership.GetType()
        .GetProperty("OwnsJaw", BindingFlags.Public | BindingFlags.Instance).GetValue(ownership);

    private static object Call(object target, string name, params object[] arguments)
    {
        MethodInfo method = target.GetType().GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Single(item => item.Name == name && item.GetParameters().Length == arguments.Length);
        try { return method.Invoke(target, arguments); }
        catch (TargetInvocationException error) { throw error.InnerException ?? error; }
    }

    private static float MaxDelta(Vector3[] before, Vector3[] after)
    {
        Assert.That(after.Length, Is.EqualTo(before.Length));
        Assert.That(after.Length, Is.GreaterThan(0));
        return before.Zip(after, Vector3.Distance).Max();
    }

    private enum VowelSetup { Original, Missing, Empty, NodeDriven }

    private sealed class Fixture : IDisposable
    {
        public static readonly Quaternion SpeechRotation = Quaternion.Euler(20f, 0f, 0f);
        public readonly Vrm10Instance Vrm;
        public readonly Animator Animator;
        public readonly Transform Jaw;
        public readonly Quaternion RestRotation;
        private readonly Component receiver;
        private readonly SkinnedMeshRenderer face;
        private readonly List<Object> temporaryDefinitions = new();

        public Fixture(VowelSetup vowels = VowelSetup.Original, bool useControlRig = false)
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Vrm = Object.FindAnyObjectByType<Vrm10Instance>();
            Assert.That(Vrm, Is.Not.Null);
            receiver = Object.FindAnyObjectByType(Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true)) as Component;
            Assert.That(receiver, Is.Not.Null);
            Animator = Vrm.GetComponentInChildren<Animator>(true);
            Assert.That(Animator, Is.Not.Null);
            Assert.That(Vrm.TryGetBoneTransform(HumanBodyBones.Jaw, out Transform jaw), Is.True);
            Jaw = jaw;
            if (useControlRig)
                typeof(Vrm10Instance).GetField("m_useControlRig", BindingFlags.NonPublic | BindingFlags.Instance)
                    .SetValue(Vrm, true);
            face = Vrm.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Single(renderer => renderer.sharedMesh != null && renderer.sharedMesh.GetBlendShapeIndex("Smile_L") >= 0);
            if (vowels != VowelSetup.Original)
            {
                VRM10Object copy = Object.Instantiate(Vrm.Vrm);
                temporaryDefinitions.Add(copy);
                foreach (FieldInfo field in typeof(VRM10ObjectExpression).GetFields()
                    .Where(field => new[] { "Aa", "Ih", "Ou", "Ee", "Oh" }.Contains(field.Name)))
                {
                    VRM10Expression clip = null;
                    if (vowels == VowelSetup.Empty || (vowels == VowelSetup.NodeDriven && field.Name == "Aa"))
                    {
                        clip = ScriptableObject.CreateInstance<VRM10Expression>();
                        clip.name = field.Name;
                        temporaryDefinitions.Add(clip);
                        if (vowels == VowelSetup.NodeDriven)
                            clip.NodeTransformBindings = new[] { new NodeTransformBinding(
                                AnimationUtility.CalculateTransformPath(Jaw, Vrm.transform), Vector3.zero,
                                SpeechRotation, Jaw.localScale) };
                    }
                    field.SetValue(copy.Expression, clip);
                }
                Vrm.Vrm = copy;
            }
            int materialSlots = Vrm.GetComponentsInChildren<Renderer>()
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .Sum(renderer => renderer.sharedMaterials.Length);
            for (int index = 0; index < materialSlots; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Call(receiver, "Awake");
            // Read the retained import pose, not the potentially retargeted
            // transform present after receiver/Animator initialization.
            var importPose = (IDictionary)Vrm.Runtime.GetType().GetProperty("InitPose").GetValue(Vrm.Runtime);
            Assert.That(importPose.Contains(Jaw), Is.True);
            object state = importPose[Jaw];
            RestRotation = (Quaternion)state.GetType().GetProperty("LocalRotation").GetValue(state);
            receiver.GetType().GetField("autoBlink", BindingFlags.NonPublic | BindingFlags.Instance)
                .SetValue(receiver, false);
            SetExpression("{\"eyeOpen\":1}");
        }

        public void Command(string method, string payload) => Call(receiver, "OnFlutterCommand",
            "{\"method\":\"" + method + "\",\"json\":\"" +
            payload.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"}");

        public void SetExpression(string payload)
        {
            Command("setExpression", payload);
            Call(receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
            CompleteFrame();
        }

        public void CompleteFrame()
        {
            Call(receiver, "LateUpdate");
            Vrm.Runtime.Process();
        }

        public void CompleteTimelineFrame(int frame)
        {
            // Pin only the clock, never mouth weights or geometry. One-second
            // frames keep this synchronous EditMode sample away from boundaries.
            receiver.GetType().GetField("lipSyncStartedAt", BindingFlags.NonPublic | BindingFlags.Instance)
                .SetValue(receiver, Time.realtimeSinceStartup - frame - 0.1f);
            CompleteFrame();
        }

        public Vector3[] BakeFace()
        {
            var mesh = new Mesh();
            try { face.BakeMesh(mesh); return mesh.vertices; }
            finally { Object.DestroyImmediate(mesh); }
        }

        public void Dispose()
        {
            // UniVRM owns generated control-rig objects with play-mode Destroy.
            // Dispose this temporary EditMode rig immediately before its owner.
            if (Vrm != null && Vrm.Runtime.ControlRig != null)
            {
                Object.DestroyImmediate(Vrm.Runtime.ControlRig.ControlRigAnimator.avatar);
                Transform controlRoot = Vrm.transform.Find("Runtime Control Rig");
                if (controlRoot != null) Object.DestroyImmediate(controlRoot.gameObject);
            }
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            foreach (Object value in temporaryDefinitions) Object.DestroyImmediate(value);
        }
    }
}
