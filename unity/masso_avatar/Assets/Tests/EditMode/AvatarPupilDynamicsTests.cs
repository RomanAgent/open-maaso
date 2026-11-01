using System;
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

public sealed class AvatarPupilDynamicsTests
{
    private const BindingFlags Flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object target, string name, params object[] args)
    {
        var method = target.GetType().GetMethods(Flags)
            .Single(m => m.Name == name && m.GetParameters().Length == args.Length);
        try { return method.Invoke(target, args); }
        catch (TargetInvocationException e) { throw e.InnerException ?? e; }
    }
    private static T Field<T>(object target, string name) => (T)target.GetType().GetField(name, Flags).GetValue(target);
    private static T Property<T>(object target, string name) => (T)target.GetType().GetProperty(name).GetValue(target);

    [TestCase("neutral", 0f)]
    [TestCase("surprise", 1f)]
    [TestCase("anger", .5882353f)]
    [TestCase("happy", .2f)]
    [TestCase("love", .1529412f)]
    [TestCase("sad", 0f)]
    public void ArousalTracksAffectRatherThanEveryChatOrSpeechMouth(string affect, float expected)
    {
        var values = new float[9];
        if (affect != "neutral") values[affect switch {
            "surprise" => 0, "anger" => 1, "happy" => 2, "love" => 3, _ => 5 }] = 1f;
        float actual = (float)A("AvatarPupilDynamics").GetMethod("ResolveArousal")
            .Invoke(null, values.Cast<object>().ToArray());
        Assert.That(actual, Is.EqualTo(expected).Within(.00001f));
    }

    [Test]
    public void ArousalDeadzoneIsContinuousAndKeepsStrongEmotionVisible()
    {
        MethodInfo resolve = A("AvatarPupilDynamics").GetMethod("ResolveArousal");
        float At(float raw) => (float)resolve.Invoke(null,
            new object[] { raw, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f });
        Assert.That(At(.1499f), Is.Zero);
        Assert.That(At(.15f), Is.Zero);
        Assert.That(At(.1501f), Is.InRange(0f, .0002f), "There must be no jump at the threshold.");
        Assert.That(At(.8f), Is.GreaterThan(.7f));
        Assert.That(At(1f), Is.EqualTo(1f));
    }

    [TestCase("Joy", "automatic-thinking")]

    [TestCase("Joy", "ordinary-speaking")]

    public void ActualRuntimeWaitingAndSpeakingPresetsDoNotForcePupilChangesEveryTurn(string model, string preset)
    {
        using var f = new ReceiverFixture(model);
        // These are the existing emotion_to_avatar outputs for the runtime's
        // automatic thinking/speaking presets, not new dialogue heuristics.
        JObject payload = preset == "automatic-thinking"
            ? new JObject { ["angry"] = .2f, ["sad"] = .1f, ["thinking"] = .14f,
                ["browConcern"] = .235f, ["eyeOpen"] = 1f }
            : new JObject { ["happy"] = .2f, ["mouthSmile"] = .2f,
                ["mouthOpen"] = .4f, ["eyeOpen"] = 1f };
        for (int turn = 0; turn < 3; turn++)
        {
            f.Affect(payload); f.Step(.8f);
            Assert.That(f.Dilation, Is.Zero, preset + " is not a distinct emotional stimulus.");
            if (model == "Joy") Assert.That(f.JoyWeight, Is.Zero);
        }
        f.Affect(new JObject { ["surprised"] = .8f, ["eyeOpen"] = 1f }); f.Step(1.5f);
        Assert.That(f.Dilation, Is.GreaterThan(.7f), "A real strong affect still produces a visible response.");
    }

    [TestCase(30)]
    [TestCase(60)]
    [TestCase(120)]
    public void LocalResponseIsSmoothFrameRateIndependentAndRecoversToExactSource(int fps)
    {
        using var f = new MorphFixture(7f);
        f.Advance(0f, 1f);
        Assert.That(f.Weight, Is.EqualTo(7f), "No instant pop on stimulus onset.");
        float previous = 0f;
        for (int frame = 1; frame <= fps * 2; frame++)
        {
            f.Advance(frame / (float)fps, 1f);
            Assert.That(f.Normalized, Is.GreaterThanOrEqualTo(previous));
            Assert.That(f.Normalized - previous, Is.LessThan(.08f));
            previous = f.Normalized;
        }
        Assert.That(f.Normalized, Is.EqualTo(1f - Mathf.Exp(-2f / .45f)).Within(.0001f));
        Assert.That(f.Weight, Is.InRange(7f, 19f));
        for (int frame = 1; frame <= fps * 9; frame++) f.Advance(2f + frame / (float)fps, 0f);
        Assert.That(f.Normalized, Is.Zero);
        Assert.That(f.Weight, Is.EqualTo(7f), "Neutral means the precise original source value.");
    }

    [Test]
    public void RebindAndDisposeRestoreOnlyTheOwnedApertureChannel()
    {
        using var first = new MorphFixture(4f);
        using var second = new MorphFixture(9f);
        first.Advance(0f, 1f); first.Advance(.1f, 1f);
        first.Renderer.SetBlendShapeWeight(1, 61f);
        Assert.That(first.Weight, Is.GreaterThan(4f));
        Call(first.Driver, "Bind", second.Root.transform, true);
        Assert.That(first.Weight, Is.EqualTo(4f));
        Assert.That(first.Renderer.GetBlendShapeWeight(1), Is.EqualTo(61f));
        Assert.That(Property<float>(first.Driver, "NormalizedDilation"), Is.Zero);
        Call(first.Driver, "Dispose");
        Assert.That(second.Weight, Is.EqualTo(9f));
        Assert.That(Property<bool>(first.Driver, "IsBound"), Is.False);
    }

    [Test]
    public void UnknownModelWithAnIdenticallyNamedShapeIsUnchanged()
    {
        using var f = new MorphFixture(13f, trustedJoy: false);
        Assert.That(Property<bool>(f.Driver, "IsBound"), Is.False);
        f.Advance(0f, 1f); f.Advance(.1f, 1f);
        Assert.That(f.Weight, Is.EqualTo(13f));
    }

    [TestCase("Joy")]

    public void InstalledModelsRespondLocallyWithoutRestartingOnIdenticalAffect(string model)
    {
        using var f = new ReceiverFixture(model);
        Assert.That(Property<bool>(f.Driver, "IsBound"), Is.True, model + " adapter must actually bind.");
        Assert.That(f.Dilation, Is.Zero, "Ordinary neutral chat does not imply dilation.");
        var request = new JObject { ["surprised"] = .8f, ["eyeOpen"] = 1f };
        f.Affect(request);
        f.Step(1.2f);
        Assert.That(f.Dilation, Is.InRange(.65f, .8f));
        float beforeRefresh = f.Dilation;
        f.Affect(request);
        Assert.That(f.Dilation, Is.EqualTo(beforeRefresh), "A streamed refresh must not restart onset.");
        f.Step(.8f);
        Assert.That(f.Dilation, Is.GreaterThan(beforeRefresh));
        if (model == "Joy") Assert.That(f.JoyWeight, Is.InRange(7.8f, 9.6f));
        f.Affect(new JObject { ["eyeOpen"] = 1f });
        f.Step(.2f);
        Assert.That(f.Dilation, Is.GreaterThan(.1f), "Affect release must not snap to source.");
        Assert.That(f.Dilation, Is.LessThan(beforeRefresh));
        f.Step(9f);
        Assert.That(f.Dilation, Is.Zero);
        if (model == "Joy") Assert.That(f.JoyWeight, Is.Zero);
    }

    [TestCase("Joy")]

    public void PupilPresentationDoesNotChangeMouthBlinkOrGazeOwnership(string model)
    {
        using var f = new ReceiverFixture(model);
        f.Affect(new JObject { ["surprised"] = .8f, ["happy"] = .2f, ["eyeOpen"] = .01f });
        f.Send("startVisemeTimeline", new JObject { ["format"] = "vrm_viseme_v2",
            ["envelope"] = new JArray(.6f, .6f, .6f), ["frameRate"] = 1,
            ["cues"] = new JArray(new JObject { ["frame"] = 0, ["viseme"] = "aa" }) });
        f.Send("setGaze", new JObject { ["eyeX"] = .4f, ["headX"] = .2f });
        Call(f.Receiver, "UpdateGazeTransition", Field<float>(f.Receiver, "gazeTransitionStartedAt") + 1f);
        f.Step(.3f);
        float mouth = f.MouthWeight, blink = f.BlinkWeight;
        Quaternion head = f.Head.rotation;
        Assert.That(mouth, Is.GreaterThan(.1f));
        Assert.That(blink, Is.GreaterThan(.9f));
        for (int index = 0; index < 20; index++)
        {
            Call(f.Driver, "Present"); f.Process();
            Assert.That(f.MouthWeight, Is.EqualTo(mouth).Within(.0001f));
            Assert.That(f.BlinkWeight, Is.EqualTo(blink).Within(.0001f));
            Assert.That(Quaternion.Angle(head, f.Head.rotation), Is.LessThan(.03f));
        }
        if (model == "Joy") Assert.That(f.JoyWeight, Is.GreaterThan(0f), "Post-VRM presentation must retain aperture modulation.");
    }

    [TestCase("Joy", "disable")]

    [TestCase("Joy", "pause")]

    [TestCase("Joy", "accountReset")]

    [TestCase("Joy", "rebind")]

    public void PresentationBoundariesRestoreTheSourceAndClearResponseState(string model, string boundary)
    {
        using var f = new ReceiverFixture(model);
        f.Affect(new JObject { ["surprised"] = 1f, ["eyeOpen"] = 1f }); f.Step(1f);
        Assert.That(f.Dilation, Is.GreaterThan(.7f));
        switch (boundary)
        {
            case "disable": Call(f.Receiver, "OnDisable"); break;
            case "pause": Call(f.Receiver, "OnApplicationPause", true); break;
            case "accountReset": Call(f.Receiver, "ResetAvatarArbiterState"); break;
            case "rebind": Call(f.Receiver, "BindAvatarRoot", f.Root); break;
        }
        Assert.That(f.Dilation, Is.Zero, boundary);
        if (model == "Joy") Assert.That(f.JoyWeight, Is.Zero);
        if (boundary == "disable") Assert.That(Property<bool>(f.Driver, "IsBound"), Is.False);
    }

    private sealed class MorphFixture : IDisposable
    {
        public readonly GameObject Root = new("Synthetic trusted eye signature");
        public readonly SkinnedMeshRenderer Renderer;
        public readonly object Driver = Activator.CreateInstance(A("AvatarPupilDynamics"));
        private readonly Mesh mesh = new();
        public float Weight => Renderer.GetBlendShapeWeight(0);
        public float Normalized => Property<float>(Driver, "NormalizedDilation");
        public MorphFixture(float original, bool trustedJoy = true)
        {
            var eye = new GameObject("Joy_eye"); eye.transform.SetParent(Root.transform);
            Renderer = eye.AddComponent<SkinnedMeshRenderer>();
            mesh.vertices = new[] { Vector3.zero, Vector3.up, Vector3.right };
            mesh.triangles = new[] { 0, 1, 2 };
            var deltas = new[] { Vector3.right * .001f, Vector3.left * .001f, Vector3.zero };
            mesh.AddBlendShapeFrame("eye_dilate", 100f, deltas, null, null);
            mesh.AddBlendShapeFrame("Unrelated", 100f, deltas, null, null);
            Renderer.sharedMesh = mesh; Renderer.SetBlendShapeWeight(0, original);
            Call(Driver, "Bind", Root.transform, trustedJoy);
        }
        public void Advance(float now, float stimulus) => Call(Driver, "Advance", now, stimulus);
        public void Dispose() { Call(Driver, "Dispose"); Object.DestroyImmediate(Root); Object.DestroyImmediate(mesh); }
    }

    private sealed class ReceiverFixture : IDisposable
    {
        public readonly Component Receiver;
        public readonly Transform Root;
        public readonly Vrm10Instance Vrm;
        public readonly Animator Animator;
        public Transform Head => Animator.GetBoneTransform(HumanBodyBones.Head);
        public object Driver => Field<object>(Receiver, "pupilDynamics");
        public float Dilation => Property<float>(Driver, "NormalizedDilation");
        private readonly SkinnedMeshRenderer face, eye;
        private float now;
        private readonly long utc = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        public float JoyWeight => eye.GetBlendShapeWeight(eye.sharedMesh.GetBlendShapeIndex("eye_dilate"));
        public float MouthWeight => Vrm != null ? Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Aa]
            : face.GetBlendShapeWeight(face.sharedMesh.GetBlendShapeIndex("V_Open")) / 100f;
        public float BlinkWeight => Vrm != null ? Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Blink]
            : face.GetBlendShapeWeight(face.sharedMesh.GetBlendShapeIndex("Eye_Blink_L")) / 100f;

        public ReceiverFixture(string model)
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            var initial = Object.FindAnyObjectByType<Vrm10Instance>();
            foreach (Renderer renderer in initial.GetComponentsInChildren<Renderer>())
                if (renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                    foreach (Material material in renderer.sharedMaterials)
                        LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Receiver = Object.FindAnyObjectByType(A("UnityAvatarCommandReceiver")) as Component;
            Call(Receiver, "Awake");

            Root = (Transform)Receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(Receiver);
            Vrm = Root.GetComponentInChildren<Vrm10Instance>(true);
            Animator = Root.GetComponentInChildren<Animator>(true);
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.Rebind(); Animator.Play("idle_shrug", 0, 0f); Animator.Update(0f);
            face = Root.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.sharedMesh != null &&
                r.sharedMesh.GetBlendShapeIndex(model == "Joy" ? "lip_smile.L" : "Mouth_Smile_L") >= 0);
            eye = model == "Joy" ? Root.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Single(r => r.sharedMesh != null && r.sharedMesh.GetBlendShapeIndex("eye_dilate") >= 0) : null;
            Send("setLocalAvatarVisible", new JObject { ["visible"] = true });
            Receiver.GetType().GetField("autoBlink", Flags).SetValue(Receiver, false);
            Receiver.GetType().GetField("actionPoseHoldUntil", Flags).SetValue(Receiver, Time.realtimeSinceStartup + 3600f);
            now = Time.realtimeSinceStartup;
            Affect(new JObject { ["eyeOpen"] = 1f }); Step(1f / 60f);
        }
        public void Send(string method, JObject json) => Call(Receiver, "OnFlutterCommand",
            new JObject { ["method"] = method, ["json"] = json.ToString() }.ToString());
        public void Affect(JObject expression)
        {
            Send("setExpression", expression);
            // Settle only the expression interpolation. The pupil keeps its
            // own continuous, monotonically advanced frame clock below.
            Call(Receiver, "UpdateExpressionTransition", Field<float>(Receiver, "expressionTransitionStartedAt") + 2f);
        }
        public void Process()
        {
            Vrm?.Runtime.Process();
            Call(Field<object>(Receiver, "facialCalibration"), "PresentSpeech");
            var morph = eye != null ? eye.GetComponent(A("AvatarPupilMorphPresentation")) : null;
            if (morph != null) Call(morph, "Present");
        }
        public void Step(float seconds)
        {
            for (int frame = 0; frame < Mathf.CeilToInt(seconds * 60f); frame++)
            {
                now += 1f / 60f;
                Call(Receiver, "Update"); Animator.Update(0f);
                Call(Receiver, "AdvancePresentationFrame", now, utc);
                Process();
            }
        }
        public void Dispose() => EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
    }
}
