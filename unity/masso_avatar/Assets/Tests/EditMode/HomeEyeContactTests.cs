using System;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

/// <summary>Exercises the installed Joy, the production receiver and UniVRM's
/// final bone/expression pass. Assertions use world bones and CPU skinned eye
/// vertices, rather than treating a LookAt input value as rendered evidence.</summary>
public sealed class HomeEyeContactTests
{
    [Test]
    public void HomeLowersBothRenderedEyesWithoutMovingTheHeadOrAccumulatingRotation()
    {
        using var f = new Fixture();
        f.CenterWithoutHome();
        var eyes = new[] { new EyeCap(f, HumanBodyBones.LeftEye), new EyeCap(f, HumanBodyBones.RightEye) };
        Quaternion head = f.Head.rotation, rootRotation = f.Root.rotation;
        Vector3 headPosition = f.Head.position, rootPosition = f.Root.position;
        f.Frame();
        Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.LessThan(-1f));
        foreach (EyeCap eye in eyes)
        {
            Assert.That(Quaternion.Angle(eye.CenterRotation, eye.Bone.rotation), Is.InRange(1f, 4f));
            Vector3 delta = eye.WorldCenter() - eye.CenterPosition;
            Assert.That(Vector3.Dot(delta, f.Root.up), Is.LessThan(-0.0001f),
                eye.Bone.name + " actual forward eye surface must move downward.");
            Assert.That(Mathf.Abs(Vector3.Dot(delta, f.Root.right)), Is.LessThan(0.0001f),
                "The fixed Home center must not introduce sideways eye motion.");
        }
        Quaternion[] rotations = eyes.Select(eye => eye.Bone.rotation).ToArray();
        Vector3[] centers = eyes.Select(eye => eye.WorldCenter()).ToArray();
        for (int frame = 0; frame < 60; frame++) f.Frame();
        for (int eye = 0; eye < eyes.Length; eye++)
        {
            Assert.That(Quaternion.Angle(rotations[eye], eyes[eye].Bone.rotation), Is.LessThan(0.03f));
            Assert.That(Vector3.Distance(centers[eye], eyes[eye].WorldCenter()), Is.LessThan(0.00001f));
        }
        Assert.That(Quaternion.Angle(head, f.Head.rotation), Is.LessThan(0.03f));
        Assert.That(Quaternion.Angle(rootRotation, f.Root.rotation), Is.LessThan(0.01f));
        Assert.That(Vector3.Distance(headPosition, f.Head.position), Is.LessThan(0.00001f));
        Assert.That(Vector3.Distance(rootPosition, f.Root.position), Is.LessThan(0.00001f));
    }

    [TestCase("worldLease")]
    [TestCase("worldLocomotion")]
    [TestCase("worldCamera")]
    [TestCase("desktopTransparent")]
    [TestCase("portalCapture")]
    [TestCase("hiddenAvatar")]
    public void LeavingHomeReleasesOnlyItsEyeCenter(string presentation)
    {
        using var f = new Fixture();
        f.CenterWithoutHome();
        Quaternion center = f.LeftEye.localRotation;
        f.Frame();
        Assert.That(Quaternion.Angle(center, f.LeftEye.localRotation), Is.GreaterThan(1f));
        switch (presentation)
        {
            case "worldLease": f.Set("avatarLeasedToWorld", true); break;
            case "worldLocomotion": f.Set("worldLocomotionActive", true); break;
            case "worldCamera": f.Framing.enabled = false; break;
            case "desktopTransparent":
                f.Camera.clearFlags = CameraClearFlags.SolidColor;
                f.Camera.backgroundColor = Color.clear;
                break;
            case "portalCapture": f.Camera.cullingMask &= ~(1 << f.Root.gameObject.layer); break;
            case "hiddenAvatar": f.Command("setLocalAvatarVisible", "{\"visible\":false}"); break;
        }
        f.Frame();
        Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.Zero);
        Assert.That(Quaternion.Angle(center, f.LeftEye.localRotation), Is.LessThan(0.03f));
        // The explicit pointer command remains valid outside Home; only the
        // fixed eye-contact calibration is released.
        f.Command("setGaze", "{\"eyeX\":0.2,\"eyeY\":0.5}");
        f.CompleteTransition("gazeTransitionStartedAt", "UpdateGazeTransition");
        f.Frame();
        Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.EqualTo(45f).Within(.001f));
    }

    [Test]
    public void PhoneOwnsItsPresentationWithoutHomeEyeContactAndResetRestoresHome()
    {
        using var f = new Fixture();
        f.Frame();
        float homePitch = f.Vrm.Runtime.LookAt.Pitch;
        // The production phone protocol accepts deadlines at most 10 seconds
        // ahead. A 60-second fixture was rejected before it could own the hands.
        long expires = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 5000;
        f.Command("setPhoneInteraction", "{\"requestId\":\"home_eye_read\",\"interactionId\":\"home_eye_phone\"," +
            "\"phase\":\"reading\",\"sequence\":1,\"expiresAtMs\":" + expires + "}");
        object phone = f.Field("phoneInteraction");
        Assert.That(phone, Is.Not.Null);
        Assert.That((bool)phone.GetType().GetProperty("OwnsHands").GetValue(phone), Is.True);
        f.Frame();
        Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.Zero);
        phone.GetType().GetMethod("Reset").Invoke(phone, new object[] { "home_eye_test_complete" });
        f.Frame();
        Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.EqualTo(homePitch).Within(.001f));
    }

    [TestCase(-1f, -90f)]
    [TestCase(0f, -22.5f)]
    [TestCase(1f, 90f)]
    public void ExplicitGazeKeepsFullEyeRangeAndDoesNotGainHeadTilt(float vertical, float expectedPitch)
    {
        using var f = new Fixture();
        Quaternion head = f.Head.rotation;
        f.Command("setGaze", "{\"eyeY\":" + vertical.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");
        f.CompleteTransition("gazeTransitionStartedAt", "UpdateGazeTransition");
        f.Frame();
        Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.EqualTo(expectedPitch).Within(.001f));
        Assert.That(Quaternion.Angle(head, f.Head.rotation), Is.LessThan(.03f));
        f.Command("clearGaze", "{}");
        f.CompleteTransition("gazeTransitionStartedAt", "UpdateGazeTransition");
        f.Frame();
        Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.EqualTo(-22.5f).Within(.001f));
    }

    [TestCase("aa")]
    [TestCase("ee")]
    [TestCase("ih")]
    [TestCase("oh")]
    [TestCase("ou")]
    public void EyeContactCoexistsWithActualBlinkAndEachTtsVowel(string vowel)
    {
        using var f = new Fixture();
        f.Frame();
        Quaternion eye = f.LeftEye.localRotation, head = f.Head.rotation;
        Vector3[] neutral = f.BakeFace();
        f.Command("startVisemeTimeline", "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.6,0.6,0,0]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"" + vowel + "\"}],\"frameRate\":1}");
        // The legacy all-zero expression is a neutral-reset sentinel. Use the
        // supported nearly-closed eyelid input, as the real-mesh jaw tests do.
        f.Command("setExpression", "{\"eyeOpen\":0.01}");
        f.CompleteTransition("expressionTransitionStartedAt", "UpdateExpressionTransition");
        f.Set("lipSyncStartedAt", Time.realtimeSinceStartup - .1f);
        f.Frame();
        ExpressionKey key = vowel switch {
            "aa" => ExpressionKey.Aa, "ee" => ExpressionKey.Ee, "ih" => ExpressionKey.Ih,
            "oh" => ExpressionKey.Oh, _ => ExpressionKey.Ou };
        Assert.That(f.Vrm.Runtime.Expression.ActualWeights[key], Is.GreaterThan(.5f));
        Assert.That(f.Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Blink], Is.GreaterThan(.95f));
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.GreaterThan(.001f));
        Assert.That(Quaternion.Angle(eye, f.LeftEye.localRotation), Is.LessThan(.03f));
        Assert.That(Quaternion.Angle(head, f.Head.rotation), Is.LessThan(.03f));
        f.Command("stopLipSync", "{}");
        f.Command("setExpression", "{\"eyeOpen\":1}");
        f.CompleteTransition("expressionTransitionStartedAt", "UpdateExpressionTransition");
        f.Frame();
        Assert.That(f.Vrm.Runtime.Expression.ActualWeights[key], Is.Zero);
        Assert.That(f.Vrm.Runtime.Expression.ActualWeights[ExpressionKey.Blink], Is.Zero);
        Assert.That(MaxDelta(neutral, f.BakeFace()), Is.LessThan(.00001f));
        Assert.That(Quaternion.Angle(eye, f.LeftEye.localRotation), Is.LessThan(.03f));
    }

    private static float MaxDelta(Vector3[] a, Vector3[] b) => a.Zip(b, Vector3.Distance).Max();

    private sealed class EyeCap
    {
        public readonly Transform Bone;
        public readonly Quaternion CenterRotation;
        public readonly Vector3 CenterPosition;
        private readonly SkinnedMeshRenderer renderer;
        private readonly int[] indices;

        public EyeCap(Fixture f, HumanBodyBones humanBone)
        {
            Bone = f.Animator.GetBoneTransform(humanBone);
            CenterRotation = Bone.rotation;
            renderer = f.Root.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Single(mesh => mesh.bones.Contains(Bone) && mesh.sharedMesh.boneWeights.Any(weight =>
                    WeightFor(weight, Array.IndexOf(mesh.bones, Bone)) > .99f));
            int boneIndex = Array.IndexOf(renderer.bones, Bone);
            Vector3[] points = BakeWorld(renderer);
            BoneWeight[] weights = renderer.sharedMesh.boneWeights;
            int[] eyeVertices = Enumerable.Range(0, points.Length)
                .Where(index => WeightFor(weights[index], boneIndex) > .99f).ToArray();
            Assert.That(eyeVertices.Length, Is.GreaterThan(10));
            float front = eyeVertices.Max(index => Vector3.Dot(points[index] - Bone.position, f.Root.forward));
            indices = eyeVertices.Where(index =>
                Vector3.Dot(points[index] - Bone.position, f.Root.forward) > front - .001f).ToArray();
            Assert.That(indices.Length, Is.GreaterThan(2), "Need an actual forward eye cap, not an arbitrary eyelid vertex.");
            CenterPosition = WorldCenter();
        }
        public Vector3 WorldCenter()
        {
            Vector3[] points = BakeWorld(renderer);
            return indices.Aggregate(Vector3.zero, (sum, index) => sum + points[index]) / indices.Length;
        }
        private static float WeightFor(BoneWeight w, int index) =>
            (w.boneIndex0 == index ? w.weight0 : 0f) + (w.boneIndex1 == index ? w.weight1 : 0f) +
            (w.boneIndex2 == index ? w.weight2 : 0f) + (w.boneIndex3 == index ? w.weight3 : 0f);
        private static Vector3[] BakeWorld(SkinnedMeshRenderer renderer)
        {
            var mesh = new Mesh();
            try { renderer.BakeMesh(mesh); return mesh.vertices.Select(renderer.transform.TransformPoint).ToArray(); }
            finally { Object.DestroyImmediate(mesh); }
        }
    }

    private sealed class Fixture : IDisposable
    {
        private const BindingFlags Flags = BindingFlags.Instance | BindingFlags.NonPublic;
        public readonly Component Receiver;
        public readonly Vrm10Instance Vrm;
        public readonly Animator Animator;
        public readonly Transform Root, Head, LeftEye;
        public readonly Behaviour Framing;
        public readonly Camera Camera;
        private readonly SkinnedMeshRenderer face;
        public Fixture()
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Vrm = Object.FindAnyObjectByType<Vrm10Instance>();
            Root = Vrm.transform;
            Receiver = Object.FindAnyObjectByType(Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp")) as Component;
            foreach (Renderer renderer in Root.GetComponentsInChildren<Renderer>())
                if (renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                    foreach (Material material in renderer.sharedMaterials)
                        LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Invoke("Awake");
            Command("setLocalAvatarVisible", "{\"visible\":true}");
            Animator = Root.GetComponentInChildren<Animator>();
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.applyRootMotion = false;
            Animator.Rebind();
            Animator.Play("idle_shrug", 0, 0f);
            Animator.Update(0f);
            Head = Animator.GetBoneTransform(HumanBodyBones.Head);
            LeftEye = Animator.GetBoneTransform(HumanBodyBones.LeftEye);
            Framing = Object.FindAnyObjectByType(Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp")) as Behaviour;
            Camera = Framing.GetComponent<Camera>();
            Assert.That(Framing.enabled, Is.True, "Saved Companion must start in Home framing.");
            Assert.That(Camera.orthographic, Is.False);
            Assert.That(Camera.backgroundColor.a, Is.GreaterThanOrEqualTo(.99f));
            face = Root.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Single(renderer => renderer.sharedMesh != null && renderer.sharedMesh.GetBlendShapeIndex("Smile_L") >= 0);
            Set("autoBlink", false);
            Set("actionPoseHoldUntil", Time.realtimeSinceStartup + 3600f);
            Command("setExpression", "{\"eyeOpen\":1}");
            CompleteTransition("expressionTransitionStartedAt", "UpdateExpressionTransition");
            Frame();
        }
        public void CenterWithoutHome()
        {
            Framing.enabled = false;
            Frame();
            Framing.enabled = true;
        }
        public void Frame() { Invoke("LateUpdate"); Vrm.Runtime.Process(); }
        public void CompleteTransition(string field, string method) => Invoke(method, (float)Field(field) + 1f);
        public object Field(string name) => Receiver.GetType().GetField(name, Flags).GetValue(Receiver);
        public void Set(string name, object value) => Receiver.GetType().GetField(name, Flags).SetValue(Receiver, value);
        public void Invoke(string name, params object[] args) => Receiver.GetType().GetMethod(name, Flags).Invoke(Receiver, args);
        public void Command(string method, string json) => Receiver.GetType().GetMethod("OnFlutterCommand").Invoke(Receiver,
            new object[] { "{\"method\":\"" + method + "\",\"json\":\"" + json.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"}" });
        public Vector3[] BakeFace()
        {
            var mesh = new Mesh();
            try { face.BakeMesh(mesh); return mesh.vertices; }
            finally { Object.DestroyImmediate(mesh); }
        }
        public void Dispose()
        {
            Set("avatarLeasedToWorld", false);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}
